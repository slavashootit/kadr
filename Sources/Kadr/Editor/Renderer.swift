import AppKit

/// Draws the document (background, image, annotations). The context must be flipped (y down) in document pixels;
/// the current NSGraphicsContext must wrap the same CGContext (needed for text).
@MainActor
enum Renderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func compose(_ ctx: CGContext, model m: EditorModel, editingCrop: Bool, skip: UUID? = nil) {
        let crop = editingCrop ? m.imageRect : m.crop
        let bg: BackgroundStyle? = (!editingCrop && m.background.enabled) ? m.background : nil
        let pad = bg.map { $0.padding * m.scale } ?? 0
        let doc = CGRect(x: 0, y: 0, width: crop.width + pad * 2, height: crop.height + pad * 2)
        let content = CGRect(x: pad, y: pad, width: crop.width, height: crop.height)
        let device = hypot(ctx.ctm.a, ctx.ctm.b)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(m.base.alphaInfo)

        ctx.saveGState()
        if let bg {
            let colors = BackgroundStyle.presets[bg.preset % BackgroundStyle.presets.count] as CFArray
            if let g = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: doc)
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: doc.width, y: doc.height), options: [])
                ctx.restoreGState()
            }
            let radius = min(bg.cornerRadius * m.scale, content.width / 2, content.height / 2)
            let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if hasAlpha {
                // Window shots already have their own shape and shadow.
                if bg.shadow { ctx.setShadow(offset: .zero, blur: 30 * m.scale * device, color: CGColor(gray: 0, alpha: 0.45)) }
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.clip(to: content)
            } else {
                if bg.shadow {
                    ctx.saveGState()
                    ctx.setShadow(offset: .zero, blur: 30 * m.scale * device, color: CGColor(gray: 0, alpha: 0.45))
                    ctx.addPath(path)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                ctx.addPath(path)
                ctx.clip()
            }
        } else {
            ctx.clip(to: content)
        }

        ctx.translateBy(x: pad - crop.minX, y: pad - crop.minY)
        drawImage(ctx, m.base, in: m.imageRect)
        drawAnnotations(ctx, m, device: device, skip: skip)
        if bg != nil && hasAlpha { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    static func drawImage(_ ctx: CGContext, _ img: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func drawAnnotations(_ ctx: CGContext, _ m: EditorModel, device: CGFloat, skip: UUID?) {
        let list = m.annotations.filter { $0.id != skip }

        for a in list where a.kind == .pixelate || a.kind == .blur {
            guard let img = a.kind == .pixelate ? m.pixelated : m.blurred else { continue }
            let r = a.rect.intersection(m.imageRect)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            ctx.saveGState()
            ctx.clip(to: r)
            drawImage(ctx, img, in: m.imageRect)
            ctx.restoreGState()
        }

        let spots = list.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.addRect(m.imageRect.insetBy(dx: -10_000, dy: -10_000))
            for s in spots {
                let r = s.rect
                let rad = min(8 * s.unit, r.width / 2, r.height / 2)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in list { draw(a, in: ctx, device: device) }
    }

    static func draw(_ a: Annotation, in ctx: CGContext, device: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.width)
        ctx.setStrokeColor(a.color)
        ctx.setFillColor(a.color)
        let softShadow = { ctx.setShadow(offset: .zero, blur: 3 * a.unit * device, color: CGColor(gray: 0, alpha: 0.35)) }

        switch a.kind {
        case .pixelate, .blur, .spotlight:
            return
        case .arrow:
            softShadow()
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: a.width))
            ctx.fillPath()
        case .line:
            softShadow()
            ctx.move(to: a.start); ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rect:
            softShadow()
            let r = a.rect
            let rad = min(a.width, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.strokePath()
        case .filledRect:
            let r = a.rect
            let rad = min(a.width * 0.6, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.fillPath()
        case .ellipse:
            softShadow()
            ctx.strokeEllipse(in: a.rect)
        case .pen:
            softShadow()
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.copy(alpha: 0.45) ?? a.color)
            ctx.setLineWidth(a.width * 3.5)
            ctx.setLineCap(.square)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .text:
            let font = a.textFont()
            let outline = isLight(a.color) ? NSColor.black.withAlphaComponent(0.85) : NSColor.white
            let size = a.textSize()
            let r = CGRect(origin: a.start, size: size)
            NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: outline, .strokeColor: outline, .strokeWidth: 12])
                .draw(with: r, options: [.usesLineFragmentOrigin])
            NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: a.color) ?? .red])
                .draw(with: r, options: [.usesLineFragmentOrigin])
        case .counter:
            let rad = a.counterRadius
            softShadow()
            ctx.fillEllipse(in: CGRect(x: a.start.x - rad, y: a.start.y - rad, width: rad * 2, height: rad * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let s = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: rad * 1.15, weight: .bold),
                .foregroundColor: isLight(a.color) ? NSColor.black : NSColor.white,
            ])
            let sz = s.size()
            s.draw(at: CGPoint(x: a.start.x - sz.width / 2, y: a.start.y - sz.height / 2))
        }
    }

    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 1 else { return path }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let head = min(len * 0.7, max(w * 3.6, 14))
        let headHalf = head * 0.55
        let neckHalf = w * 0.55
        let tailHalf = w * 0.18
        let base = CGPoint(x: e.x - ux * head, y: e.y - uy * head)
        let back = CGPoint(x: base.x - ux * head * 0.12, y: base.y - uy * head * 0.12)
        func off(_ p: CGPoint, _ h: CGFloat) -> CGPoint { CGPoint(x: p.x + nx * h, y: p.y + ny * h) }
        path.move(to: off(s, tailHalf))
        path.addLine(to: off(base, neckHalf))
        path.addLine(to: off(back, headHalf))
        path.addLine(to: e)
        path.addLine(to: off(back, -headHalf))
        path.addLine(to: off(base, -neckHalf))
        path.addLine(to: off(s, -tailHalf))
        path.closeSubpath()
        return path
    }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)); return path }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func isLight(_ c: CGColor) -> Bool {
        guard let comps = c.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components, comps.count >= 3 else { return false }
        return 0.2126 * comps[0] + 0.7152 * comps[1] + 0.0722 * comps[2] > 0.7
    }
}
