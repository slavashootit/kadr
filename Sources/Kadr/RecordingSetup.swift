import AppKit
import AVFoundation
import SwiftUI

/// Pre-recording panel: check audio levels, pick mic/camera and overlays, then start.
@MainActor
final class RecordingSetup {
    private var panel: NSPanel?
    private let meter = AudioMeter()
    private var continuation: CheckedContinuation<Bool?, Never>?
    private let areaRect: CGRect   // global AppKit coords
    private var gif: Bool

    private init(gif: Bool, areaRect: CGRect) {
        self.gif = gif
        self.areaRect = areaRect
    }

    /// Returns the chosen mode (true = GIF) or nil if cancelled.
    static func run(gif: Bool, areaRect: CGRect, screen: NSScreen) async -> Bool? {
        let s = RecordingSetup(gif: gif, areaRect: areaRect)
        return await s.present(on: screen)
    }

    private func present(on screen: NSScreen) async -> Bool? {
        await withCheckedContinuation { c in
            continuation = c
            let view = RecordingSetupView(
                meter: meter,
                gif: gif,
                pixelSize: CGSize(width: areaRect.width * screen.backingScaleFactor, height: areaRect.height * screen.backingScaleFactor),
                onAudioChange: { [weak self] gif in self?.gif = gif; self?.refreshAudio() },
                onCameraChange: { [weak self] in await self?.refreshCamera() },
                onStart: { [weak self] gif in self?.finish(gif) },
                onCancel: { [weak self] in self?.finish(nil) })
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let vis = screen.visibleFrame
            var origin = CGPoint(x: areaRect.midX - size.width / 2, y: areaRect.midY - size.height / 2)
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)

            let p = KeyPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.identifier = Exclusion.identifier
            p.isReleasedWhenClosed = false
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.appearance = NSAppearance(named: .darkAqua)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = host
            panel = p
            p.makeKeyAndOrderFront(nil)
            NSApp.activate()
            refreshAudio()
            Task { _ = await refreshCamera() }
        }
    }

    private func refreshAudio() {
        let mic = !gif && Prefs.recordMic ? Prefs.recordMicID : nil
        let sys = !gif && Prefs.recordSystemAudio
        Task { await meter.start(micID: mic, system: sys) }
    }

    private func refreshCamera() async -> String? {
        if Prefs.recordCamera {
            return await CameraBubble.shared.show(deviceID: Prefs.recordCameraID, near: areaRect)
        }
        CameraBubble.shared.hide()
        return nil
    }

    private func finish(_ result: Bool?) {
        guard let c = continuation else { return }
        continuation = nil
        meter.stop()
        panel?.orderOut(nil)
        panel = nil
        if result == nil { CameraBubble.shared.hide() }
        c.resume(returning: result)
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct RecordingSetupView: View {
    @ObservedObject var meter: AudioMeter
    @State var gif: Bool
    let pixelSize: CGSize
    let onAudioChange: (Bool) -> Void
    let onCameraChange: () async -> String?
    let onStart: (Bool) -> Void
    let onCancel: () -> Void

    @AppStorage(PrefKey.recordMic) private var mic = false
    @AppStorage(PrefKey.recordMicID) private var micID = ""
    @AppStorage(PrefKey.recordSystemAudio) private var systemAudio = true
    @AppStorage(PrefKey.recordCamera) private var camera = false
    @AppStorage(PrefKey.recordCameraID) private var cameraID = ""
    @AppStorage(PrefKey.recordCursor) private var cursor = true
    @AppStorage(PrefKey.recordClicks) private var clicks = true
    @AppStorage(PrefKey.recordKeys) private var keys = false
    @AppStorage(PrefKey.recordFPS) private var fps = 60
    @AppStorage(PrefKey.recordCountdown) private var countdown = 3
    @AppStorage(PrefKey.recordHideDesktop) private var hideDesktop = false
    @AppStorage(PrefKey.afterRecordOpenEditor) private var openEditor = true
    @State private var cameraError: String?

    private let mics = AudioMeter.microphones
    private let cams = CameraBubble.cameras

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text("Запис екрана").font(.headline)
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $gif) {
                    Text("Відео").tag(false)
                    Text("GIF").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }

            group("Звук") {
                if gif {
                    Text("GIF пишеться без звуку").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Мікрофон", isOn: $mic).frame(width: 130, alignment: .leading)
                            Picker("", selection: $micID) {
                                Text("Типовий").tag("")
                                ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }
                            .labelsHidden()
                            .disabled(!mic)
                        }
                        if mic { LevelBar(level: meter.mic) }
                        if mic, let e = meter.micError { Text(e).font(.caption).foregroundStyle(.orange) }
                        Toggle("Системний звук", isOn: $systemAudio)
                        if systemAudio { LevelBar(level: meter.system) }
                        if systemAudio, let e = meter.systemError { Text(e).font(.caption).foregroundStyle(.orange) }
                        if mic || systemAudio {
                            Text("Скажи щось або ввімкни звук — смужка має рухатись.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            group("Камера") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("Вебкамера", isOn: $camera).frame(width: 130, alignment: .leading)
                        Picker("", selection: $cameraID) {
                            Text("Типова").tag("")
                            ForEach(cams, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        .labelsHidden()
                        .disabled(!camera)
                    }
                    if camera { Text("Кружечок можна перетягнути, скрол — розмір.").font(.caption).foregroundStyle(.secondary) }
                    if let cameraError { Text(cameraError).font(.caption).foregroundStyle(.orange) }
                }
            }

            group("У кадрі") {
                HStack(spacing: 14) {
                    Toggle("Курсор", isOn: $cursor)
                    Toggle("Кліки", isOn: $clicks)
                    Toggle("Клавіші", isOn: $keys)
                    Toggle("Сховати іконки", isOn: $hideDesktop)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 16) {
                LabeledContent("Відлік") {
                    Picker("", selection: $countdown) {
                        Text("Ні").tag(0)
                        Text("3 с").tag(3)
                        Text("5 с").tag(5)
                        Text("10 с").tag(10)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                LabeledContent("FPS") {
                    Picker("", selection: $fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                }
            }
            .font(.callout)

            Toggle("Після запису відкрити відеоредактор", isOn: $openEditor).toggleStyle(.checkbox)

            HStack {
                Button("Скасувати") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button { onStart(gif) } label: {
                    Label("Почати запис", systemImage: "record.circle.fill").frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12)))
        .onChange(of: gif) { onAudioChange(gif) }
        .onChange(of: mic) { onAudioChange(gif) }
        .onChange(of: micID) { onAudioChange(gif) }
        .onChange(of: systemAudio) { onAudioChange(gif) }
        .onChange(of: camera) { Task { cameraError = await onCameraChange() } }
        .onChange(of: cameraID) { Task { cameraError = await onCameraChange() } }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(4, g.size.width * CGFloat(level)))
                    }
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 8)
    }
}
