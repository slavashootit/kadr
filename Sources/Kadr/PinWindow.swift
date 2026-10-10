import AppKit

/// Floating always-on-top screenshot. Drag to move, scroll/pinch to zoom, right-click for options.
final class PinWindow: NSPanel {
    @MainActor private static var all: [PinWindow] = []

    let image: CGImage
    let scale: CGFloat
    private let aspect: CGFloat
    private(set) var locked = false

    @MainActor
    static func pin(_ image: CGImage, scale: CGFloat, at rect: CGRect? = nil) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var frame: CGRect
        if let rect, NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
            frame = rect
        } else {
            let s = NSScreen.withMouse.visibleFrame
            var fit = size
            let k = min(1, s.width * 0.7 / size.width, s.height * 0.7 / size.height)
            fit = CGSize(width: size.width * k, height: size.height * k)
            frame = CGRect(x: s.midX - fit.width / 2, y: s.midY - fit.height / 2, width: fit.width, height: fit.height)
        }
        let w = PinWindow(image: image, scale: scale, frame: frame)
        all.append(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @MainActor static func closeAll() { all.forEach { $0.close() } }
    @MainActor static func unlockAll() { all.forEach { $0.setLocked(false) } }
    @MainActor static var count: Int { all.count }

    init(image: CGImage, scale: CGFloat, frame: CGRect) {
        self.image = image
        self.scale = scale
        aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = NSSize(width: 1, height: aspect)
        minSize = NSSize(width: 60, height: 60 * aspect)

        let v = PinView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.contents = image
        v.layer?.contentsGravity = .resizeAspect
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.autoresizingMask = [.width, .height]
        v.owner = self
        contentView = v
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        MainActor.assumeIsolated { PinWindow.all.removeAll { $0 === self } }
    }

    func setLocked(_ on: Bool) {
        locked = on
        ignoresMouseEvents = on
        if on { HUD.show("Пін заблоковано", symbol: "lock.fill", detail: "Розблокувати: меню Kadr → Розблокувати піни") }
    }

    func zoom(by factor: CGFloat, around p: CGPoint? = nil) {
        var f = frame
        let newW = min(max(f.width * factor, 60), 8000)
        let newH = newW * aspect
        let anchor = p ?? CGPoint(x: f.midX, y: f.midY)
        let rx = (anchor.x - f.minX) / f.width, ry = (anchor.y - f.minY) / f.height
        f.origin.x = anchor.x - newW * rx
        f.origin.y = anchor.y - newH * ry
        f.size = CGSize(width: newW, height: newH)
        setFrame(f, display: true)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53, 51: close()                                  // Esc / Delete
        case 24, 69: zoom(by: 1.1)                            // + / =
        case 27, 78: zoom(by: 1 / 1.1)                        // -
        case 29: zoom(by: (CGFloat(image.width) / scale) / frame.width)   // 0 = 100%
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage() } else { super.keyDown(with: event) }
        }
    }

    @objc func copyImage() { Clipboard.copy(image, scale: scale); HUD.show("Скопійовано") }
    @objc func saveImage() {
        let url = Storage.newURL(ext: Storage.imageExt)
        do { try Storage.write(image, scale: scale, to: url); History.add(url); HUD.show("Збережено", detail: url.lastPathComponent) }
        catch { HUD.error("Не вдалося зберегти") }
    }
    @objc func annotate() {
        EditorWindowController.open(CaptureItem(image: image, scale: scale))
        close()
    }
    @objc func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc func lock() { setLocked(true) }
    @objc func actualSize() { zoom(by: (CGFloat(image.width) / scale) / frame.width) }
    @objc func closePin() { close() }
}

private final class PinView: NSView {
    weak var owner: PinWindow?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
        owner?.zoom(by: 1 + delta, around: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) { owner?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.close(); return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let o = owner else { return nil }
        let m = NSMenu()
        func item(_ t: String, _ s: Selector, _ k: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: k); i.target = o; return i
        }
        m.addItem(item("Копіювати", #selector(PinWindow.copyImage), "c"))
        m.addItem(item("Зберегти", #selector(PinWindow.saveImage)))
        m.addItem(item("Редагувати", #selector(PinWindow.annotate)))
        m.addItem(item("Справжній розмір", #selector(PinWindow.actualSize), "0"))
        let op = NSMenuItem(title: "Прозорість", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 75, 50, 25] {
            let i = item("\(v)%", #selector(PinWindow.setOpacity(_:)))
            i.tag = v
            i.state = Int((o.alphaValue * 100).rounded()) == v ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        m.addItem(item("Заблокувати (клік крізь пін)", #selector(PinWindow.lock)))
        m.addItem(.separator())
        m.addItem(item("Закрити", #selector(PinWindow.closePin)))
        return m
    }
}
