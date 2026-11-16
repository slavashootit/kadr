import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        _ = Storage.folder()
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        registerHotKeys()
        NotificationCenter.default.addObserver(forName: .kadrHotKeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }

        Recorder.shared.onStateChange = { [weak self] in self?.updateStatusItem() }

        if !Capture.hasPermission() {
            CGRequestScreenCaptureAccess()
        }
        if UserDefaults.standard.object(forKey: "didShowWelcome") == nil {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            HUD.show("Kadr працює в рядку меню", symbol: "camera.viewfinder", detail: "⌥⇧1 — область · ⌥⇧2 — вікно · ⌥⇧5 — запис відео", seconds: 5)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return true
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.registerAll { action in AppCoordinator.shared.perform(action) }
        let failed = HotKeyCenter.shared.failed
        if !failed.isEmpty {
            HUD.error("Зайняті гарячі клавіші: " + failed.map(\.title).joined(separator: ", "))
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if Recorder.shared.isRecording {
            let paused = Recorder.shared.isPaused
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: "Стоп")?
                .withSymbolConfiguration(.init(paletteColors: [paused ? .systemOrange : .systemRed]))
            button.title = " " + Recorder.shared.elapsedString
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
            button.title = ""
            button.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func stopRecording() { Task { await Recorder.shared.stop() } }

    // MARK: Status menu (rebuilt on open so hotkeys/history stay current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ symbol: String, _ action: HotKeyAction, to target: NSMenu) {
            let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = action.rawValue
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let c = HotKeyStore.combo(for: action), !c.menuKey.isEmpty {
                i.keyEquivalent = c.menuKey
                i.keyEquivalentModifierMask = c.menuModifiers
            }
            target.addItem(i)
        }
        @discardableResult
        func item(_ title: String, _ symbol: String?, _ sel: Selector, key: String = "", to target: NSMenu) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            target.addItem(i)
            return i
        }

        // The three everyday captures first.
        add("Знімок області", "rectangle.dashed", .area, to: menu)
        add("Знімок вікна", "macwindow", .window, to: menu)
        add("Весь екран", "display", .fullscreen, to: menu)
        menu.addItem(.separator())
        add("Записати відео", "record.circle", .recordVideo, to: menu)
        add("Записати GIF", "photo.stack", .recordGIF, to: menu)

        // Latest captures: click copies, drag gives the file.
        let urls = Array(History.urls.prefix(5))
        if !urls.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Останні — клік копіює"))
            let strip = NSMenuItem()
            let host = NSHostingView(rootView: RecentStrip(urls: urls) { [weak self] url in
                menu.cancelTracking()
                self?.copyRecent(url)
            })
            host.frame = NSRect(x: 0, y: 0, width: 320, height: RecentStrip.height)
            strip.view = host
            menu.addItem(strip)
        }
        add("Історія знімків", "clock.arrow.circlepath", .history, to: menu)
        if BuferLink.isInstalled {
            item("Історія буфера (Bufer)", "doc.on.clipboard", #selector(openBufer), to: menu)
        }
        item("Відкрити теку знімків", "folder", #selector(openFolder), to: menu)
        menu.addItem(.separator())

        // Everything occasional lives one level down.
        let more = NSMenuItem(title: "Ще", action: nil, keyEquivalent: "")
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        let mm = NSMenu()
        add("Попередня область", "arrow.counterclockwise", .previousArea, to: mm)
        add("Скролінг-знімок", "arrow.down.doc", .scrolling, to: mm)
        let timer = NSMenuItem(title: "Знімок із таймером", action: nil, keyEquivalent: "")
        timer.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let tm = NSMenu()
        for s in [3, 5, 10] {
            let i = NSMenuItem(title: "\(s) секунд", action: #selector(timerShot(_:)), keyEquivalent: "")
            i.target = self
            i.tag = s
            tm.addItem(i)
        }
        timer.submenu = tm
        mm.addItem(timer)
        mm.addItem(.separator())
        add("Розпізнати текст (OCR)", "text.viewfinder", .ocr, to: mm)
        add("Закріпити з буфера", "pin", .pinClipboard, to: mm)
        item("Редагувати з буфера", "pencil.tip.crop.circle", #selector(annotateClipboard), to: mm)
        item("Відкрити зображення…", "photo", #selector(openFile), key: "o", to: mm)
        mm.addItem(.separator())
        add(DesktopIcons.shared.isHidden ? "Показати іконки робочого столу" : "Сховати іконки робочого столу",
            DesktopIcons.shared.isHidden ? "eye" : "eye.slash", .toggleDesktop, to: mm)
        more.submenu = mm
        menu.addItem(more)

        if PinWindow.count > 0 {
            item("Розблокувати піни", "lock.open", #selector(unlockPins), to: menu)
            item("Закрити всі піни (\(PinWindow.count))", "pin.slash", #selector(closePins), to: menu)
        }

        menu.addItem(.separator())
        item("Налаштування…", "gearshape", #selector(openSettings), key: ",", to: menu)
        item("Вийти з Kadr", nil, #selector(quit), key: "q", to: menu)
    }

    private func copyRecent(_ url: URL) {
        if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), case let (img, scale)? = Thumbs.full(url) {
            Clipboard.copy(img, scale: scale, file: url)
        } else {
            Clipboard.copy(file: url)
        }
        HUD.show("Скопійовано", detail: url.lastPathComponent)
    }

    @objc private func openBufer() { BuferLink.openHistory() }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = HotKeyAction(rawValue: raw) else { return }
        // Let the menu close before an overlay freezes the screen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            AppCoordinator.shared.perform(a)
        }
    }

    @objc private func timerShot(_ sender: NSMenuItem) {
        let s = sender.tag
        Task { await AppCoordinator.shared.captureFullscreen(delay: s) }
    }

    @objc private func annotateClipboard() { AppCoordinator.shared.annotateClipboard() }
    @objc private func openFile() { AppCoordinator.shared.openImageFile() }
    @objc private func unlockPins() { PinWindow.unlockAll() }
    @objc private func closePins() { PinWindow.closeAll() }
    @objc private func openFolder() { NSWorkspace.shared.open(Storage.folder()) }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        switch u.pathExtension.lowercased() {
        case "png", "jpg", "jpeg": EditorWindowController.openFile(u)
        case "mp4", "mov": VideoEditorWindowController.open(u)
        default: NSWorkspace.shared.open(u)
        }
    }

    // MARK: Main menu: needed for ⌘Z/⌘C/⌘V in editor windows and text fields

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Налаштування…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Сховати Kadr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Вийти з Kadr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Редагування")
        edit.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторити", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "Вікно")
        win.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Kadr: launch at login failed: \(error)")
        }
    }
}
