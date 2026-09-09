import AppKit
import Foundation

// usage-bar — a menu bar readout of Claude and GPT subscription usage.
//
// Every number comes from the local opencodex proxy (127.0.0.1:10100) and nowhere else.
// The proxy caches usage for five minutes, so polling matches that interval instead of
// asking more often for the same answer. Opening the menu forces an immediate read.

let proxyBase = "http://127.0.0.1:10100"
let tokenPath = NSString(string: "~/.opencodex/admin-api-token").expandingTildeInPath
let pollInterval: TimeInterval = 300
let warnPercent = 70.0
let dangerPercent = 90.0

struct Window {
    var percent: Double
    var resetAt: Date?
}

struct Snapshot {
    var claudeWeekly: Window?
    var claudeFive: Window?
    var fable: Window?
    var gptWeekly: Window?
    var spark: Window?
    var resetCredits: Int?
    var claudeOK = false
    var gptOK = false
}

// CJK characters occupy two cells even in a monospaced font, so text columns have to be
// padded by display width rather than by character count. Only --dump uses this; the menu
// itself lays rows out by coordinate.
func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { total, scalar in
        let v = scalar.value
        let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0xFFE0 && v <= 0xFFE6)
        return total + (wide ? 2 : 1)
    }
}

func padded(_ text: String, to width: Int) -> String {
    text + String(repeating: " ", count: max(1, width - displayWidth(text)))
}

func asNumber(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

// Codex sends reset times in seconds, Anthropic in milliseconds. Tell them apart by magnitude.
func asDate(_ value: Any?) -> Date? {
    guard let n = asNumber(value), n > 0 else { return nil }
    return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
}

func makeWindow(_ percent: Any?, _ resetAt: Any?) -> Window? {
    guard let p = asNumber(percent) else { return nil }
    return Window(percent: p, resetAt: asDate(resetAt))
}

func readToken() -> String? {
    guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// No disk cache: usage readings are never worth caching, and the cache database emits
// warnings when the app runs under a sandbox.
let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

func fetchJSON(_ path: String, token: String) async -> [String: Any]? {
    guard let url = URL(string: proxyBase + path) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func loadSnapshot() async -> Snapshot {
    var snapshot = Snapshot()
    guard let token = readToken() else { return snapshot }

    async let providersTask = fetchJSON("/api/provider-quotas", token: token)
    async let codexTask = fetchJSON("/api/codex-auth/quota", token: token)
    let (providers, codex) = await (providersTask, codexTask)

    if let reports = providers?["reports"] as? [[String: Any]],
       let anthropic = reports.first(where: { ($0["provider"] as? String) == "anthropic" }),
       let quota = anthropic["quota"] as? [String: Any] {
        snapshot.claudeWeekly = makeWindow(quota["weeklyPercent"], quota["weeklyResetAt"])
        snapshot.claudeFive = makeWindow(quota["fiveHourPercent"], quota["fiveHourResetAt"])
        if let custom = quota["customWindows"] as? [[String: Any]],
           let row = custom.first(where: { ($0["label"] as? String)?.lowercased().contains("fable") == true }) {
            snapshot.fable = makeWindow(row["percent"], row["resetAt"])
        }
        snapshot.claudeOK = snapshot.claudeWeekly != nil
    }

    if let quotas = codex?["quotas"] as? [String: Any] {
        let account = (quotas["__main__"] as? [String: Any]) ?? (quotas.values.first as? [String: Any])
        if let account {
            snapshot.gptWeekly = makeWindow(account["weeklyPercent"], account["weeklyResetAt"])
            if let custom = account["customWindows"] as? [[String: Any]],
               let row = custom.first(where: { ($0["label"] as? String)?.lowercased().contains("spark") == true }) {
                snapshot.spark = makeWindow(row["percent"], row["resetAt"])
            }
            snapshot.resetCredits = asNumber(account["resetCredits"]).map { Int($0) }
            snapshot.gptOK = snapshot.gptWeekly != nil
        }
    }

    return snapshot
}

// The resting color differs by surface. Menu bar text uses the standard label color so it
// stays readable over any wallpaper; the bars in the dropdown use the accent color. Only the
// warning and danger colors are shared.
func color(for percent: Double, normal: NSColor = .labelColor) -> NSColor {
    if percent >= dangerPercent { return .systemRed }
    if percent >= warnPercent { return .systemOrange }
    return normal
}

// Row layout. Aligning columns with spaces breaks as soon as the font metrics shift, so every
// element gets an explicit coordinate instead.
enum Layout {
    static let inset: CGFloat = 14
    static let labelWidth: CGFloat = 92
    static let barWidth: CGFloat = 90
    static let percentWidth: CGFloat = 38
    static let resetWidth: CGFloat = 150
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 26
    static let width: CGFloat = inset + labelWidth + 8 + barWidth + 10 + percentWidth + 12 + resetWidth + inset
}

final class BarView: NSView {
    private let percent: Double
    private let fill: NSColor

    init(percent: Double, fill: NSColor, frame: NSRect) {
        self.percent = percent
        self.fill = fill
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let ratio = max(0, min(1, percent / 100))
        guard ratio > 0 else { return }
        // Floor the fill at one bar height so a tiny nonzero reading still shows as a dot.
        let width = max(bounds.height, bounds.width * ratio)
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

func label(_ text: String, font: NSFont, color: NSColor, align: NSTextAlignment, frame: NSRect) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.alignment = align
    field.frame = frame
    return field
}

func rowView(_ name: String, _ window: Window?) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.rowHeight))
    let textY = (Layout.rowHeight - 16) / 2

    view.addSubview(label(name, font: .systemFont(ofSize: 12), color: .labelColor, align: .left,
                          frame: NSRect(x: Layout.inset, y: textY, width: Layout.labelWidth, height: 16)))

    let barX = Layout.inset + Layout.labelWidth + 8
    guard let window else {
        view.addSubview(label("unavailable", font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, align: .left,
                              frame: NSRect(x: barX, y: textY, width: 200, height: 16)))
        return view
    }

    let barHeight: CGFloat = 6
    view.addSubview(BarView(percent: window.percent, fill: color(for: window.percent, normal: .controlAccentColor),
                            frame: NSRect(x: barX, y: (Layout.rowHeight - barHeight) / 2,
                                          width: Layout.barWidth, height: barHeight)))

    let percentX = barX + Layout.barWidth + 10
    view.addSubview(label(String(Int(window.percent.rounded())) + "%",
                          font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                          color: color(for: window.percent), align: .right,
                          frame: NSRect(x: percentX, y: textY, width: Layout.percentWidth, height: 16)))

    let resetX = percentX + Layout.percentWidth + 12
    view.addSubview(label(resetText(window.resetAt), font: .systemFont(ofSize: 11),
                          color: .secondaryLabelColor, align: .left,
                          frame: NSRect(x: resetX, y: textY + 1, width: Layout.resetWidth, height: 15)))
    return view
}

func headerView(_ text: String) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.headerHeight))
    view.addSubview(label(text, font: .systemFont(ofSize: 11, weight: .semibold),
                          color: .secondaryLabelColor, align: .left,
                          frame: NSRect(x: Layout.inset, y: 4, width: Layout.width - Layout.inset * 2, height: 15)))
    return view
}


