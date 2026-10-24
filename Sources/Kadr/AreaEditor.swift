import AppKit

/// The area to record, in display-local top-left points; shared by the frame editor and the setup panel.
@MainActor
final class RecordingArea: ObservableObject {
    @Published var rect: CGRect
    let screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
        rect = CGRect(origin: .zero, size: screen.frame.size)
    }

    var pixelSize: CGSize {
        CGSize(width: rect.width * screen.backingScaleFactor, height: rect.height * screen.backingScaleFactor)
    }
}

/// Live (not frozen) overlay that starts as the whole screen and lets the user resize the frame
/// by its corners and edges, move it from inside, or drag a new one outside it.
@MainActor
final class AreaEditor {
    private let window: NSWindow

    init(area: RecordingArea) {
        let screen = area.screen
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.identifier = Exclusion.identifier
        window.isReleasedWhenClosed = false
        // One step below the setup panel, so clicking the frame never covers the panel.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.contentView = AreaEditorView(area: area)
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil) }
}

private final class AreaEditorView: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }
    private enum Grab { case resize(Edges), move, draw }

    private let area: RecordingArea
    private var grab: Grab?
    private var dragStart: CGPoint = .zero
    private var startRect: CGRect = .zero
    private static let handle: CGFloat = 10
    private static let reach: CGFloat = 14     // how far from a corner/edge a press still grabs it
    private static let minSide: CGFloat = 32

    init(area: RecordingArea) {
        self.area = area
        super.init(frame: CGRect(origin: .zero, size: area.screen.frame.size))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var rect: CGRect {
        get { area.rect }
        set { area.rect = newValue; needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    // MARK: Hit testing & cursors

    private func edges(at p: CGPoint) -> Edges {
        let r = rect, d = Self.reach
        guard r.insetBy(dx: -d, dy: -d).contains(p) else { return [] }
        var e: Edges = []
        if abs(p.x - r.minX) <= d { e.insert(.left) } else if abs(p.x - r.maxX) <= d { e.insert(.right) }
        if abs(p.y - r.minY) <= d { e.insert(.top) } else if abs(p.y - r.maxY) <= d { e.insert(.bottom) }
        return e
    }

    private func grab(at p: CGPoint) -> Grab {
        let e = edges(at: p)
        if !e.isEmpty { return .resize(e) }
        return rect.contains(p) ? .move : .draw
    }

    private func cursor(for g: Grab) -> NSCursor {
        switch g {
        case .move: return .openHand
        case .draw: return .crosshair
        case .resize(let e):
            let position: NSCursor.FrameResizePosition
            switch (e.contains(.left), e.contains(.right), e.contains(.top), e.contains(.bottom)) {
            case (true, _, true, _): position = .topLeft
            case (_, true, true, _): position = .topRight
            case (true, _, _, true): position = .bottomLeft
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(for: grab(at: convert(event.locationInWindow, from: nil))).set()
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, rect.contains(p) {
            rect = bounds       // double-click: back to the whole screen
            grab = nil
            return
        }
        grab = grab(at: p)
        dragStart = p
        startRect = rect
        if case .move = grab { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        let r = startRect, m = Self.minSide

        switch grab {
        case .move:
            var o = CGPoint(x: r.minX + dx, y: r.minY + dy)
            o.x = min(max(o.x, 0), bounds.width - r.width)
            o.y = min(max(o.y, 0), bounds.height - r.height)
            rect = CGRect(origin: o, size: r.size)
        case .draw:
            rect = CGRect(p1: dragStart, p2: p)
        case .resize(let e):
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if e.contains(.left) { minX = min(r.minX + dx, maxX - m) }
            if e.contains(.right) { maxX = max(r.maxX + dx, minX + m) }
            if e.contains(.top) { minY = min(r.minY + dy, maxY - m) }
            if e.contains(.bottom) { maxY = max(r.maxY + dy, minY + m) }
            if event.modifierFlags.contains(.shift), e.contains(.left) || e.contains(.right), e.contains(.top) || e.contains(.bottom) {
                // Shift on a corner keeps the starting proportions.
                let aspect = r.width / max(r.height, 1)
                let h = (maxX - minX) / aspect
                if e.contains(.top) { minY = maxY - h } else { maxY = minY + h }
            }
            rect = CGRect(x: max(0, minX), y: max(0, minY),
                          width: min(maxX, bounds.width) - max(0, minX), height: min(maxY, bounds.height) - max(0, minY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .draw = grab, rect.width < Self.minSide || rect.height < Self.minSide { rect = startRect }
        rect = rect.integral.intersection(bounds)
        grab = nil
        mouseMoved(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let r = rect
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        border.stroke()

        let h = Self.handle
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        for c in points {
            // Keep handles fully on screen when the frame touches the edges.
            let x = min(max(c.x - h / 2, 2), bounds.width - h - 2)
            let y = min(max(c.y - h / 2, 2), bounds.height - h - 2)
            let box = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: h, height: h), xRadius: 2.5, yRadius: 2.5)
            NSColor.white.setFill(); box.fill()
            NSColor.systemRed.setStroke(); box.lineWidth = 1.5; box.stroke()
        }

        let px = area.pixelSize
        drawPill("\(Int(px.width)) × \(Int(px.height)) px", at: CGPoint(x: r.midX, y: r.midY))
        if grab == nil {
            drawPill("Тягни кути чи краї — розмір · всередині — перемістити · поза рамкою — нова · двічі клік — весь екран",
                     at: CGPoint(x: bounds.midX, y: 48))
        }
    }

    private func drawPill(_ text: String, at p: CGPoint) {
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
}
