// Draws the app icon into an .iconset folder: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.98, alpha: 1),
                        NSColor(red: 0.10, green: 0.62, blue: 0.98, alpha: 1)])?.draw(in: bg, angle: -60)
    // Viewfinder corners
    NSColor.white.setStroke()
    let c = body.insetBy(dx: s * 0.16, dy: s * 0.16)
    let l = c.width * 0.28
    let path = NSBezierPath()
    path.lineWidth = s * 0.055
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    for (p, dx, dy) in [(NSPoint(x: c.minX, y: c.maxY), 1.0, -1.0), (NSPoint(x: c.maxX, y: c.maxY), -1.0, -1.0),
                        (NSPoint(x: c.minX, y: c.minY), 1.0, 1.0), (NSPoint(x: c.maxX, y: c.minY), -1.0, 1.0)] {
        path.move(to: NSPoint(x: p.x, y: p.y + dy * l))
        path.line(to: p)
        path.line(to: NSPoint(x: p.x + dx * l, y: p.y))
    }
    path.stroke()
    NSColor.white.setFill()
    let r = c.width * 0.13
    NSBezierPath(ovalIn: NSRect(x: c.midX - r, y: c.midY - r, width: r * 2, height: r * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for mult in [1, 2] {
        let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try? render(base * mult)?.write(to: out.appendingPathComponent(name))
    }
}