func barString(_ percent: Double) -> String {
    let filled = max(0, min(10, Int((percent / 10).rounded())))
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
}

let resetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM/dd HH:mm"
    return f
}()

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let remaining = date.timeIntervalSinceNow
    if remaining <= 0 { return "resetting" }
    let hours = remaining / 3600
    let relative = hours < 24
        ? String(format: "in %.0fh", hours.rounded())
        : String(format: "in %.1fd", hours / 24)
    return resetFormatter.string(from: date) + " (" + relative + ")"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var snapshot = Snapshot()
    private var lastUpdated: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        renderTitle()
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openDashboard() {
        if let url = URL(string: proxyBase + "/") { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        Task { @MainActor in
            let next = await loadSnapshot()
            self.snapshot = next
            if next.claudeOK || next.gptOK { self.lastUpdated = Date() }
            self.renderTitle()
            self.rebuildMenu()
        }
    }

    private func segment(_ label: String, _ window: Window?) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        guard let window else {
            return NSAttributedString(string: label + " ?", attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        let text = label + " " + String(Int(window.percent.rounded())) + "%"
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color(for: window.percent),
        ])
    }

    private func renderTitle() {
        let title = NSMutableAttributedString()
        title.append(segment("C", snapshot.claudeWeekly))
        title.append(NSAttributedString(string: "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        title.append(segment("G", snapshot.gptWeekly))
        statusItem.button?.attributedTitle = title
    }

    private func addRow(_ name: String, _ window: Window?) {
        let item = NSMenuItem()
        item.view = rowView(name, window)
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addHeader(_ text: String) {
        let item = NSMenuItem()
        item.view = headerView(text)
        item.isEnabled = false
        menu.addItem(item)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if !snapshot.claudeOK && !snapshot.gptOK {
            addHeader("Can't reach the opencodex proxy")
            let hint = NSMenuItem(title: "Run  ocx start  in a terminal", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else {
            addHeader("Claude")
            addRow("Weekly", snapshot.claudeWeekly)
            addRow("Fable", snapshot.fable)
            addRow("5-hour", snapshot.claudeFive)
            menu.addItem(.separator())
            addHeader("GPT")
            addRow("Weekly", snapshot.gptWeekly)
            addRow("Spark weekly", snapshot.spark)
            if let credits = snapshot.resetCredits {
                menu.addItem(.separator())
                addHeader(String(credits) + (credits == 1 ? " reset credit left" : " reset credits left"))
            }
        }

        menu.addItem(.separator())
        if let lastUpdated {
            addHeader("Updated " + resetFormatter.string(from: lastUpdated))
        }
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open dashboard", action: #selector(openDashboard), keyEquivalent: "d").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    }
}

// --dump prints the current numbers without the menu bar. For checking what the app sees.
if CommandLine.arguments.contains("--dump") {
    let semaphore = DispatchSemaphore(value: 0)
    var fetched = Snapshot()
    Task {
        fetched = await loadSnapshot()
        semaphore.signal()
    }
    semaphore.wait()

    do {
        let snap = fetched
        func line(_ label: String, _ window: Window?) {
            let head = padded(label, to: 14)
            guard let window else { print(head + "unavailable"); return }
            let percent = String(Int(window.percent.rounded())) + "%"
            let gap = String(repeating: " ", count: max(0, 4 - percent.count))
            print(head + barString(window.percent) + " " + gap + percent + "   " + resetText(window.resetAt))
        }
        print("Claude")
        line("Weekly", snap.claudeWeekly)
        line("Fable", snap.fable)
        line("5-hour", snap.claudeFive)
        print("GPT")
        line("Weekly", snap.gptWeekly)
        line("Spark weekly", snap.spark)
        if let credits = snap.resetCredits { print(String(credits) + " reset credits left") }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
