// Generates an .iconset (PNG sizes for iconutil) for Light System using AppKit only.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
    shape.fill()
    shape.addClip()
    let beams: [(CGFloat, NSColor)] = [
        (0.30, NSColor(calibratedRed: 0.74, green: 0.66, blue: 1.0, alpha: 0.75)),
        (0.50, NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.40, alpha: 0.85)),
        (0.70, NSColor(calibratedRed: 0.52, green: 0.70, blue: 1.0, alpha: 0.75)),
    ]
    for (x, color) in beams {
        let cx = rect.minX + rect.width * x
        let top = rect.maxY - rect.height * 0.16
        let bottom = rect.minY + rect.height * 0.12
        let half = rect.width * 0.17
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: cx - s * 0.015, y: top))
        beam.line(to: NSPoint(x: cx + s * 0.015, y: top))
        beam.line(to: NSPoint(x: cx + half, y: bottom))
        beam.line(to: NSPoint(x: cx - half, y: bottom))
        beam.close()
        NSGradient(starting: color, ending: color.withAlphaComponent(0.04))?.draw(in: beam, angle: -90)
        color.withAlphaComponent(1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.035, y: top - s * 0.02, width: s * 0.07, height: s * 0.07)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = render(base * scale) else { fatalError("render failed") }
        try data.write(to: out.appendingPathComponent(name))
    }
}
