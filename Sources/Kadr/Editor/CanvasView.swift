import AppKit
import Combine

enum EditorCommand { case copy, save, saveAs, pin, share, reveal, done, ocr, resetCrop }

/// The drawing surface. Works in image pixel coordinates; maps to view points via `k`/`origin`/`shift`.
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    var onCommand: ((EditorCommand) -> Void)?

    private var cancellable: AnyCancellable?
    private var k: CGFloat = 1
    private var origin: CGPoint = .zero
    private var shift: CGPoint = .zero
    private var docSize: CGSize = .zero

    private var dragStart: CGPoint?
    private var lastPoint: CGPoint?
    private var draftID: UUID?
    private var cropDraft: CGRect?
    private var movingID: UUID?
    private var movedOnce = false

    private var textField: NSTextField?
    private var pendingText: Annotation?
    private var editingTextID: UUID?
    private var lastTool: Tool?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        cancellable = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplay = true
                if self.lastTool != self.model.tool {
                    self.lastTool = self.model.tool
                    if self.textField != nil { self.commitText() }
                    self.window?.invalidateCursorRects(for: self)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        let c: NSCursor
        switch model.tool {
        case .select: c = .arrow
        case .text: c = .iBeam
        default: c = .crosshair
        }
        addCursorRect(bounds, cursor: c)
    }

    // MARK: Geometry

    private var editingCrop: Bool { model.tool == .crop }

    private func computeLayout() {
        let crop = editingCrop ? model.imageRect : model.crop
        let pad = (!editingCrop && model.background.enabled) ? model.background.padding * model.scale : 0
        docSize = CGSize(width: crop.width + pad * 2, height: crop.height + pad * 2)
        shift = CGPoint(x: pad - crop.minX, y: pad - crop.minY)
        let avail = bounds.insetBy(dx: 28, dy: 28)
        k = min(avail.width / max(1, docSize.width), avail.height / max(1, docSize.height), 1 / model.scale)
        k = max(k, 0.02)
        origin = CGPoint(x: (bounds.midX - docSize.width * k / 2).rounded(), y: (bounds.midY - docSize.height * k / 2).rounded())
    }

    private func toImage(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - origin.x) / k - shift.x, y: (v.y - origin.y) / k - shift.y)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + shift.x) * k + origin.x, y: (p.y + shift.y) * k + origin.y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * k, height: r.height * k)
    }

    private func point(_ e: NSEvent) -> CGPoint {
        computeLayout()
        return toImage(convert(e.locationInWindow, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        computeLayout()
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let docView = CGRect(x: origin.x, y: origin.y, width: docSize.width * k, height: docSize.height * k)
        if !model.background.enabled || editingCrop { drawChecker(docView) }

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: k, y: k)
        Renderer.compose(ctx, model: model, editingCrop: editingCrop, skip: editingTextID)
        ctx.restoreGState()

        if model.tool == .select, let id = model.selectedID, let a = model.annotations.first(where: { $0.id == id }) {
            let r = toView(a.bounds).insetBy(dx: -4, dy: -4)
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            p.lineWidth = 1.5
            p.setLineDash([5, 3], count: 2, phase: 0)
            p.stroke()
        }

        if editingCrop { drawCropUI(docView) }
    }

    private func drawChecker(_ r: CGRect) {
        NSColor(white: 0.2, alpha: 1).setFill()
        r.fill()
        NSColor(white: 0.26, alpha: 1).setFill()
        let s: CGFloat = 8
        var y = r.minY
        var row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : s)
            while x < r.maxX {
                CGRect(x: x, y: y, width: min(s, r.maxX - x), height: min(s, r.maxY - y)).fill()
                x += s * 2
            }
            y += s
            row += 1
        }
    }

    private func drawCropUI(_ docView: CGRect) {
        let c = toView(cropDraft ?? model.crop)
        let dim = NSBezierPath(rect: docView)
        dim.append(NSBezierPath(rect: c))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()
        NSColor.white.setStroke()
        let b = NSBezierPath(rect: c)
        b.lineWidth = 1.5
        b.stroke()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let g = NSBezierPath()
        g.lineWidth = 0.5
        for i in 1...2 {
            let fx = c.minX + c.width * CGFloat(i) / 3, fy = c.minY + c.height * CGFloat(i) / 3
            g.move(to: CGPoint(x: fx, y: c.minY)); g.line(to: CGPoint(x: fx, y: c.maxY))
            g.move(to: CGPoint(x: c.minX, y: fy)); g.line(to: CGPoint(x: c.maxX, y: fy))
        }
        g.stroke()
        let r = cropDraft ?? model.crop
        let label = NSAttributedString(string: " \(Int(r.width)) × \(Int(r.height)) px  ·  ⏎ — застосувати ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ])
        label.draw(at: CGPoint(x: c.minX, y: max(4, c.minY - 20)))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            commitText()
            if model.tool == .text { return }
        }
        window?.makeFirstResponder(self)
        let p = point(event)
        dragStart = p
        lastPoint = p
        let tol = 6 / k

        switch model.tool {
        case .select:
            if let a = model.annotations.last(where: { $0.hitTest(p, tolerance: tol) }) {
                model.selectedID = a.id
                movingID = a.id
                movedOnce = false
                if event.clickCount == 2, a.kind == .text { beginText(at: a.start, editing: a) }
            } else {
                model.selectedID = nil
            }
        case .text:
            if let a = model.annotations.last(where: { $0.kind == .text && $0.hitTest(p, tolerance: tol) }) {
                beginText(at: a.start, editing: a)
            } else {
                beginText(at: p, editing: nil)
            }
        case .counter:
            model.pushUndo()
            var a = newAnnotation(.counter, at: p)
            a.number = model.nextCounter
            model.annotations.append(a)
        case .crop:
            let c = clampToImage(p)
            cropDraft = CGRect(origin: c, size: .zero)
            dragStart = c
        default:
            guard let kind = annotationKind(model.tool) else { return }
            model.pushUndo()
            var a = newAnnotation(kind, at: p)
            if kind == .pen || kind == .highlighter { a.points = [p] }
            model.annotations.append(a)
            draftID = a.id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var p = point(event)
        switch model.tool {
        case .select:
            guard let id = movingID, let last = lastPoint, let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            if !movedOnce { model.pushUndo(); movedOnce = true }
            model.annotations[i].move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            lastPoint = p
        case .crop:
            guard let s = dragStart else { return }
            p = clampToImage(p)
            cropDraft = CGRect(p1: s, p2: p)
            needsDisplay = true
        default:
            guard let id = draftID, let s = dragStart, let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            let kind = model.annotations[i].kind
            if kind == .pen || kind == .highlighter {
                if let last = model.annotations[i].points.last, hypot(p.x - last.x, p.y - last.y) < 1 / k { return }
                if event.modifierFlags.contains(.shift), let first = model.annotations[i].points.first {
                    // Straight stroke while Shift is held.
                    model.annotations[i].points = [first, snap(from: first, to: p)]
                } else {
                    model.annotations[i].points.append(p)
                }
            } else {
                if event.modifierFlags.contains(.shift) {
                    p = (kind == .arrow || kind == .line) ? snap(from: s, to: p) : square(from: s, to: p)
                }
                model.annotations[i].end = p
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draftID = nil; movingID = nil; dragStart = nil; lastPoint = nil }
        switch model.tool {
        case .crop:
            if let d = cropDraft, d.width >= 8, d.height >= 8 {
                model.pushUndo()
                model.crop = d.intersection(model.imageRect).integral
            }
            cropDraft = nil
            needsDisplay = true
        default:
            guard let id = draftID, let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            let a = model.annotations[i]
            let tiny = a.kind != .pen && a.kind != .highlighter && hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4 / k
            if tiny {
                model.annotations.remove(at: i)
                model.discardUndo()
            }
        }
    }

    private func newAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, color: model.color, width: model.pixelWidth, start: p, end: p)
        a.unit = model.scale
        return a
    }

    private func annotationKind(_ t: Tool) -> Annotation.Kind? {
        switch t {
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .filledRect: return .filledRect
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .spotlight: return .spotlight
        case .text: return .text
        case .counter: return .counter
        case .select, .crop: return nil
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(model.base.width)), y: min(max(p.y, 0), CGFloat(model.base.height)))
    }

    private func snap(from s: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
    }

    private func square(from s: CGPoint, to p: CGPoint) -> CGPoint {
        let side = max(abs(p.x - s.x), abs(p.y - s.y))
        return CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
    }

    // MARK: Text

    private func beginText(at p: CGPoint, editing: Annotation?) {
        var a = editing ?? newAnnotation(.text, at: p)
        if editing == nil { a.text = "" }
        pendingText = a
        editingTextID = editing?.id
        computeLayout()

        let tf = NSTextField(string: a.text)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.isBezeled = false
        tf.font = NSFont.systemFont(ofSize: max(8, a.fontSize * k), weight: .bold)
        tf.textColor = NSColor(cgColor: a.color)
        tf.delegate = self
        tf.placeholderString = "Текст"
        tf.cell?.isScrollable = true
        let vp = toView(a.start)
        let h = ceil(a.fontSize * k * 1.35)
        tf.frame = CGRect(x: vp.x - 2, y: vp.y, width: max(160, a.textSize().width * k + 40), height: h)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = textField, let a = pendingText else { return }
        var probe = a
        probe.text = tf.stringValue
        tf.frame.size.width = max(160, probe.textSize().width * k + 40)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func commitText() {
        guard let tf = textField, var a = pendingText else { return }
        textField = nil
        pendingText = nil
        tf.removeFromSuperview()
        let txt = tf.stringValue
        let empty = txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let editedID = editingTextID
        editingTextID = nil
        defer { window?.makeFirstResponder(self); needsDisplay = true }

        if let id = editedID, let i = model.annotations.firstIndex(where: { $0.id == id }) {
            if txt == model.annotations[i].text { return }
            model.pushUndo()
            if empty { model.annotations.remove(at: i) } else { model.annotations[i].text = txt }
        } else if !empty {
            model.pushUndo()
            a.text = txt
            model.annotations.append(a)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let ch = event.characters(byApplyingModifiers: [])?.lowercased().first {
            if let t = Tool.allCases.first(where: { $0.shortcut == ch }) { model.tool = t; return }
            if let d = ch.wholeNumberValue, (1...EditorModel.palette.count).contains(d) {
                model.color = EditorModel.palette[d - 1]
                model.styleChanged()
                return
            }
        }
        switch Int(event.keyCode) {
        case 51, 117:
            model.deleteSelected()
        case 53:
            if editingCrop { cropDraft = nil; model.tool = .arrow } else { model.selectedID = nil }
        case 36, 76:
            if editingCrop { model.tool = .arrow }
        case 123, 124, 125, 126:
            nudge(event)
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(_ event: NSEvent) {
        guard let id = model.selectedID, let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
        let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) * model.scale
        var d = CGVector.zero
        switch Int(event.keyCode) {
        case 123: d.dx = -step
        case 124: d.dx = step
        case 125: d.dy = step
        default: d.dy = -step
        }
        model.pushUndo()
        model.annotations[i].move(by: d)
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { onCommand?(.copy) }
    @objc func saveDocument(_ sender: Any?) { onCommand?(.save) }
    @objc func saveDocumentAs(_ sender: Any?) { onCommand?(.saveAs) }
}
