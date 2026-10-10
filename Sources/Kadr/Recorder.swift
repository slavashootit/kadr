import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Screen recording via ScreenCaptureKit's SCRecordingOutput (macOS 15+).
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    private(set) var asGIF = false

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var proxy: RecorderProxy?
    private var fileURL: URL?
    private var startDate: Date?
    private var ticker: Timer?
    private var chrome: [NSWindow] = []
    private var controlPanel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var cancelled = false
    var onStateChange: (() -> Void)?

    func toggle(gif: Bool) {
        if isRecording { Task { await stop() } } else { Task { await start(gif: gif) } }
    }

    func start(gif: Bool) async {
        guard !isRecording else { return }
        guard let sel = await SelectionController.run(mode: .area, allowWindowMode: true, hint: gif ? "Запис GIF" : "Запис відео") else { return }

        var (screen, rect) = sel.screenAndRect   // rect: display-local top-left points
        // Encoders want even pixel dimensions.
        rect = rect.integral
        rect.size.width -= rect.width.truncatingRemainder(dividingBy: 2)
        rect.size.height -= rect.height.truncatingRemainder(dividingBy: 2)
        guard rect.width >= 16, rect.height >= 16 else { return }

        if Prefs.recordMic, !gif {
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { HUD.error("Немає доступу до мікрофона — пишу без нього") }
        }

        asGIF = gif
        cancelled = false
        showChrome(rect: rect, on: screen)
        await Countdown.run(seconds: 3, on: screen)

        do {
            try await begin(rect: rect, screen: screen, gif: gif)
        } catch {
            tearDownChrome()
            HUD.error("Запис не стартував: \(error.localizedDescription)")
        }
    }

    private func begin(rect: CGRect, screen: NSScreen, gif: Bool) async throws {
        let content = try await Capture.content()
        guard let display = Capture.display(for: screen, in: content) else { throw KadrError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: Capture.excludedWindows(in: content))

        let fullScreen = rect.size == screen.frame.size
        let scale = screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        if !fullScreen { cfg.sourceRect = rect }
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(gif ? min(Prefs.recordFPS, 30) : Prefs.recordFPS))
        cfg.showsCursor = Prefs.recordCursor
        cfg.queueDepth = 6
        cfg.captureResolution = .best
        cfg.colorSpaceName = CGColorSpace.sRGB
        if !gif {
            cfg.capturesAudio = Prefs.recordSystemAudio
            cfg.excludesCurrentProcessAudio = true
            cfg.captureMicrophone = Prefs.recordMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }

        let url = Storage.newURL(prefix: "Kadr Recording", ext: "mp4", in: gif ? Storage.tempDir : nil)
        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = Prefs.recordHEVC ? .hevc : .h264

        let proxy = RecorderProxy()
        let stream = SCStream(filter: filter, configuration: cfg, delegate: proxy)
        let output = SCRecordingOutput(configuration: recCfg, delegate: proxy)
        try stream.addRecordingOutput(output)
        // A screen output keeps frames flowing to the recording output.
        try stream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: proxy.queue)
        if cfg.capturesAudio { try stream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: proxy.queue) }
        if cfg.captureMicrophone { try stream.addStreamOutput(proxy, type: .microphone, sampleHandlerQueue: proxy.queue) }
        proxy.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let error { HUD.error("Запис зупинено: \(error.localizedDescription)") }
                await self.stop()
            }
        }

        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.proxy = proxy
        fileURL = url
        startDate = Date()
        elapsed = 0
        isRecording = true
        Sound.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let d = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(d)
                self.onStateChange?()
            }
        }
        startInputOverlays(screen: screen)
        onStateChange?()
    }

    func cancel() async {
        cancelled = true
        await stop()
    }

    func stop() async {
        guard isRecording, let stream else { return }
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        stopInputOverlays()
        tearDownChrome()
        onStateChange?()

        try? await stream.stopCapture()
        await proxy?.waitForFinish(timeout: 5)
        self.stream = nil
        self.output = nil
        self.proxy = nil

        guard let url = fileURL else { return }
        fileURL = nil
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            HUD.show("Запис скасовано", symbol: "xmark.circle")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { HUD.error("Файл запису не створився"); return }

        if asGIF {
            HUD.show("Конвертую в GIF…", symbol: "hourglass", seconds: 60)
            do {
                let tmp = try await GIFExporter.export(video: url)
                let dest = Storage.newURL(prefix: "Kadr Recording", ext: "gif")
                try FileManager.default.moveItem(at: tmp, to: dest)
                try? FileManager.default.removeItem(at: url)
                deliver(dest)
            } catch {
                HUD.error("GIF не вийшов: \(error.localizedDescription)")
                deliver(url)
            }
        } else {
            deliver(url)
        }
    }

    private func deliver(_ url: URL) {
        History.add(url)
        if Prefs.afterCopy { Clipboard.copy(file: url) }
        if Prefs.afterOverlay { QuickAccess.shared.show(CaptureItem(video: url)) } else { HUD.show("Запис збережено", detail: url.lastPathComponent) }
    }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Chrome (border + control panel), excluded from the capture

    private func showChrome(rect: CGRect, on screen: NSScreen) {
        let g = screen.globalRect(fromTopLeft: rect)
        let border = NSWindow(contentRect: g.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        border.identifier = Exclusion.identifier
        border.isReleasedWhenClosed = false
        border.level = .screenSaver
        border.backgroundColor = .clear
        border.isOpaque = false
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bv = NSView(frame: CGRect(origin: .zero, size: border.frame.size))
        bv.wantsLayer = true
        let dash = CAShapeLayer()
        dash.path = CGPath(rect: bv.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        dash.fillColor = nil
        dash.strokeColor = NSColor.systemRed.cgColor
        dash.lineWidth = 2
        dash.lineDashPattern = [8, 5]
        bv.layer?.addSublayer(dash)
        border.contentView = bv
        if rect.size != screen.frame.size { border.orderFrontRegardless(); chrome.append(border) }

        let size = CGSize(width: 214, height: 40)
        var origin = CGPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY + 4 { origin.y = min(g.maxY + 12, screen.visibleFrame.maxY - size.height - 4) }
        if origin.y + size.height > screen.visibleFrame.maxY || rect.size == screen.frame.size {
            origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 20)
        }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Exclusion.identifier
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingControls(recorder: self))
        panel.orderFrontRegardless()
        controlPanel = panel
        chrome.append(panel)
    }

    private func tearDownChrome() {
        chrome.forEach { $0.orderOut(nil) }
        chrome.removeAll()
        controlPanel = nil
    }

    // MARK: Click & keystroke overlays (these ARE recorded)

    private func startInputOverlays(screen: NSScreen) {
        if Prefs.recordClicks {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                let right = e.type == .rightMouseDown
                Task { @MainActor in ClickRipple.show(at: NSEvent.mouseLocation, right: right) }
            }
        }
        if Prefs.recordKeys {
            if !AXIsProcessTrusted() {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
            }
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { e in
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
                let combo = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: KeyCombo.carbon(mods), key: KeyCombo.keyName(for: e)).display
                Task { @MainActor in KeystrokeHUD.show(combo, on: screen) }
            }
        }
    }

    private func stopInputOverlays() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        keyMonitor = nil
        KeystrokeHUD.hide()
    }
}

