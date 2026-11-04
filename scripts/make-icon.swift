// Renders the Notchbench app icon and fills the Xcode icon set.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body inset in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.24, alpha: 1),
                    NSColor(calibratedRed: 0.25, green: 0.36, blue: 0.88, alpha: 1)])!
    .draw(in: bodyPath, angle: 70)

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()

// Soft light under the notch.
NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.70, blue: 1, alpha: 0.35), .clear])!
    .draw(fromCenter: CGPoint(x: body.midX, y: body.maxY - 150), radius: 0,
          toCenter: CGPoint(x: body.midX, y: body.maxY - 150), radius: 420, options: [])

// The notch: black, hanging from the top edge, rounded at the bottom.
let notchWidth: CGFloat = 440, notchHeight: CGFloat = 150
let notch = NSRect(x: body.midX - notchWidth / 2, y: body.maxY - notchHeight,
                   width: notchWidth, height: notchHeight + 100)
NSColor.black.setFill()
NSBezierPath(roundedRect: notch, xRadius: 70, yRadius: 70).fill()
NSGraphicsContext.restoreGraphicsState()

// Three tool tiles under the notch, the middle one lit green like a running tool.
let tile: CGFloat = 190, gap: CGFloat = 44
let rowWidth = tile * 3 + gap * 2
let tileY = body.midY - tile / 2 - 70
for index in 0..<3 {
    let rect = NSRect(x: body.midX - rowWidth / 2 + CGFloat(index) * (tile + gap), y: tileY,
                      width: tile, height: tile)
    let lit = index == 1
    (lit ? NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.50, alpha: 1) : NSColor(white: 1, alpha: 0.92)).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46).fill()
}

NSGraphicsContext.restoreGraphicsState()
let master = rep.representation(using: .png, properties: [:])!

// Write every size the icon set needs.
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconSet = scriptDir.deletingLastPathComponent()
    .appendingPathComponent("boringNotch/Assets.xcassets/AppIcon.appiconset")
let masterURL = iconSet.appendingPathComponent("icon_1024.png")
try! master.write(to: masterURL)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        let target = iconSet.appendingPathComponent(name)
        if pixels == 1024 {
            try? FileManager.default.removeItem(at: target)
            try! FileManager.default.copyItem(at: masterURL, to: target)
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            task.arguments = ["-z", "\(pixels)", "\(pixels)", masterURL.path, "--out", target.path]
            task.standardOutput = FileHandle.nullDevice
            try! task.run()
            task.waitUntilExit()
        }
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
try? FileManager.default.removeItem(at: masterURL)

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("Icon written to \(iconSet.path)")
