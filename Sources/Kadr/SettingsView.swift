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
        NSApp.activate(ignoringOtherApps: true)
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
    @Local private var launchAtLogin = LaunchAtLogin.isEnabled

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
                    Text("3 с").tag(3)
                    Text("5 с").tag(5)
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
    @AppStorage(PrefKey.afterRecord) private var afterRecord = "folder"

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
                Picker("Після запису", selection: $afterRecord) {
                    Text("Відкрити теку з записом").tag("folder")
                    Text("Панель швидкого доступу").tag("panel")
                    Text("Відеоредактор").tag("editor")
                }
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
    @Local private var refresh = 0

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
    @Local private var combo: KeyCombo? = nil
    @Local private var recording = false
    @Local private var monitor: Any? = nil

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
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum HistoryFilter: String, CaseIterable {
    case all = "Усе", images = "Знімки", video = "Відео"

    func matches(_ url: URL) -> Bool {
        let isVideo = ["mp4", "mov", "gif"].contains(url.pathExtension.lowercased())
        switch self {
        case .all: return true
        case .images: return !isVideo
        case .video: return isVideo
        }
    }
}

private struct HistoryView: View {
    @Local private var urls = History.urls
    @Local private var filter = HistoryFilter.all
    @Local private var selection: Set<URL> = []

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMMM, EEEE"
        return f
    }()

    /// Newest day first; inside a day the order of `History.urls` (newest first) is kept.
    private var days: [(title: String, items: [URL])] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [URL]] = [:]
        for u in urls where filter.matches(u) {
            let date = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let day = cal.startOfDay(for: date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(u)
        }
        return order.sorted(by: >).map { day in
            let title = cal.isDateInToday(day) ? "Сьогодні" : cal.isDateInYesterday(day) ? "Учора" : Self.dayFormat.string(from: day)
            return (title, byDay[day] ?? [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if days.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(urls.isEmpty ? "Ще немає знімків" : "У цьому розділі порожньо").foregroundStyle(.secondary)
                    if urls.isEmpty {
                        Text("Зроби перший: меню Kadr у рядку меню").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                        ForEach(days, id: \.title) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(day.title).font(.system(size: 13, weight: .semibold))
                                    Text("\(day.items.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                                    ForEach(day.items, id: \.self) { u in
                                        HistoryCell(url: u, selected: selection.contains(u),
                                                    select: { toggle(u, extend: $0) },
                                                    changed: reload)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: .kadrHistoryChanged)) { _ in reload() }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(HistoryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Spacer()
            if selection.isEmpty {
                Text("⌘-клік — вибрати кілька").font(.caption).foregroundStyle(.tertiary)
                Button("Очистити історію") { History.clear(); reload() }
            } else {
                Text("Вибрано: \(selection.count)").font(.caption).foregroundStyle(.secondary)
                Button("Копіювати") {
                    let picked = urls.filter(selection.contains).reversed()
                    Clipboard.copy(files: Array(picked))
                    HUD.show("Скопійовано: \(picked.count)", detail: "⌘V вставить усі разом")
                    selection = []
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("У кошик") {
                    for u in selection { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                    selection = []
                    reload()
                }
                Button("Зняти вибір") { selection = [] }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func reload() {
        urls = History.urls
        selection = selection.filter { urls.contains($0) }
    }

    private func toggle(_ u: URL, extend: Bool) {
        if extend {
            if selection.contains(u) { selection.remove(u) } else { selection.insert(u) }
        } else {
            selection = selection == [u] ? [] : [u]
        }
    }
}

private struct HistoryCell: View {
    let url: URL
    let selected: Bool
    let select: (_ extend: Bool) -> Void
    let changed: () -> Void
    @Local private var thumb: NSImage? = nil
    @Local private var hover = false

    private var isImage: Bool { ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var caption: String {
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
        let t = date.map(Self.time.string(from:)) ?? url.lastPathComponent
        return isImage ? t : "\(t) · \(url.pathExtension.lowercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.10))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    Image(systemName: isImage ? "photo" : "film").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hover)
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { open() }
        .onTapGesture { select(NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)) }
        .contextMenu {
            Button("Відкрити") { open() }
            if url.pathExtension.lowercased() == "mp4" {
                Button("Обрізати й експортувати") { VideoEditorWindowController.open(url) }
            } else if url.pathExtension.lowercased() != "gif" {
                Button("Редагувати") { EditorWindowController.openFile(url) }
            }
            Button("Копіювати") {
                if isImage, case let (img, scale)? = Thumbs.full(url) { Clipboard.copy(img, scale: scale, file: url) } else { Clipboard.copy(file: url) }
            }
            Button("Показати у Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("У кошик") { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); changed() }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.lastPathComponent)
        .task {
            if isImage { thumb = Thumbs.image(for: url, maxPixel: 480) } else { thumb = QuickAccess.thumbnail(for: CaptureItem(video: url)) }
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
