import AppKit
import ScreenCaptureKit

enum SelectionResult {
    /// rect is in display-local top-left points; image is the frozen full-display shot.
    case area(screen: NSScreen, rect: CGRect, shot: DisplayShot)
    case window(WindowCandidate, screen: NSScreen)
}

/// Freezes every display and lets the user drag an area or (Space) pick a window.
@MainActor
final class SelectionController {
    enum Mode { case area, window }

    private(set) var mode: Mode
    let allowWindowMode: Bool
    let hint: String?
    private(set) var candidates: [WindowCandidate] = []
    private var overlays: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    private init(mode: Mode, allowWindowMode: Bool, hint: String?) {
        self.mode = mode
        self.allowWindowMode = allowWindowMode
        self.hint = hint
    }

    static func run(mode: Mode = .area, allowWindowMode: Bool = true, hint: String? = nil) async -> SelectionResult? {
        let c = SelectionController(mode: mode, allowWindowMode: allowWindowMode, hint: hint)
        return await c.start()
    }

    private func start() async -> SelectionResult? {
        let shots: [DisplayShot]
        do {
            let r = try await Capture.shotsOfAllScreens()
            shots = r.shots
            candidates = Capture.windowCandidates(r.content)
        } catch {
            Capture.showPermissionAlert()
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<SelectionResult?, Never>) in
            continuation = cont
            for shot in shots {
                let w = SelectionOverlayWindow(shot: shot, controller: self)
                overlays.append(w)
                w.orderFrontRegardless()
            }
            NSApp.activate()
            let target = overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays.first
            if let target {
                target.makeKey()
                target.makeFirstResponder(target.selectionView)
            }
        }
    }

    func toggleMode() {
        guard allowWindowMode else { return }
        mode = mode == .area ? .window : .area
        overlays.forEach { $0.selectionView.modeChanged() }
    }

    func candidate(atGlobal p: CGPoint) -> WindowCandidate? {
        candidates.first { $0.frame.contains(p) }
    }

    func mouseMoved(on view: SelectionView) {
        for o in overlays where o.selectionView !== view { o.selectionView.clearCursor() }
    }

    func finish(_ result: SelectionResult?) {
        guard let cont = continuation else { return }
        continuation = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        cont.resume(returning: result)
    }
}

final class SelectionOverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(shot: DisplayShot, controller: SelectionController) {
        selectionView = SelectionView(shot: shot, controller: controller)
        super.init(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        identifier = Exclusion.identifier
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        setFrame(shot.screen.frame, display: false)

        let root = NSView(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        root.wantsLayer = true
        root.layer?.contents = shot.image
        root.layer?.contentsGravity = .resize
        selectionView.frame = root.bounds
        selectionView.autoresizingMask = [.width, .height]
        root.addSubview(selectionView)
        contentView = root
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let shot: DisplayShot
    weak var controller: SelectionController?
    private let cgOrigin: CGPoint
    private var cursor: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowCandidate?
    private lazy var nsImage = NSImage(cgImage: shot.image, size: bounds.size)

    init(shot: DisplayShot, controller: SelectionController) {
        self.shot = shot
        self.controller = controller
        cgOrigin = CGDisplayBounds(shot.screen.displayID).origin
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { currentCursor.set() }
    private var currentCursor: NSCursor { controller?.mode == .window ? .pointingHand : .crosshair }

    private var mode: SelectionController.Mode { controller?.mode ?? .area }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + cgOrigin.x, y: p.y + cgOrigin.y) }
    private func localRect(fromGlobal r: CGRect) -> CGRect { r.offsetBy(dx: -cgOrigin.x, dy: -cgOrigin.y) }

    func clearCursor() {
        guard cursor != nil || hovered != nil else { return }
        cursor = nil
        hovered = nil
        needsDisplay = true
    }

    func modeChanged() {
        selection = nil
        dragStart = nil
        if let c = cursor { hovered = controller?.candidate(atGlobal: global(c)) }
        currentCursor.set()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) { clearCursor() }

    override func mouseMoved(with event: NSEvent) {
        cursor = local(event)
        if window?.isKeyWindow == false { window?.makeKey(); window?.makeFirstResponder(self) }
        controller?.mouseMoved(on: self)
        if mode == .window, let c = cursor { hovered = controller?.candidate(atGlobal: global(c)) }
        currentCursor.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(event)
        dragStart = p
        cursor = p
        if mode == .area { selection = CGRect(origin: p, size: .zero) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let s = dragStart else { return }
        var p = local(event)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        if event.modifierFlags.contains(.shift) {   // square
            let side = max(abs(p.x - s.x), abs(p.y - s.y))
            p = CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
        }
        cursor = p
        selection = CGRect(p1: s, p2: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = local(event)
        defer { dragStart = nil }
        if mode == .window {
            if let h = controller?.candidate(atGlobal: global(p)) { controller?.finish(.window(h, screen: shot.screen)) }
            return
        }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            controller?.finish(.area(screen: shot.screen, rect: sel.integral, shot: shot))
        } else if controller?.allowWindowMode == true, let h = controller?.candidate(atGlobal: global(p)) {
            // A plain click captures the window under the cursor.
            controller?.finish(.window(h, screen: shot.screen))
        } else {
            controller?.finish(.area(screen: shot.screen, rect: bounds, shot: shot))
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: controller?.finish(nil)                        // Esc
        case 49: controller?.toggleMode()                       // Space
        case 36, 76:                                            // Return: whole screen
            controller?.finish(.area(screen: shot.screen, rect: bounds, shot: shot))
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.32)
        if mode == .window {
            let path = NSBezierPath(rect: bounds)
            if let h = hovered {
                let r = localRect(fromGlobal: h.frame)
                path.append(NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10))
                path.windingRule = .evenOdd
                dim.setFill(); path.fill()
                NSColor.systemBlue.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
                NSColor.systemBlue.setStroke()
                let b = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
                b.lineWidth = 3
                b.stroke()
                let label = h.title.isEmpty ? h.appName : "\(h.appName) — \(h.title)"
                drawPill("\(label)   \(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: r.midX, y: r.midY), centered: true)
            } else {
                dim.setFill(); path.fill()
            }
            drawHint("Клік — знімок вікна · Пробіл — область · Esc — скасувати")
            return
        }

        if let sel = selection, sel.width > 0 || sel.height > 0 {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: sel))
            path.windingRule = .evenOdd
            dim.setFill(); path.fill()
            NSColor.white.setStroke()
            let b = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            b.lineWidth = 1
            b.stroke()
            let px = CGSize(width: sel.width * shot.scale, height: sel.height * shot.scale)
            let labelY = sel.maxY + 16 < bounds.height ? sel.maxY + 16 : sel.maxY - 16
            drawPill("\(Int(sel.width)) × \(Int(sel.height))  ·  \(Int(px.width))×\(Int(px.height)) px", at: CGPoint(x: sel.midX, y: labelY), centered: true)
        } else {
            dim.setFill(); bounds.fill(using: .sourceOver)
            if let c = cursor {
                NSColor.white.withAlphaComponent(0.55).setStroke()
                let cross = NSBezierPath()
                cross.lineWidth = 1
                cross.move(to: CGPoint(x: 0, y: c.y + 0.5)); cross.line(to: CGPoint(x: bounds.width, y: c.y + 0.5))
                cross.move(to: CGPoint(x: c.x + 0.5, y: 0)); cross.line(to: CGPoint(x: c.x + 0.5, y: bounds.height))
                cross.setLineDash([4, 4], count: 2, phase: 0)
                cross.stroke()
            }
            drawHint((controller?.hint.map { $0 + " · " } ?? "") + "Тягни — область · Клік — вікно · Пробіл — режим вікна · ⏎ — весь екран · Esc")
        }
        if let c = cursor, Prefs.showMagnifier { drawLoupe(at: c) }
    }

