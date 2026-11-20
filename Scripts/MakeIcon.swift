import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func drawIcon(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let bounds = NSRect(x: 90, y: 90, width: 844, height: 844)
    let outline = NSBezierPath(roundedRect: bounds, xRadius: 184, yRadius: 184)
    NSGradient(
        starting: NSColor(srgbRed: 0.07, green: 0.23, blue: 0.24, alpha: 1),
        ending: NSColor(srgbRed: 0.05, green: 0.12, blue: 0.18, alpha: 1)
    )?.draw(in: outline, angle: -45)

    NSColor(srgbRed: 0.38, green: 0.72, blue: 0.69, alpha: 0.45).setStroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 230, y: 292, width: 564, height: 440), xRadius: 74, yRadius: 74)
    screen.lineWidth = 25
    screen.stroke()

    let trace = NSBezierPath()
    trace.move(to: NSPoint(x: 309, y: 505))
    trace.line(to: NSPoint(x: 413, y: 505))
    trace.line(to: NSPoint(x: 468, y: 615))
    trace.line(to: NSPoint(x: 550, y: 414))
    trace.line(to: NSPoint(x: 600, y: 505))
    trace.line(to: NSPoint(x: 715, y: 505))
    trace.lineWidth = 31
    trace.lineCapStyle = .round
    trace.lineJoinStyle = .round
    NSColor(srgbRed: 0.41, green: 0.94, blue: 0.78, alpha: 1).setStroke()
    trace.stroke()
    return bitmap.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let path = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let data = drawIcon(size: size * scale) else {
            fatalError("无法生成 \(path.lastPathComponent)")
        }
        try data.write(to: path)
    }
}
