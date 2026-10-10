import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Kadr — налаштування"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Загальні", systemImage: "gearshape") }
            CaptureTab().tabItem { Label("Знімки", systemImage: "camera") }
            RecordingTab().tabItem { Label("Запис", systemImage: "record.circle") }
            HotKeysTab().tabItem { Label("Клавіші", systemImage: "keyboard") }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }
}

private struct GeneralTab: View {
    @AppStorage(PrefKey.saveFolder) private var folder = Prefs.defaultFolder.path
    @AppStorage(PrefKey.playSound) private var sound = true
    @AppStorage(PrefKey.overlayAutoClose) private var autoClose = 20
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Збереження") {
                HStack {
                    Text("Тека").frame(width: 60, alignment: .leading)
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Змінити…") { pickFolder() }
                    Button { NSWorkspace.shared.open(Storage.folder()) } label: { Image(systemName: "folder") }
                }
            }
            Section("Поведінка") {
                Toggle("Запускати при вході в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LaunchAtLogin.set(launchAtLogin) }
                Toggle("Звук затвора", isOn: $sound)
                Picker("Панель після знімка зникає через", selection: $autoClose) {
                    Text("10 с").tag(10)
                    Text("20 с").tag(20)
                    Text("60 с").tag(60)
                    Text("Ніколи").tag(0)
                }
            }
            Section("Дозволи") {
                HStack {
                    Image(systemName: Capture.hasPermission() ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(Capture.hasPermission() ? .green : .red)
                    Text("Запис екрана")
                    Spacer()
                    Button("Відкрити параметри") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                HStack {
                    Image(systemName: AXIsProcessTrusted() ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(AXIsProcessTrusted() ? .green : .secondary)
                    Text("Універсальний доступ (лише для показу клавіш у записі)")
                    Spacer()
                    Button("Відкрити") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: folder)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}

private struct CaptureTab: View {
    @AppStorage(PrefKey.afterSave) private var save = true
    @AppStorage(PrefKey.afterCopy) private var copy = true
    @AppStorage(PrefKey.afterOverlay) private var overlay = true
    @AppStorage(PrefKey.afterOpenEditor) private var editor = false
    @AppStorage(PrefKey.imageFormat) private var format = "png"
    @AppStorage(PrefKey.downscaleRetina) private var downscale = false
    @AppStorage(PrefKey.windowShadow) private var shadow = true
    @AppStorage(PrefKey.showMagnifier) private var magnifier = true

    var body: some View {
        Form {
            Section("Після знімка") {
                Toggle("Зберігати у теку", isOn: $save)
                Toggle("Копіювати в буфер обміну", isOn: $copy)
                Toggle("Показувати панель швидкого доступу", isOn: $overlay)
                Toggle("Одразу відкривати редактор", isOn: $editor)
            }
            Section("Файл") {
                Picker("Формат", selection: $format) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpg")
                }
                .pickerStyle(.segmented)
                Toggle("Зменшувати Retina-знімки до 1x", isOn: $downscale)
            }
            Section("Вибір області") {
                Toggle("Лупа з координатами й кольором пікселя", isOn: $magnifier)
                Toggle("Тінь у знімках вікон", isOn: $shadow)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingTab: View {
    @AppStorage(PrefKey.recordFPS) private var fps = 60
    @AppStorage(PrefKey.recordCursor) private var cursor = true
    @AppStorage(PrefKey.recordClicks) private var clicks = true
    @AppStorage(PrefKey.recordKeys) private var keys = false
    @AppStorage(PrefKey.recordSystemAudio) private var systemAudio = true
    @AppStorage(PrefKey.recordMic) private var mic = false
    @AppStorage(PrefKey.recordHEVC) private var hevc = false
    @AppStorage(PrefKey.gifFPS) private var gifFPS = 15
    @AppStorage(PrefKey.gifMaxWidth) private var gifWidth = 960
    @AppStorage(PrefKey.recordCountdown) private var countdown = 3
    @AppStorage(PrefKey.afterRecordOpenEditor) private var openEditor = true

    var body: some View {
        Form {
            Section("Відео") {
                Picker("Частота кадрів", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Toggle("Кодек HEVC (менші файли)", isOn: $hevc)
                Toggle("Показувати курсор", isOn: $cursor)
                Toggle("Підсвічувати кліки", isOn: $clicks)
                Toggle("Показувати натиснуті клавіші", isOn: $keys)
                Picker("Відлік перед стартом", selection: $countdown) {
                    Text("Без відліку").tag(0)
                    Text("3 с").tag(3)
                    Text("5 с").tag(5)
                    Text("10 с").tag(10)
                }
                Toggle("Після запису відкривати відеоредактор", isOn: $openEditor)
            }
            Section("Звук") {
                Toggle("Системний звук", isOn: $systemAudio)
                Toggle("Мікрофон", isOn: $mic)
            }
            Section("GIF") {
                Picker("Кадрів за секунду", selection: $gifFPS) {
                    Text("10").tag(10)
                    Text("15").tag(15)
                    Text("20").tag(20)
                    Text("25").tag(25)
                }
                .pickerStyle(.segmented)
                Picker("Макс. ширина", selection: $gifWidth) {
                    Text("640").tag(640)
                    Text("960").tag(960)
                    Text("1280").tag(1280)
                    Text("1920").tag(1920)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotKeysTab: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { a in
                    HotKeyRow(action: a)
                }
            } footer: {
                HStack {
                    Text("Щоб узяти ⌘⇧3/⌘⇧4, спершу вимкни їх у Системні параметри → Клавіатура → Скорочення → Знімки екрана.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Скинути") { HotKeyStore.reset(); refresh += 1 }
                }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
    }
}

private struct HotKeyRow: View {
    let action: HotKeyAction
    @State private var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Натисни комбінацію…" : (combo?.display ?? "—"))
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            Button {
                HotKeyStore.set(nil, for: action)
                combo = nil
            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Прибрати")
        }
        .onAppear { combo = HotKeyStore.combo(for: action) }
        .onDisappear { stop() }
    }

    private func start() {
        HotKeyCenter.shared.unregisterAll()   // so the current combo can be re-pressed
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFKey = (0x60...0x7A).contains(Int(e.keyCode))
            guard isFKey || !mods.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            let c = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: KeyCombo.carbon(mods), key: KeyCombo.keyName(for: e))
            combo = c
            stop(save: c)
            return nil
        }
    }

    private func stop(save: KeyCombo? = nil) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        let wasRecording = recording
        recording = false
        if let save { HotKeyStore.set(save, for: action) } else if wasRecording {
            NotificationCenter.default.post(name: .kadrHotKeysChanged, object: nil)  // re-register untouched keys
        }
    }
}

// MARK: - History window

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Kadr — історія"
            w.isReleasedWhenClosed = false
            w.center()
            return w
        }()
        w.contentView = NSHostingView(rootView: HistoryView())
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct HistoryView: View {
    @State private var urls = History.urls

    var body: some View {
        Group {
            if urls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Ще немає знімків").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(urls, id: \.self) { u in HistoryCell(url: u) { urls = History.urls } }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            Button("Очистити історію") { History.clear(); urls = [] }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct HistoryCell: View {
    let url: URL
    let changed: () -> Void
    @State private var thumb: NSImage?

    private var isImage: Bool { ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    Image(systemName: isImage ? "photo" : "film").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 110)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Відкрити") { open() }
            if url.pathExtension.lowercased() == "mp4" {
                Button("Обрізати й експортувати") { VideoEditorWindowController.open(url) }
            } else if url.pathExtension.lowercased() != "gif" {
                Button("Редагувати") { EditorWindowController.openFile(url) }
            }
            Button("Копіювати") { Clipboard.copy(file: url) }
            Button("Показати у Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("У кошик") { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); changed() }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .task {
            if isImage { thumb = NSImage(contentsOf: url) } else { thumb = QuickAccess.thumbnail(for: CaptureItem(video: url)) }
        }
    }

    private func open() {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg": EditorWindowController.openFile(url)
        case "mp4", "mov": VideoEditorWindowController.open(url)
        default: NSWorkspace.shared.open(url)
        }
    }
}
