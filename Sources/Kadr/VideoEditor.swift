import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class VideoEditorModel: ObservableObject {
    enum Format: String, CaseIterable { case mp4, gif }
    enum Quality: Int, CaseIterable { case high, medium, low }

    let url: URL
    let asset: AVURLAsset
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var current: Double = 0
    @Published var playing = false
    @Published var thumbnails: [NSImage] = []
    @Published var hasAudio = false
    @Published var muted = false { didSet { player.isMuted = muted } }
    @Published var speed: Double = 1 { didSet { if playing { player.rate = Float(speed) } } }
    @Published var format: Format
    @Published var quality: Quality = .high
    @Published var exporting = false
    @Published var videoSize: CGSize = .zero
    @Published var fileSize: Int64 = 0

    private var timeObserver: Any?

    init(url: URL, gif: Bool) {
        self.url = url
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        format = gif ? .gif : .mp4
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        Task { await load() }
    }

    func teardown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = nil
    }

    private func load() async {
        guard let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 else { return }
        duration = d
        end = d
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        if let v = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await v.load(.naturalSize), let tf = try? await v.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(tf)
            videoSize = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 260, height: 260)
        let tol = CMTime(seconds: max(0.1, d / 40), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let n = 14
        var thumbs: [NSImage] = []
        for i in 0..<n {
            let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
            if let r = try? await gen.image(at: t) {
                let cg = r.image
                thumbs.append(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
            }
        }
        thumbnails = thumbs
    }

    private func tick(_ t: Double) {
        current = t
        if playing, t >= end - 0.02 {
            player.pause()
            playing = false
            seek(start)
        }
    }

    func togglePlay() {
        if playing {
            player.pause()
            playing = false
        } else {
            if current < start || current >= end - 0.05 { seek(start) }
            player.rate = Float(speed)
            playing = true
        }
    }

    func seek(_ t: Double) {
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart(_ t: Double) { start = min(max(0, t), end - 0.2); seek(start) }
    func setEnd(_ t: Double) { end = max(min(duration, t), start + 0.2); seek(end) }

    var selectedDuration: Double { max(0, end - start) / speed }

    func qualityTitle(_ q: Quality) -> String {
        switch (format, q) {
        case (.mp4, .high): return "Оригінал"
        case (.mp4, .medium): return "1080p"
        case (.mp4, .low): return "720p"
        case (.gif, .high): return "1280"
        case (.gif, .medium): return "960"
        case (.gif, .low): return "640"
        }
    }

    var isTrimmed: Bool { start > 0.01 || end < duration - 0.01 }

    // MARK: Export

    /// Exports the edit to a new file in the captures folder.
    func export() async throws -> URL {
        exporting = true
        defer { exporting = false }

        let comp = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        guard let v = try await asset.loadTracks(withMediaType: .video).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw KadrError.nothingToDo("У файлі немає відео")
        }
        try cv.insertTimeRange(range, of: v, at: .zero)
        cv.preferredTransform = try await v.load(.preferredTransform)
        if !muted && format == .mp4 {
            for a in try await asset.loadTracks(withMediaType: .audio) {
                let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try ca?.insertTimeRange(range, of: a, at: .zero)
            }
        }
        if abs(speed - 1) > 0.01 {
            let d = range.duration
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: d), toDuration: CMTimeMultiplyByFloat64(d, multiplier: 1 / speed))
        }

        let preset: String
        switch (format, quality) {
        case (.mp4, .medium): preset = AVAssetExportPreset1920x1080
        case (.mp4, .low): preset = AVAssetExportPreset1280x720
        default: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { throw KadrError.writeFailed }
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true

        let mp4 = Storage.newURL(prefix: "Kadr Edit", ext: "mp4", in: format == .gif ? Storage.tempDir : nil)
        try await session.export(to: mp4, as: .mp4)
        guard format == .gif else { return mp4 }

        let width: Int
        switch quality {
        case .high: width = 1280
        case .medium: width = 960
        case .low: width = 640
        }
        let tmpGIF = try await GIFExporter.export(video: mp4, fps: Prefs.gifFPS, maxWidth: width)
        let gif = Storage.newURL(prefix: "Kadr Edit", ext: "gif")
        try FileManager.default.moveItem(at: tmpGIF, to: gif)
        try? FileManager.default.removeItem(at: mp4)
        return gif
    }
}

