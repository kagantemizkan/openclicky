#!/usr/bin/env swift
// Draws Resources/OpenClicky.icns: the cursor on a dark macOS-shaped tile.
// Usage: swift scripts/make-icon.swift Resources/OpenClicky.icns
// The cursor's corner points mirror CursorGeometry in BlueCursorView.swift.
import AppKit

let output = CommandLine.arguments[1]
let iconset = NSTemporaryDirectory() + "OpenClicky-\(UUID().uuidString).iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func cursorPath(width w: CGFloat, origin: CGPoint) -> CGPath {
    let aspect: CGFloat = 1.12
    let corners: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 0.09), (1, 0.56, 0.09), (0.46, 0.68, 0.12), (0.22, aspect, 0.09)]
    let points = corners.map { CGPoint(x: origin.x + $0.0 * w, y: origin.y + (aspect - $0.1) * w) }
    let path = CGMutablePath()
    let last = points[3]
    path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
    for i in points.indices {
        path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % 4], radius: corners[i].2 * w)
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let s = CGFloat(pixels)

    // Apple's icon grid: an 824-unit tile centred in 1024.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(white: 0.22, alpha: 1).cgColor, NSColor(white: 0.1, alpha: 1).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: .zero, options: [])

    let width = s * 0.40
    let path = cursorPath(width: width, origin: CGPoint(x: (s - width) / 2 - s * 0.01, y: (s - width * 1.12) / 2))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    context.addPath(path)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(width * 0.15)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()
    context.addPath(path)
    context.setFillColor(NSColor(srgbRed: 160 / 255, green: 218 / 255, blue: 250 / 255, alpha: 1).cgColor)
    context.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o", output]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
exit(process.terminationStatus)
