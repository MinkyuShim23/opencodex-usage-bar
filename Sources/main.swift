import AppKit
import Foundation

// usage-bar — a menu bar readout of Claude and GPT subscription usage.
//
// Usage windows come from the local opencodex proxy (127.0.0.1:10100). Two balances the proxy
// does not expose (Claude extra usage, GPT credits) are read directly from Anthropic and
// ChatGPT with the access tokens the proxy and Codex already hold. Those tokens are only
// read, never refreshed: refreshing would rotate them out from under the proxy.
//
// Refresh has three speeds:
// - every minute, a cached read from the proxy (free, local)
// - every ten seconds, a look at the proxy's request log; when a new request has finished,
//   the proxy is asked to re-probe upstream, at most once a minute
// - every ten minutes, the credit balances and reset grants

let proxyBase = "http://127.0.0.1:10100"
let tokenPath = NSString(string: "~/.opencodex/admin-api-token").expandingTildeInPath
let opencodexAuthPath = NSString(string: "~/.opencodex/auth.json").expandingTildeInPath
let codexAuthPath: String = {
    let base = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath
    return (base as NSString).appendingPathComponent("auth.json")
}()
let pollInterval: TimeInterval = 60
let activityInterval: TimeInterval = 10
let forcedMinGap: TimeInterval = 60
let creditInterval: TimeInterval = 600
let creditMinGap: TimeInterval = 60
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
    var resetCredits: Int?
    var claudeOK = false
    var gptOK = false
}

struct ExtraUsage {
    var enabled: Bool
    var used: Double
    var limit: Double
    var currency: String
}

struct ResetGrants {
    var left: Int
    var expiresAt: Date?
}

struct Credits {
    var claudeExtra: ExtraUsage?
    var claudeResets: ResetGrants?
    var gptBalance: Double?
    var gptUnlimited = false
    var gptResets: ResetGrants?
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

func fetchURL(_ urlString: String, headers: [String: String]) async -> [String: Any]? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func fetchJSON(_ path: String, token: String) async -> [String: Any]? {
    await fetchURL(proxyBase + path, headers: ["Authorization": "Bearer " + token])
}

func readJSONFile(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func loadSnapshot(force: Bool = false) async -> Snapshot {
    var snapshot = Snapshot()
    guard let token = readToken() else { return snapshot }

    // A forced read makes the proxy re-probe upstream, which also refreshes its Codex store,
    // so the Codex read waits for it instead of racing it.
    let providers = await fetchJSON("/api/provider-quotas" + (force ? "?refresh=1" : ""), token: token)
    let codex = await fetchJSON("/api/codex-auth/quota", token: token)

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
            snapshot.resetCredits = asNumber(account["resetCredits"]).map { Int($0) }
            snapshot.gptOK = snapshot.gptWeekly != nil
        }
    }

    return snapshot
}

// Id of the newest finished request in the proxy's log. Local and cheap; used only to notice
// that usage has probably changed.
func latestRequestId() async -> String? {
    guard let token = readToken(),
          let page = await fetchJSON("/api/request-history?limit=1", token: token),
          let entries = page["entries"] as? [[String: Any]] else { return nil }
    return entries.first?["requestId"] as? String ?? ""
}

// Claude extra usage. The proxy's usage probe drops this block, so read it from the same
// endpoint with the proxy's current access token. An expired token means skip, not refresh.
func fetchClaudeExtra() async -> ExtraUsage? {
    guard let auth = readJSONFile(opencodexAuthPath)?["anthropic"] as? [String: Any],
          let activeId = auth["activeAccountId"] as? String,
          let accounts = auth["accounts"] as? [[String: Any]],
          let account = accounts.first(where: { ($0["id"] as? String) == activeId }),
          let credential = account["credential"] as? [String: Any],
          let access = credential["access"] as? String else { return nil }
    if let expires = asDate(credential["expires"]), expires.timeIntervalSinceNow < 60 { return nil }

    guard let body = await fetchURL("https://api.anthropic.com/api/oauth/usage", headers: [
        "Authorization": "Bearer " + access,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/2.1.0",
    ]), let extra = body["extra_usage"] as? [String: Any] else { return nil }

    // Amounts arrive in minor units (cents for USD).
    let scale = pow(10, asNumber(extra["decimal_places"]) ?? 2)
    return ExtraUsage(
        enabled: (extra["is_enabled"] as? Bool) ?? false,
        used: (asNumber(extra["used_credits"]) ?? 0) / scale,
        limit: (asNumber(extra["monthly_limit"]) ?? 0) / scale,
        currency: (extra["currency"] as? String) ?? "USD")
}

let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let isoFractionalParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// Anthropic sends whole seconds, ChatGPT sends microseconds.
func parseISO(_ text: String) -> Date? {
    isoParser.date(from: text) ?? isoFractionalParser.date(from: text)
}