/// Non-isolated delegate/output sink for ScreenCaptureKit callbacks.
final class RecorderProxy: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "kadr.recorder.samples")
    var onStop: ((Error?) -> Void)?
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { markFinished() }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        markFinished()
        onStop?(error)
    }

    private func markFinished() {
        lock.lock()
        finished = true
        let w = waiters
        waiters.removeAll()
        lock.unlock()
        w.forEach { $0.resume() }
    }

    func waitForFinish(timeout: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self.finished { self.lock.unlock(); c.resume(); return }
                    self.waiters.append(c)
                    self.lock.unlock()
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            _ = await group.next()
            group.cancelAll()
            // Release a still-pending waiter so the group can finish.
            self.markFinished()
        }
    }
}

private struct RecordingControls: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.4)
            Text(recorder.isRecording ? recorder.elapsedString : "Готуюсь…")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 58, alignment: .leading)
            Button { Task { await recorder.stop() } } label: {
                Label("Стоп", systemImage: "stop.fill").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Button { Task { await recorder.cancel() } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Скасувати й видалити")
        }
        .padding(.horizontal, 14)
        .frame(width: 214, height: 40)
        .background(Capsule().fill(Color.black.opacity(0.85)))
    }
}

@MainActor
enum ClickRipple {
    static func show(at p: CGPoint, right: Bool) {
        let d: CGFloat = 54
        let w = NSPanel(contentRect: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: CGRect(x: 0, y: 0, width: d, height: d))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        ring.frame = v.bounds
        ring.path = CGPath(ellipseIn: v.bounds.insetBy(dx: 4, dy: 4), transform: nil)
        let color = right ? NSColor.systemBlue : NSColor.systemYellow
        ring.fillColor = color.withAlphaComponent(0.35).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        v.layer?.addSublayer(ring)
        w.contentView = v
        w.orderFrontRegardless()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: d / 2, y: d / 2)
        ring.add(group, forKey: "ripple")
        Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); w.orderOut(nil) }
    }
}

@MainActor
enum KeystrokeHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, on screen: NSScreen) {
        hideWork?.cancel()
        let host = NSHostingView(rootView:
            Text(text).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75))))
        let size = host.fittingSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 80, width: size.width, height: size.height)
        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        panel = p
        p.contentView = host
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        let work = DispatchWorkItem { Task { @MainActor in KeystrokeHUD.panel?.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    static func hide() { panel?.orderOut(nil) }
}
