import AppKit
import AVFoundation
import SwiftUI

/// Pre-recording panel: check audio levels, pick mic/camera and overlays, then start.
@MainActor
final class RecordingSetup {
    private var panel: NSPanel?
    private let meter = AudioMeter()
    private var continuation: CheckedContinuation<Bool?, Never>?
    private let area: RecordingArea
    private var gif: Bool

    /// The area as it was when the panel opened, in global AppKit coords (places the panel and the camera).
    private var areaRect: CGRect { area.screen.globalRect(fromTopLeft: area.rect) }

    private init(gif: Bool, area: RecordingArea) {
        self.gif = gif
        self.area = area
    }

    /// Returns the chosen mode (true = GIF) or nil if cancelled. The area stays editable while the panel is open.
    static func run(gif: Bool, area: RecordingArea) async -> Bool? {
        let s = RecordingSetup(gif: gif, area: area)
        return await s.present(on: area.screen)
    }

    private func present(on screen: NSScreen) async -> Bool? {
        await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
            continuation = c
            let view = RecordingSetupView(
                meter: meter,
                gif: gif,
                area: area,
                onAudioChange: { [weak self] gif in self?.gif = gif; self?.refreshAudio() },
                onCameraChange: { [weak self] in await self?.refreshCamera() },
                onStart: { [weak self] gif in self?.finish(gif) },
                onCancel: { [weak self] in self?.finish(nil) })
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let areaRect = self.areaRect
            let vis = screen.visibleFrame
            // Sit outside the capture area: below it, else above, else inside along the bottom edge.
            var origin = CGPoint(x: areaRect.midX - size.width / 2, y: areaRect.minY - size.height - 12)
            if origin.y < vis.minY + 6 {
                origin.y = areaRect.maxY + 12
                if origin.y + size.height > vis.maxY - 6 { origin.y = max(vis.minY, areaRect.minY) + 24 }
            }
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)

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
    @Local var gif: Bool
    @ObservedObject var area: RecordingArea
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
    @AppStorage(PrefKey.afterRecord) private var afterRecord = "folder"
    @Local private var cameraError: String? = nil

    private let mics = AudioMeter.microphones
    private let cams = CameraBubble.cameras

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $gif) {
                Text("Відео").tag(false)
                Text("GIF").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 104)

            divider

            // Microphone: tap toggles, menu picks the device.
            chip(on: mic && !gif, symbol: mic && !gif ? "mic.fill" : "mic.slash", level: meter.mic,
                 warn: mic ? meter.micError : nil, disabled: gif) {
                Toggle("Мікрофон", isOn: $mic)
                Divider()
                Picker("Пристрій", selection: $micID) {
                    Text("Типовий").tag("")
                    ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .pickerStyle(.inline)
            }
            .help(gif ? "GIF без звуку" : "Мікрофон — смужка показує рівень")

            chip(on: systemAudio && !gif, symbol: systemAudio && !gif ? "speaker.wave.2.fill" : "speaker.slash", level: meter.system,
                 warn: systemAudio ? meter.systemError : nil, disabled: gif) {
                Toggle("Системний звук", isOn: $systemAudio)
            }
            .help("Системний звук — смужка показує рівень")

            chip(on: camera, symbol: camera ? "video.fill" : "video.slash", level: nil, warn: cameraError, disabled: false) {
                Toggle("Вебкамера", isOn: $camera)
                Divider()
                Picker("Камера", selection: $cameraID) {
                    Text("Типова").tag("")
                    ForEach(cams, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .pickerStyle(.inline)
            }
            .help("Вебкамера: кружечок можна перетягнути, скрол — розмір")

            Menu {
                Toggle("Показувати курсор", isOn: $cursor)
                Toggle("Підсвічувати кліки", isOn: $clicks)
                Toggle("Показувати клавіші", isOn: $keys)
                Toggle("Сховати іконки робочого столу", isOn: $hideDesktop)
                Divider()
                Picker("Відлік", selection: $countdown) {
                    Text("Без відліку").tag(0)
                    Text("3 с").tag(3)
                    Text("5 с").tag(5)
                    Text("10 с").tag(10)
                }
                Picker("Кадрів на секунду", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Divider()
                Picker("Після запису", selection: $afterRecord) {
                    Text("Відкрити теку з записом").tag("folder")
                    Text("Панель швидкого доступу").tag("panel")
                    Text("Відеоредактор").tag("editor")
                }
            } label: {
                Image(systemName: "gearshape.fill").frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Курсор, кліки, клавіші, відлік, fps")

            Text("\(Int(area.pixelSize.width))×\(Int(area.pixelSize.height))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            divider

            Button { onCancel() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Скасувати (Esc)")

            Button { onStart(gif) } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                    Text(countdown > 0 ? "Запис · \(countdown)с" : "Запис").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.red))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help("Почати (⏎)")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Capsule().fill(.ultraThickMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .fixedSize()
        .onChange(of: gif) { onAudioChange(gif) }
        .onChange(of: mic) { onAudioChange(gif) }
        .onChange(of: micID) { onAudioChange(gif) }
        .onChange(of: systemAudio) { onAudioChange(gif) }
        .onChange(of: camera) { Task { cameraError = await onCameraChange() } }
        .onChange(of: cameraID) { Task { cameraError = await onCameraChange() } }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 22)
    }

    /// Icon button with a dropdown menu and an optional mini level meter underneath.
    private func chip<M: View>(on: Bool, symbol: String, level: Float?, warn: String?, disabled: Bool,
                               @ViewBuilder menu: () -> M) -> some View {
        VStack(spacing: 2) {
            Menu {
                menu()
                if let warn { Divider(); Text(warn) }
            } label: {
                Image(systemName: warn != nil ? "exclamationmark.triangle.fill" : symbol)
                    .foregroundStyle(warn != nil ? Color.orange : (on ? Color.primary : Color.secondary))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if let level, on {
                LevelBar(level: level).frame(width: 22, height: 3)
            } else {
                Color.clear.frame(width: 22, height: 3)
            }
        }
        .frame(width: 36, height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.12) : Color.clear))
        .disabled(disabled)
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
        .frame(minHeight: 3, maxHeight: 8)
    }
}