@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [VideoEditorWindowController] = []

    static func open(_ url: URL, gif: Bool = false) {
        if let existing = openEditors.first(where: { $0.model.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let c = VideoEditorWindowController(url: url, gif: gif)
        openEditors.append(c)
        c.window?.center()
        c.showWindow(nil)
        NSApp.activate()
    }

    let model: VideoEditorModel

    init(url: URL, gif: Bool) {
        model = VideoEditorModel(url: url, gif: gif)
        let vis = NSScreen.withMouse.visibleFrame
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: min(1000, vis.width * 0.9), height: min(720, vis.height * 0.9)),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = url.lastPathComponent
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 480)
        win.appearance = NSAppearance(named: .darkAqua)
        super.init(window: win)
        win.delegate = self
        win.contentView = NSHostingView(rootView: VideoEditorView(model: model) { [weak self] action in self?.handle(action) })
    }

    required init?(coder: NSCoder) { fatalError() }

    enum Action { case save, copy, share, reveal }

    private func handle(_ action: Action) {
        if action == .reveal { NSWorkspace.shared.activateFileViewerSelecting([model.url]); return }
        model.player.pause()
        model.playing = false
        Task {
            do {
                let out = try await model.export()
                History.add(out)
                switch action {
                case .copy:
                    Clipboard.copy(file: out)
                    HUD.show("Збережено й скопійовано", detail: out.lastPathComponent)
                case .share:
                    let picker = NSSharingServicePicker(items: [out])
                    if let v = window?.contentView { picker.show(relativeTo: CGRect(x: v.bounds.maxX - 120, y: 10, width: 1, height: 1), of: v, preferredEdge: .maxY) }
                default:
                    if Prefs.afterCopy { Clipboard.copy(file: out) }
                    HUD.show("Збережено", detail: out.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                HUD.error("Експорт не вдався: \(error.localizedDescription)")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.teardown()
        Self.openEditors.removeAll { $0 === self }
    }
}

// MARK: - Views

private struct PlayerHost: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let action: (VideoEditorWindowController.Action) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerHost(player: model.player)
                    .onTapGesture { model.togglePlay() }
                if model.exporting {
                    Color.black.opacity(0.55)
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Експортую…").foregroundStyle(.white)
                    }
                }
            }

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 22)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Пробіл")
                    Text(timeString(model.current)).monospacedDigit().frame(width: 64, alignment: .leading)
                    TrimTimeline(model: model)
                    Text(timeString(model.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    Button("Початок тут") { model.setStart(model.current) }.keyboardShortcut("i", modifiers: []).help("I")
                    Button("Кінець тут") { model.setEnd(model.current) }.keyboardShortcut("o", modifiers: []).help("O")
                    if model.isTrimmed {
                        Button("Скинути") { model.start = 0; model.end = model.duration }
                    }
                    Text("Вибрано \(timeString(model.selectedDuration))").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(sizeInfo).font(.caption).foregroundStyle(.tertiary)
                }
                .controlSize(.small)

                Divider()

                HStack(spacing: 18) {
                    LabeledContent("Формат") {
                        Picker("", selection: $model.format) {
                            Text("MP4").tag(VideoEditorModel.Format.mp4)
                            Text("GIF").tag(VideoEditorModel.Format.gif)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    }
                    LabeledContent(model.format == .gif ? "Ширина" : "Якість") {
                        Picker("", selection: $model.quality) {
                            ForEach(VideoEditorModel.Quality.allCases, id: \.self) { Text(model.qualityTitle($0)).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                    LabeledContent("Швидкість") {
                        Picker("", selection: $model.speed) {
                            Text("0.5×").tag(0.5)
                            Text("1×").tag(1.0)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    }
                    if model.hasAudio && model.format == .mp4 {
                        Toggle("Без звуку", isOn: $model.muted).toggleStyle(.checkbox)
                    }
                    Spacer()
                }
                .font(.callout)

                HStack {
                    Button { action(.reveal) } label: { Label("Оригінал у Finder", systemImage: "folder") }
                    Spacer()
                    Button { action(.share) } label: { Label("Поділитися", systemImage: "square.and.arrow.up") }
                    Button { action(.copy) } label: { Label("Зберегти й копіювати", systemImage: "doc.on.doc") }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button { action(.save) } label: { Label("Зберегти", systemImage: "square.and.arrow.down") }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .disabled(model.exporting)
            }
            .padding(16)
            .background(Color(white: 0.15))
        }
    }

    private var sizeInfo: String {
        let s = model.videoSize
        let mb = Double(model.fileSize) / 1_048_576
        return s == .zero ? "" : "\(Int(s.width))×\(Int(s.height)) · оригінал \(String(format: "%.1f", mb)) МБ"
    }
}

func timeString(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00.0" }
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}

private struct TrimTimeline: View {
    @ObservedObject var model: VideoEditorModel
    private let height: CGFloat = 54
    private let handle: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(model.duration, 0.001)
            let xs = CGFloat(model.start / d) * w
            let xe = CGFloat(model.end / d) * w
            let xc = CGFloat(model.current / d) * w

            ZStack(alignment: .topLeading) {
                // Filmstrip (scrub by clicking/dragging)
                HStack(spacing: 0) {
                    ForEach(model.thumbnails.indices, id: \.self) { i in
                        Image(nsImage: model.thumbnails[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(max(1, model.thumbnails.count)), height: height)
                            .clipped()
                    }
                }
                .frame(width: w, height: height, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                    model.seek(Double(min(max(0, v.location.x), w) / w) * d)
                })

                // Dim outside the selection
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, xs), height: height)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, w - xe), height: height)
                    .offset(x: xe)
                    .allowsHitTesting(false)

                // Selection frame
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(handle * 2, xe - xs), height: height)
                    .offset(x: xs)
                    .allowsHitTesting(false)

                // Playhead
                Rectangle().fill(Color.white)
                    .frame(width: 2, height: height + 8)
                    .offset(x: xc - 1, y: -4)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)

                handleView(left: true)
                    .offset(x: xs)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        model.setStart(Double(min(max(0, v.location.x), w) / w) * d)
                    })
                handleView(left: false)
                    .offset(x: xe - handle)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        model.setEnd(Double(min(max(0, v.location.x), w) / w) * d)
                    })
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: height)
    }

    private func handleView(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: handle, height: height)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}
