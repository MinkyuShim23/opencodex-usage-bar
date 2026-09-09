import AppKit

// AppIcon.icns 생성기. 아이콘을 바꾸고 싶을 때만 실행한다.
//   swift tools/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns

let background = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.17, alpha: 1)
let track = NSColor(calibratedWhite: 1, alpha: 0.16)
let claudeColor = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.20, alpha: 1)
let gptColor = NSColor(calibratedRed: 0.35, green: 0.66, blue: 1.00, alpha: 1)

func bar(y: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat, fill: CGFloat, color: NSColor) {
    let radius = height / 2
    track.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                 xRadius: radius, yRadius: radius).fill()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(height, width * fill), height: height),
                 xRadius: radius, yRadius: radius).fill()
}

func render(_ size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 아이콘 여백은 macOS 앱 아이콘 관례를 따른다.
    let inset = s * 0.06
    let plate = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    background.setFill()
    NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237).fill()

    let barHeight = plate.height * 0.145
    let barX = plate.minX + plate.width * 0.17
    let barWidth = plate.width * 0.66
    bar(y: plate.midY + barHeight * 0.35, height: barHeight, x: barX, width: barWidth, fill: 0.70, color: claudeColor)
    bar(y: plate.midY - barHeight * 1.35, height: barHeight, x: barX, width: barWidth, fill: 0.28, color: gptColor)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    guard let data = render(size).representation(using: .png, properties: [:]) else { continue }
    try data.write(to: URL(fileURLWithPath: outputDir + "/" + name + ".png"))
}
print("wrote " + outputDir)
