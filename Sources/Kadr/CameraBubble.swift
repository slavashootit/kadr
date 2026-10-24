import AppKit
import AVFoundation

/// Round webcam overlay. It is a normal on-screen window, so it ends up in the recording.
@MainActor
final class CameraBubble {
    static let shared = CameraBubble()

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private(set) var deviceID: String?
    var isVisible: Bool { panel != nil }
    /// While the recording frame is being set up, the bubble sits above its dimmed overlay to stay draggable.
    var raised = false { didSet { panel?.level = level } }
    private var level: NSWindow.Level { raised ? .screenSaver : .floating }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// Shows (or switches) the bubble. Returns an error message on failure.
    @discardableResult
    func show(deviceID id: String, near rect: CGRect) async -> String? {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            return "Немає доступу до камери — дозволь у Параметрах → Приватність → Камера"
        }
        let device = id.isEmpty ? AVCaptureDevice.default(for: .video) : (AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .video))
        guard let device else { return "Камеру не знайдено" }
        if panel != nil, deviceID == device.uniqueID { return nil }

        let s = AVCaptureSession()
        s.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { return "Камера зайнята" }
            s.addInput(input)
        } catch {
            return error.localizedDescription
        }

        let size: CGFloat = 200
        let frame = panel?.frame ?? CGRect(x: rect.maxX - size - 24, y: rect.minY + 24, width: size, height: size)
        stopSession()
        panel?.orderOut(nil)

        let p = BubblePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = level
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let v = BubbleView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        let preview = AVCaptureVideoPreviewLayer(session: s)
        preview.videoGravity = .resizeAspectFill
        preview.frame = v.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        v.layer?.addSublayer(preview)
        v.layer?.cornerRadius = frame.width / 2
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 3
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        p.contentView = v
        p.orderFrontRegardless()

        panel = p
        session = s
        deviceID = device.uniqueID
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        return nil
    }

    func hide() {
        stopSession()
        panel?.orderOut(nil)
        panel = nil
        deviceID = nil
    }

    private func stopSession() {
        if let s = session { DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() } }
        session = nil
    }
}

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Scroll or pinch to resize the bubble.
private final class BubbleView: NSView {
    private func resize(by f: CGFloat) {
        guard let w = window else { return }
        let side = min(max(w.frame.width * f, 100), 520)
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side), display: true)
        layer?.cornerRadius = side / 2
    }

    override func scrollWheel(with event: NSEvent) {
        resize(by: 1 + (event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08))
    }

    override func magnify(with event: NSEvent) { resize(by: 1 + event.magnification) }
}