    private func drawLoupe(at c: CGPoint) {
        let cells = 15, zoom: CGFloat = 8
        let size = CGFloat(cells) * zoom
        var origin = CGPoint(x: c.x + 24, y: c.y + 24)
        if origin.x + size > bounds.width { origin.x = c.x - 24 - size }
        if origin.y + size + 26 > bounds.height { origin.y = c.y - 24 - size - 26 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))

        let s = shot.scale
        let src = CGRect(x: c.x * s - CGFloat(cells / 2), y: c.y * s - CGFloat(cells / 2), width: CGFloat(cells), height: CGFloat(cells))
        // NSImage source rects are bottom-left based.
        let srcNS = CGRect(x: src.minX / s, y: (CGFloat(shot.image.height) - src.maxY) / s, width: src.width / s, height: src.height / s)

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.set()
        NSColor.black.setFill(); clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        nsImage.draw(in: box, from: srcNS, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        // Grid + center pixel
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for i in 1..<cells {
            let o = CGFloat(i) * zoom
            grid.move(to: CGPoint(x: box.minX + o, y: box.minY)); grid.line(to: CGPoint(x: box.minX + o, y: box.maxY))
            grid.move(to: CGPoint(x: box.minX, y: box.minY + o)); grid.line(to: CGPoint(x: box.maxX, y: box.minY + o))
        }
        grid.stroke()
        let mid = CGRect(x: box.minX + CGFloat(cells / 2) * zoom, y: box.minY + CGFloat(cells / 2) * zoom, width: zoom, height: zoom)
        NSColor.white.setStroke()
        let m = NSBezierPath(rect: mid); m.lineWidth = 1.5; m.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()

        var hex = ""
        if let rgb = pixelColor(atPixel: CGPoint(x: c.x * s, y: c.y * s)) { hex = "  " + rgb }
        drawPill("\(Int(c.x)), \(Int(c.y))\(hex)", at: CGPoint(x: box.midX, y: box.maxY + 14), centered: true)
    }

    private func pixelColor(atPixel p: CGPoint) -> String? {
        guard let one = shot.image.cropping(to: CGRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }

    private func drawPill(_ text: String, at p: CGPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var r = CGRect(x: p.x - size.width / 2 - 8, y: p.y - size.height / 2 - 4, width: size.width + 16, height: size.height + 8)
        r.origin.x = min(max(r.minX, 4), bounds.width - r.width - 4)
        r.origin.y = min(max(r.minY, 4), bounds.height - r.height - 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 8, y: r.minY + 4))
    }

    private func drawHint(_ text: String) {
        guard NSMouseInRect(NSEvent.mouseLocation, shot.screen.frame, false) else { return }
        drawPill(text, at: CGPoint(x: bounds.midX, y: bounds.height - 40), centered: true)
    }
}

@MainActor
extension SelectionResult {
    /// Screen plus display-local top-left rect, for recording/scrolling (window -> its visible frame).
    var screenAndRect: (NSScreen, CGRect) {
        switch self {
        case .area(let s, let r, _):
            return (s, r)
        case .window(let c, let s):
            let origin = CGDisplayBounds(s.displayID).origin
            let r = c.frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(CGRect(origin: .zero, size: s.frame.size))
            return (s, r)
        }
    }
}
