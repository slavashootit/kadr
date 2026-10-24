import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Screen recording via ScreenCaptureKit's SCRecordingOutput (macOS 15+).
/// Pause and the mic toggle split the take into parts (one stream each); stop glues them into one MP4.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()
    static let waveBars = 22

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micAvailable = false
    @Published private(set) var micOn = false
    @Published private(set) var micLevels = [Float](repeating: 0, count: Recorder.waveBars)
    @Published private(set) var micSilent = false   // mic is on, but no samples arrive
    private(set) var asGIF = false

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var proxy: RecorderProxy?
    private var area: (rect: CGRect, screen: NSScreen)?
    private var fileURL: URL?
    private var parts: [URL] = []
    private var recordedBefore: TimeInterval = 0    // duration of the finished parts
    private var partStart: Date?
    private var switching = false
    private var preparing = false   // frame editor / setup / countdown on screen
    private var micPeak: Float = 0
    private var lastMicSample: Date?
    private var ticker: Timer?
    private var chrome: [NSWindow] = []
    private var controlPanel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var cancelled = false
    private var hidDesktop = false
    var onStateChange: (() -> Void)?

    func toggle(gif: Bool) {
        if isRecording { Task { await stop() } } else { Task { await start(gif: gif) } }
    }

    func start(gif: Bool) async {
        guard !isRecording, !preparing else { return }
        preparing = true
        defer { preparing = false }
        guard Capture.hasPermission() else { Capture.showPermissionAlert(); return }
        // Start from the whole screen under the mouse; the frame is resized right there while setting up.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = RecordingArea(screen: screen)
        let editor = AreaEditor(area: area)
        editor.show()
        cancelled = false
        CameraBubble.shared.raised = true
        let chosen = await RecordingSetup.run(gif: gif, area: area)
        CameraBubble.shared.raised = false
        editor.close()
        guard let chosenGIF = chosen else { CameraBubble.shared.hide(); return }

        var rect = area.rect.integral   // display-local top-left points
        // Encoders want even pixel dimensions.
        rect.size.width -= rect.width.truncatingRemainder(dividingBy: 2)
        rect.size.height -= rect.height.truncatingRemainder(dividingBy: 2)
        guard rect.width >= 16, rect.height >= 16 else { CameraBubble.shared.hide(); return }
        showBorder(rect: rect, on: screen)
        asGIF = chosenGIF
        micAvailable = !asGIF && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micOn = micAvailable && Prefs.recordMic
        micLevels = [Float](repeating: 0, count: Self.waveBars)
        if Prefs.recordMic, !asGIF, !micAvailable {
            HUD.error("Немає доступу до мікрофона — пишу без нього")
        }
        if Prefs.recordHideDesktop, !DesktopIcons.shared.isHidden {
            DesktopIcons.shared.hide()
            hidDesktop = true
        }
        showControlPanel(rect: rect, on: screen)
        await Countdown.run(seconds: Prefs.recordCountdown, on: screen)
        let gif = asGIF

        do {
            try await begin(rect: rect, screen: screen, gif: gif)
        } catch {
            tearDownChrome()
            restoreScene()
            HUD.error("Запис не стартував: \(error.localizedDescription)")
        }
    }

    private func begin(rect: CGRect, screen: NSScreen, gif: Bool) async throws {
        area = (rect, screen)
        // With the editor on, keep the MP4 even in GIF mode: the GIF is made on export.
        let keepVideo = !gif || Prefs.afterRecordOpenEditor
        fileURL = Storage.newURL(prefix: "Kadr Recording", ext: "mp4", in: keepVideo ? nil : Storage.tempDir)
        parts = []
        recordedBefore = 0
        elapsed = 0
        isPaused = false

        try await startPart()
        isRecording = true
        Sound.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        startInputOverlays(screen: screen)
        onStateChange?()
    }

    /// Starts a stream that writes the next part of the take.
    private func startPart() async throws {
        guard let (rect, screen) = area, let fileURL else { return }
        let gif = asGIF
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
            cfg.captureMicrophone = micOn
            if cfg.captureMicrophone, let mic = AudioMeter.microphone(id: Prefs.recordMicID) {
                cfg.microphoneCaptureDeviceID = mic.uniqueID
            }
        }

        let base = fileURL.deletingPathExtension().lastPathComponent
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("\(base) part\(parts.count + 1).mp4")
        try? FileManager.default.removeItem(at: url)
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
        // The meter reads the very samples that go into the file, so a moving wave means sound is recorded.
        proxy.onMicLevel = { [weak self] level in
            Task { @MainActor in self?.micSample(level) }
        }
        proxy.onStop = { [weak self, weak proxy] error in
            Task { @MainActor in
                // Only a failure of the live part ends the take; parts stopped on purpose are ignored.
                guard let self, self.isRecording, let proxy, self.proxy === proxy else { return }
                if let error { HUD.error("Запис зупинено: \(error.localizedDescription)") }
                await self.stop()
            }
        }

        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.proxy = proxy
        parts.append(url)
        partStart = Date()
        lastMicSample = nil
    }

    /// Stops the live stream and waits until its part is written.
    private func stopPart() async {
        guard let stream else { return }
        let output = self.output
        let proxy = self.proxy
        self.stream = nil
        self.output = nil
        self.proxy = nil
        if let d = partStart { recordedBefore += Date().timeIntervalSince(d) }
        partStart = nil
        try? await stream.stopCapture()
        await proxy?.waitForFinish(timeout: 5)
        withExtendedLifetime(output) {}
    }

    func togglePause() async {
        isPaused ? await resume() : await pause()
    }

    func pause() async {
        guard isRecording, !isPaused, !switching else { return }
        switching = true
        defer { switching = false }
        isPaused = true
        await stopPart()
        onStateChange?()
    }

    func resume() async {
        guard isRecording, isPaused, !switching else { return }
        switching = true
        defer { switching = false }
        do {
            try await startPart()
            isPaused = false
        } catch {
            HUD.error("Не вдалося продовжити запис: \(error.localizedDescription)")
        }
        onStateChange?()
    }

    /// Mic on/off mid-take: the stream is restarted with the new setting (on pause it applies on resume).
    func toggleMic() {
        guard micAvailable, !switching else { return }
        micOn.toggle()
        guard isRecording, !isPaused else { return }
        switching = true   // set before the task starts, so a quick second tap is ignored
        Task {
            defer { switching = false }
            await stopPart()
            do {
                try await startPart()
            } catch {
                isPaused = true
                HUD.error("Запис на паузі: \(error.localizedDescription)")
                onStateChange?()
            }
        }
    }

    private func micSample(_ level: Float) {
        micPeak = max(micPeak, level)
        lastMicSample = Date()
    }

    private func tick() {
        let shown = Int(elapsed)
        elapsed = recordedBefore + (partStart.map { Date().timeIntervalSince($0) } ?? 0)
        let live = micOn && stream != nil
        micLevels.removeFirst()
        micLevels.append(live ? micPeak : 0)
        micPeak = 0
        // A fresh part gets a moment to deliver its first mic samples.
        let silent = live && (lastMicSample ?? partStart).map { Date().timeIntervalSince($0) > 1.5 } == true
        if silent != micSilent { micSilent = silent }
        if Int(elapsed) != shown { onStateChange?() }
    }

    func cancel() async {
        cancelled = true
        await stop()
    }

    func stop() async {
        guard isRecording else { return }
        while switching { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        ticker?.invalidate()
        ticker = nil
        stopInputOverlays()
        tearDownChrome()
        restoreScene()
        onStateChange?()

        await stopPart()
        let recorded = parts.filter { FileManager.default.fileExists(atPath: $0.path) }
        parts = []
        area = nil

        guard let url = fileURL else { return }
        fileURL = nil
        if cancelled {
            recorded.forEach { try? FileManager.default.removeItem(at: $0) }
            HUD.show("Запис скасовано", symbol: "xmark.circle")
            return
        }
        guard !recorded.isEmpty else { HUD.error("Файл запису не створився"); return }
        if recorded.count > 1 { HUD.show("Склеюю запис…", symbol: "hourglass", seconds: 60) }
        do {
            try await Self.join(recorded, into: url)
        } catch {
            HUD.error("Не вдалося склеїти частини запису — вони лишились у теці")
            NSWorkspace.shared.activateFileViewerSelecting(recorded)
            return
        }

        if Prefs.afterRecordOpenEditor {
            History.add(url)
            VideoEditorWindowController.open(url, gif: asGIF)
        } else if asGIF {
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

    /// Glues the parts into one MP4 without re-encoding, then deletes them.
    private static func join(_ parts: [URL], into dest: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        if parts.count == 1 { try fm.moveItem(at: parts[0], to: dest); return }

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw KadrError.writeFailed
        }
        // Tracks only weakly reference their asset, so the assets are kept alive until the export ends.
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        var clips: [(video: AVAssetTrack, range: CMTimeRange, audio: AVAssetTrack?)] = []
        var audioFormat: CMFormatDescription?
        for part in parts {
            let asset = AVURLAsset(url: part)
            assets.append(asset)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let vr = try await v.load(.timeRange)
            guard vr.duration > .zero else { continue }
            let a = try await asset.loadTracks(withMediaType: .audio).first
            if audioFormat == nil, let a { audioFormat = try await a.load(.formatDescriptions).first }
            clips.append((v, vr, a))
        }
        guard let first = clips.first else { throw KadrError.writeFailed }
        cv.preferredTransform = try await first.video.load(.preferredTransform)

        var fillers: [URL] = []
        defer { fillers.forEach { try? fm.removeItem(at: $0) } }
        var cursor = CMTime.zero
        for clip in clips {
            try cv.insertTimeRange(clip.range, of: clip.video, at: cursor)
            var audio = clip.audio
            if audio == nil, let audioFormat {
                // A part recorded with the mic and system sound off has no audio track. An empty stretch would
                // only be an edit-list gap that many editors pull the following sound into, so write real silence.
                let url = try await silence(duration: clip.range.duration, like: audioFormat)
                fillers.append(url)
                let asset = AVURLAsset(url: url)
                assets.append(asset)
                audio = try await asset.loadTracks(withMediaType: .audio).first
            }
            if let audio {
                let ar = try await audio.load(.timeRange)
                try ca.insertTimeRange(CMTimeRange(start: ar.start, duration: CMTimeMinimum(ar.duration, clip.range.duration)), of: audio, at: cursor)
            }
            cursor = cursor + clip.range.duration
        }
        if audioFormat == nil { comp.removeTrack(ca) }

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw KadrError.writeFailed }
        do {
            try await session.export(to: dest, as: .mp4)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        parts.forEach { try? fm.removeItem(at: $0) }
    }

    /// A temporary AAC file of digital silence in the same sample rate and channel count as `format`.
    private static func silence(duration: CMTime, like format: CMFormatDescription) async throws -> URL {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let rate = asbd?.mSampleRate ?? 48_000
        let channels = Int(max(1, asbd?.mChannelsPerFrame ?? 2))
        let url = Storage.newURL(prefix: "Kadr Silence", ext: "m4a", in: Storage.tempDir)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? KadrError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        var pcm = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                              mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
                                              mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                              mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &pcm, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard let fmt else { throw KadrError.writeFailed }

        // Slightly longer than the gap: the composition trims it, and AAC priming never leaves a hole.
        let total = Int((duration.seconds + 0.2) * rate)
        let chunk = 4096
        var written = 0
        while written < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let frames = min(chunk, total - written)
            let bytes = frames * 2 * channels
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let block else { throw KadrError.writeFailed }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, input.append(sample) else { throw writer.error ?? KadrError.writeFailed }
            written += frames
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? KadrError.writeFailed }
        return url
    }

    private func deliver(_ url: URL) {
        History.add(url)
        if Prefs.afterCopy { Clipboard.copy(file: url) }
        if Prefs.afterRecord == "panel" {
            QuickAccess.shared.show(CaptureItem(video: url))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            HUD.show("Запис збережено", detail: url.lastPathComponent)
        }
    }

    /// Undo what the recording session changed on screen (camera bubble, hidden icons).
    private func restoreScene() {
        CameraBubble.shared.hide()
        if hidDesktop { DesktopIcons.shared.show(); hidDesktop = false }
    }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Chrome (border + control panel), excluded from the capture

    private func showBorder(rect: CGRect, on screen: NSScreen) {
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
    }

    private func showControlPanel(rect: CGRect, on screen: NSScreen) {
        let g = screen.globalRect(fromTopLeft: rect)
        let host = NSHostingView(rootView: RecordingControls(recorder: self))
        let size = host.fittingSize
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
        panel.contentView = host
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
    var onMicLevel: ((Float) -> Void)?
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .microphone else { return }
        onMicLevel?(AudioLevel.level(of: sampleBuffer))
    }

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
            Circle().fill(recorder.isPaused ? Color.orange : Color.red).frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.4)
            Text(recorder.isRecording ? recorder.elapsedString : "Готуюсь…")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(recorder.isPaused ? Color.orange : Color.white)
                .frame(width: 58, alignment: .leading)
            if recorder.micAvailable {
                MicWave(levels: recorder.micLevels, muted: !recorder.micOn, silent: recorder.micSilent)
                    .help(!recorder.micOn ? "Мікрофон вимкнено" : recorder.micSilent ? "Мікрофон не дає сигналу" : "Рівень мікрофона у записі")
                roundButton(recorder.micOn ? "mic.fill" : "mic.slash.fill", tint: recorder.micOn ? .white : .red) {
                    recorder.toggleMic()
                }
                .help(recorder.micOn ? "Вимкнути мікрофон" : "Увімкнути мікрофон")
            }
            roundButton(recorder.isPaused ? "play.fill" : "pause.fill", tint: .white) {
                Task { await recorder.togglePause() }
            }
            .disabled(!recorder.isRecording)
            .opacity(recorder.isRecording ? 1 : 0.4)
            .help(recorder.isPaused ? "Продовжити запис" : "Пауза")
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
        .frame(height: 40)
        .fixedSize()
        .background(Capsule().fill(Color.black.opacity(0.85)))
    }

    private func roundButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Scrolling bars of the recorded mic level: flat when muted, orange when the mic is on but silent.
private struct MicWave: View {
    let levels: [Float]
    let muted: Bool
    let silent: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: muted ? 2 : max(2, CGFloat(pow(levels[i], 1.6)) * 22))
            }
        }
        .frame(height: 22)
    }

    private var color: Color {
        if muted { return .white.opacity(0.3) }
        if silent { return .orange }
        return Color(red: 0.35, green: 0.9, blue: 0.5)
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