// Claude usage-limit reset grants, through the proxy (which reads Anthropic on every call).
func fetchClaudeResets() async -> ResetGrants? {
    guard let token = readToken(),
          let body = await fetchJSON("/api/anthropic/reset-grants", token: token),
          let grants = body["grants"] as? [[String: Any]] else { return nil }
    let live = grants.filter { ($0["paused"] as? Bool) != true && (asNumber($0["resetsLeft"]) ?? 0) > 0 }
    let left = live.reduce(0) { $0 + Int(asNumber($1["resetsLeft"]) ?? 0) }
    let expiry = live.compactMap { ($0["endsAt"] as? String).flatMap(parseISO) }.min()
    return ResetGrants(left: left, expiresAt: expiry)
}

// GPT reset credits with their expiry dates, through the proxy (which reads ChatGPT on every
// call). The plain quota read carries only the count, which is not enough to avoid losing one.
func fetchGptResets() async -> ResetGrants? {
    guard let token = readToken(),
          let body = await fetchJSON("/api/codex-auth/reset-credits?accountId=__main__", token: token),
          let credits = body["credits"] as? [[String: Any]] else { return nil }
    let expiries = credits.compactMap { ($0["expires_at"] as? String).flatMap(parseISO) }
        .filter { $0 > Date() }
    let left = asNumber(body["available_count"]).map { Int($0) } ?? expiries.count
    return ResetGrants(left: left, expiresAt: expiries.min())
}

// GPT credit balance. The proxy parses the same WHAM response but keeps only reset credits.
func fetchGptCredits() async -> (balance: Double, unlimited: Bool)? {
    guard let tokens = readJSONFile(codexAuthPath)?["tokens"] as? [String: Any],
          let access = tokens["access_token"] as? String else { return nil }
    var headers = ["Authorization": "Bearer " + access, "User-Agent": "codex_cli_rs"]
    if let account = tokens["account_id"] as? String { headers["chatgpt-account-id"] = account }
    guard let body = await fetchURL("https://chatgpt.com/backend-api/wham/usage", headers: headers),
          let credits = body["credits"] as? [String: Any] else { return nil }
    let raw = credits["balance"]
    guard let balance = (raw as? String).flatMap(Double.init) ?? asNumber(raw) else { return nil }
    return (balance, (credits["unlimited"] as? Bool) ?? false)
}

func loadCredits() async -> Credits {
    async let extra = fetchClaudeExtra()
    async let resets = fetchClaudeResets()
    async let gpt = fetchGptCredits()
    async let gptResets = fetchGptResets()
    let (e, r, g, gr) = await (extra, resets, gpt, gptResets)
    return Credits(claudeExtra: e, claudeResets: r, gptBalance: g?.balance, gptUnlimited: g?.unlimited ?? false,
                   gptResets: gr)
}

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM/dd"
    return f
}()

func moneyText(_ amount: Double, _ currency: String) -> String {
    (currency == "USD" ? "$" : currency + " ") + String(format: "%.2f", amount)
}

func extraText(_ extra: ExtraUsage) -> String {
    moneyText(extra.used, extra.currency) + " / " + moneyText(extra.limit, extra.currency) + " this month"
}

func resetGrantText(_ resets: ResetGrants) -> String {
    guard resets.left > 0 else { return "none" }
    var text = String(resets.left) + " left"
    if let expiry = resets.expiresAt {
        text += " \u{00B7} " + (resets.left > 1 ? "next expires " : "expires ") + dayFormatter.string(from: expiry)
    }
    return text
}

// The detailed read carries expiry dates but refreshes every ten minutes; the count from the
// quota store refreshes every minute. When they disagree a credit was just used or granted, so
// the date may belong to the wrong credit: show the fresh count alone until the next detailed read.
func gptResetText(_ detailed: ResetGrants?, count: Int?) -> String? {
    if let detailed, count == nil || count == detailed.left { return resetGrantText(detailed) }
    guard let count else { return nil }
    return count > 0 ? String(count) + " left" : "none"
}

