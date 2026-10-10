import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    static func open(_ item: CaptureItem) {
        guard item.image != nil else { return }
        let c = EditorWindowController(item: item)
        openEditors.append(c)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func openFile(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { HUD.error("Не вдалося відкрити зображення"); return }
        var scale: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let dpi = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue, dpi > 72 {
            scale = CGFloat((dpi / 72).rounded())
        }
        open(CaptureItem(image: img, scale: max(1, scale), fileURL: url))
    }

    let model: EditorModel
    let canvas: CanvasView

    init(item: CaptureItem) {
        model = EditorModel(item: item)
        canvas = CanvasView(model: model)
        let vis = NSScreen.withMouse.visibleFrame
        let pts = item.pointSize
        let w = min(max(pts.width + 80, 860), vis.width * 0.92)
        let h = min(max(pts.height + 150, 520), vis.height * 0.92)
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = item.fileURL?.lastPathComponent ?? "Kadr — редактор"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 760, height: 420)
        win.backgroundColor = NSColor(white: 0.13, alpha: 1)
        win.appearance = NSAppearance(named: .darkAqua)
        super.init(window: win)
        win.delegate = self
        win.contentView = NSHostingView(rootView: EditorRootView(model: model, canvas: canvas) { [weak self] cmd in self?.handle(cmd) })
        canvas.onCommand = { [weak self] cmd in self?.handle(cmd) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func handle(_ cmd: EditorCommand) {
        canvas.commitText()
        switch cmd {
        case .copy:
            // Copy finishes the edit: keep the saved file in sync, then close.
            guard let img = model.render() else { return }
            Clipboard.copy(img, scale: model.scale)
            if model.dirty, Prefs.afterSave { save(quiet: true) }
            model.dirty = false
            HUD.show("Скопійовано")
            window?.close()
        case .save:
            _ = save()
        case .saveAs:
            saveAs()
        case .pin:
            guard let img = model.render() else { return }
            PinWindow.pin(img, scale: model.scale)
        case .share:
            guard let img = model.render() else { return }
            let url = Storage.newURL(ext: Storage.imageExt, in: Storage.tempDir)
            try? Storage.write(img, scale: model.scale, to: url)
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: CGRect(x: canvas.bounds.maxX - 40, y: 0, width: 1, height: 1), of: canvas, preferredEdge: .minY)
        case .reveal:
            if let url = save() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .ocr:
            guard let img = model.render() else { return }
            Task { await OCR.copyText(from: img) }
        case .resetCrop:
            model.pushUndo()
            model.crop = model.imageRect
        case .done:
            guard let img = model.render() else { return }
            Clipboard.copy(img, scale: model.scale)
            if save(quiet: true) != nil { HUD.show("Збережено й скопійовано") }
            model.dirty = false
            window?.close()
        }
    }

    @discardableResult
    private func save(quiet: Bool = false) -> URL? {
        guard let img = model.render() else { return nil }
        let item = model.item
        let folder = Storage.folder().path
        let url: URL
        if let u = item.fileURL, u.path.hasPrefix(folder) || !u.path.hasPrefix(Storage.tempDir.path) {
            url = u   // overwrite the capture / opened file
        } else {
            url = Storage.newURL(ext: Storage.imageExt)
        }
        do {
            try Storage.write(img, scale: model.scale, to: url)
            item.fileURL = url
            History.add(url)
            model.dirty = false
            window?.title = url.lastPathComponent
            if !quiet { HUD.show("Збережено", detail: url.lastPathComponent) }
            return url
        } catch {
            HUD.error("Не вдалося зберегти: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveAs() {
        guard let window, let img = model.render() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = model.item.fileURL?.deletingPathExtension().lastPathComponent ?? "Kadr"
        panel.directoryURL = Storage.folder()
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try Storage.write(img, scale: self.model.scale, to: url)
                History.add(url)
                self.model.dirty = false
                HUD.show("Збережено", detail: url.lastPathComponent)
            } catch {
                HUD.error("Не вдалося зберегти")
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitText()
        guard model.dirty else { return true }
        let a = NSAlert()
        a.messageText = "Зберегти зміни?"
        a.informativeText = "Анотації буде втрачено, якщо не зберегти."
        a.addButton(withTitle: "Зберегти")
        a.addButton(withTitle: "Не зберігати")
        a.addButton(withTitle: "Скасувати")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save() != nil
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }
}

// MARK: - SwiftUI chrome

private struct CanvasHost: NSViewRepresentable {
    let view: CanvasView
    func makeNSView(context: Context) -> CanvasView { view }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

private struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView
    let command: (EditorCommand) -> Void
    @Local private var showBackground = false

    private let widths: [(String, CGFloat)] = [("S", 2), ("M", 4), ("L", 7), ("XL", 11)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.17))
            Divider()
            CanvasHost(view: canvas)
            Divider()
            statusBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.17))
        }
        .onChange(of: model.color) { model.styleChanged() }
        .onChange(of: model.strokeWidth) { model.styleChanged() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { t in
                    Button { model.tool = t } label: {
                        Image(systemName: t.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.tool == t ? Color.accentColor : Color.clear))
                            .foregroundStyle(model.tool == t ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 4) {
                ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { i, c in
                    Button { model.color = c } label: {
                        Circle().fill(Color(cgColor: c))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white.opacity(model.color == c ? 1 : 0.25), lineWidth: model.color == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("Колір \(i + 1)")
                }
                ColorPicker("", selection: $model.color, supportsOpacity: true).labelsHidden().frame(width: 28)
            }

            Picker("", selection: $model.strokeWidth) {
                ForEach(widths.indices, id: \.self) { i in Text(widths[i].0).tag(widths[i].1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .help("Товщина / розмір тексту")

            Spacer(minLength: 6)

            Button { showBackground.toggle() } label: {
                Image(systemName: "photo.artframe")
                    .foregroundStyle(model.background.enabled ? Color.accentColor : Color.primary)
            }
            .help("Фон, відступи, тінь")
            .popover(isPresented: $showBackground, arrowEdge: .bottom) { BackgroundPanel(model: model) }

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Скасувати (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Повторити (⇧⌘Z)")

            Menu {
                Button("Зберегти як…") { command(.saveAs) }
                Button("Показати у Finder") { command(.reveal) }
                Button("Закріпити поверх вікон") { command(.pin) }
                Button("Поділитися…") { command(.share) }
                Button("Розпізнати текст (OCR)") { command(.ocr) }
                Divider()
                Button("Скинути обрізку") { command(.resetCrop) }
                Button("Видалити всі анотації") { model.clearAll() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)

            Button("Копіювати") { command(.copy) }.help("⌘C — скопіювати й закрити")
            Button("Зберегти") { command(.save) }.keyboardShortcut("s", modifiers: .command)
            Button("Готово") { command(.done) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.tool.title).foregroundStyle(.secondary)
            Spacer()
            let s = model.documentSize
            Text("\(Int(s.width)) × \(Int(s.height)) px").monospacedDigit().foregroundStyle(.secondary)
            Text("·  1–8 кольори · Shift — рівно · ⌫ — видалити · ⌘⏎ — готово").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
    }
}

private struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Фон і відступи", isOn: $model.background.enabled).toggleStyle(.switch)
            Group {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 4), spacing: 8) {
                    ForEach(BackgroundStyle.presets.indices, id: \.self) { i in
                        let colors = BackgroundStyle.presets[i].map { Color(cgColor: $0) }
                        Button { model.background.preset = i; model.background.enabled = true } label: {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 34, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: model.background.preset == i ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                LabeledContent("Відступ") {
                    Slider(value: $model.background.padding, in: 8...200).frame(width: 150)
                }
                LabeledContent("Заокруглення") {
                    Slider(value: $model.background.cornerRadius, in: 0...40).frame(width: 150)
                }
                Toggle("Тінь", isOn: $model.background.shadow)
            }
            .disabled(!model.background.enabled)
        }
        .padding(16)
        .frame(width: 260)
        .onChange(of: model.background) { model.dirty = true }
    }
}
