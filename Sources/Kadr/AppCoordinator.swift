import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// All capture flows end in `deliver`, which applies the "after capture" preferences.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()
    private var busy = false

    func perform(_ action: HotKeyAction) {
        switch action {
        case .area: run { await self.captureArea() }
        case .window: run { await self.captureWindow() }
        case .fullscreen: run { await self.captureFullscreen(delay: 0) }
        case .previousArea: run { await self.capturePreviousArea() }
        case .recordVideo: Recorder.shared.toggle(gif: false)
        case .recordGIF: Recorder.shared.toggle(gif: true)
        case .ocr: run { await self.captureText() }
        case .scrolling:
            if ScrollCapture.shared.running { ScrollCapture.shared.finish() } else { run { await ScrollCapture.shared.start() } }
        case .pinClipboard: pinClipboard()
        case .toggleDesktop: DesktopIcons.shared.toggle()
        case .history: HistoryWindow.show()
        }
    }

    /// Prevents overlapping selection overlays (e.g. double hotkey press).
    private func run(_ work: @escaping @MainActor () async -> Void) {
        if Recorder.shared.isRecording { HUD.error("Спершу зупини запис"); return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await work()
            self.busy = false
        }
    }

    // MARK: Flows

    func captureArea() async {
        guard let sel = await SelectionController.run(mode: .area) else { return }
        await handle(sel)
    }

    func captureWindow() async {
        guard let sel = await SelectionController.run(mode: .window) else { return }
        await handle(sel)
    }

    func captureFullscreen(delay: Int) async {
        if delay > 0 { await Countdown.run(seconds: delay) }
        let screen = NSScreen.withMouse
        do {
            let content = try await Capture.content()
            let shot = try await Capture.shot(of: screen, content: content)
            deliver(image: shot.image, scale: shot.scale, screenRect: screen.frame)
        } catch {
            Capture.showPermissionAlert()
        }
    }

    func capturePreviousArea() async {
        guard case let (id, rect)? = Prefs.lastArea, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
            await captureArea()
            return
        }
        do {
            let (img, scale) = try await Capture.image(of: rect, on: screen)
            deliver(image: img, scale: scale, screenRect: screen.globalRect(fromTopLeft: rect))
        } catch {
            Capture.showPermissionAlert()
        }
    }

    func captureText() async {
        guard let sel = await SelectionController.run(mode: .area, hint: "Розпізнати текст") else { return }
        guard case let (img, _, _)? = await image(for: sel) else { return }
        await OCR.copyText(from: img)
    }

    private func handle(_ sel: SelectionResult) async {
        guard case let (img, scale, rect)? = await image(for: sel) else { return }
        if case .area(let screen, let r, _) = sel { Prefs.lastArea = (screen.displayID, r) }
        deliver(image: img, scale: scale, screenRect: rect)
    }

    private func image(for sel: SelectionResult) async -> (CGImage, CGFloat, CGRect)? {
        switch sel {
        case .area(let screen, let rect, let shot):
            guard let img = Capture.crop(shot.image, to: rect, scale: shot.scale) else { return nil }
            return (img, shot.scale, screen.globalRect(fromTopLeft: rect))
        case .window(let c, let screen):
            do {
                let (img, scale) = try await Capture.image(of: c.window)
                let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
                let g = CGRect(x: c.frame.minX, y: primaryH - c.frame.maxY, width: c.frame.width, height: c.frame.height)
                return (img, scale, g)
            } catch {
                HUD.error("Не вдалося зняти вікно: \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: Delivery

    func deliver(image raw: CGImage, scale rawScale: CGFloat, screenRect: CGRect?) {
        var image = raw
        var scale = rawScale
        if Prefs.downscaleRetina, scale > 1, let s = raw.scaled(by: 1 / scale) {
            image = s
            scale = 1
        }
        Sound.shutter()
        let item = CaptureItem(image: image, scale: scale, screenRect: screenRect)
        if Prefs.afterSave { item.saveToFolder() }
        if Prefs.afterCopy { Clipboard.copy(image, scale: scale) }
        if Prefs.afterOpenEditor {
            EditorWindowController.open(item)
        } else if Prefs.afterOverlay {
            QuickAccess.shared.show(item)
        } else if Prefs.afterCopy {
            HUD.show("Скопійовано в буфер")
        }
    }

    // MARK: Misc

    func pinClipboard() {
        guard case let (img, scale)? = Clipboard.image() else { HUD.error("У буфері немає зображення"); return }
        PinWindow.pin(img, scale: scale)
    }

    func annotateClipboard() {
        guard case let (img, scale)? = Clipboard.image() else { HUD.error("У буфері немає зображення"); return }
        EditorWindowController.open(CaptureItem(image: img, scale: scale))
    }

    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = Storage.folder()
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { EditorWindowController.openFile(url) }
    }
}