func balanceText(_ balance: Double, unlimited: Bool) -> String {
    if unlimited { return "unlimited" }
    let rounded = balance.rounded() == balance ? String(Int(balance)) : String(format: "%.2f", balance)
    return rounded + (balance == 1 ? " credit" : " credits")
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

func rowView(_ name: String, _ window: Window?, detail: String? = nil) -> NSView {
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
    view.addSubview(label(detail ?? resetText(window.resetAt), font: .systemFont(ofSize: 11),
                          color: .secondaryLabelColor, align: .left,
                          frame: NSRect(x: resetX, y: textY + 1, width: Layout.resetWidth, height: 15)))
    return view
}

// A label and a line of text, for values that are counts or balances rather than percentages.
func noteView(_ name: String, _ text: String) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.rowHeight))
    let textY = (Layout.rowHeight - 16) / 2
    view.addSubview(label(name, font: .systemFont(ofSize: 12), color: .labelColor, align: .left,
                          frame: NSRect(x: Layout.inset, y: textY, width: Layout.labelWidth, height: 16)))
    let x = Layout.inset + Layout.labelWidth + 8
    view.addSubview(label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, align: .left,
                          frame: NSRect(x: x, y: textY, width: Layout.width - x - Layout.inset, height: 16)))
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
    private var activityTimer: Timer?
    private var creditTimer: Timer?
    private var snapshot = Snapshot()
    private var credits = Credits()
    private var lastUpdated: Date?
    private var lastRequestId: String?
    private var lastForced = Date.distantPast
    private var forcePending = false
    private var lastCreditFetch = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        renderTitle()
        rebuildMenu()
        refresh()
        refreshCredits()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityInterval, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        creditTimer = Timer.scheduledTimer(withTimeInterval: creditInterval, repeats: true) { [weak self] _ in
            self?.refreshCredits()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        if Date().timeIntervalSince(lastCreditFetch) >= creditMinGap { refreshCredits() }
    }

    @objc private func refreshNow() {
        refresh(force: true)
        refreshCredits()
    }

    @objc private func openDashboard() {
        if let url = URL(string: proxyBase + "/") { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh(force: Bool = false) {
        if force { lastForced = Date() }
        Task { @MainActor in
            let next = await loadSnapshot(force: force)
            self.snapshot = next
            if next.claudeOK || next.gptOK { self.lastUpdated = Date() }
            self.renderTitle()
            self.rebuildMenu()
        }
    }

    private func refreshCredits() {
        lastCreditFetch = Date()
        Task { @MainActor in
            let next = await loadCredits()
            // Keep the last good value of each field; one failed read should not blank it.
            if let v = next.claudeExtra { self.credits.claudeExtra = v }
            if let v = next.claudeResets { self.credits.claudeResets = v }
            if let v = next.gptResets { self.credits.gptResets = v }
            if let v = next.gptBalance { self.credits.gptBalance = v; self.credits.gptUnlimited = next.gptUnlimited }
            self.rebuildMenu()
        }
    }

    // A finished request means usage moved. GPT numbers arrive in-band with the response, so a
    // plain read shows them at once. Claude needs an upstream re-probe, rate-limited to one a minute.
    private func checkActivity() {
        Task { @MainActor in
            guard let id = await latestRequestId() else { return }
            defer { self.lastRequestId = id }
            guard let previous = self.lastRequestId, previous != id else { return }
            self.refresh()
            self.scheduleForced()
        }
    }

    private func scheduleForced() {
        guard !forcePending else { return }
        forcePending = true
        let wait = max(3, forcedMinGap - Date().timeIntervalSince(lastForced))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.forcePending = false
            self?.refresh(force: true)
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

    private func addNote(_ name: String, _ text: String) {
        let item = NSMenuItem()
        item.view = noteView(name, text)
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
            if let extra = credits.claudeExtra {
                if extra.enabled && extra.limit > 0 {
                    let item = NSMenuItem()
                    item.view = rowView("Extra usage", Window(percent: extra.used / extra.limit * 100, resetAt: nil),
                                        detail: extraText(extra))
                    item.isEnabled = false
                    menu.addItem(item)
                } else {
                    addNote("Extra usage", "off")
                }
            }
            if let resets = credits.claudeResets { addNote("Resets", resetGrantText(resets)) }
            menu.addItem(.separator())
            addHeader("GPT")
            addRow("Weekly", snapshot.gptWeekly)
            if let balance = credits.gptBalance { addNote("Credits", balanceText(balance, unlimited: credits.gptUnlimited)) }
            if let text = gptResetText(credits.gptResets, count: snapshot.resetCredits) { addNote("Resets", text) }
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
    var fetchedCredits = Credits()
    Task {
        async let snap = loadSnapshot()
        async let cred = loadCredits()
        (fetched, fetchedCredits) = await (snap, cred)
        semaphore.signal()
    }
    semaphore.wait()

    do {
        let snap = fetched
        let cred = fetchedCredits
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
        if let extra = cred.claudeExtra {
            print(padded("Extra usage", to: 14) + (extra.enabled ? extraText(extra) : "off"))
        }
        if let resets = cred.claudeResets { print(padded("Resets", to: 14) + resetGrantText(resets)) }
        print("GPT")
        line("Weekly", snap.gptWeekly)
        if let balance = cred.gptBalance { print(padded("Credits", to: 14) + balanceText(balance, unlimited: cred.gptUnlimited)) }
        if let text = gptResetText(cred.gptResets, count: snap.resetCredits) { print(padded("Resets", to: 14) + text) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
