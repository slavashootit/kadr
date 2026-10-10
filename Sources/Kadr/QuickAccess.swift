import AppKit
import AVFoundation
import SwiftUI

/// One finished capture: a screenshot (image in memory) or a recording (file on disk).
@MainActor
final class CaptureItem: ObservableObject, Identifiable {
    enum Kind { case image, video }

    let id = UUID()
    let kind: Kind
    @Published var image: CGImage?
    let scale: CGFloat
    @Published var fileURL: URL?
    /// Where the capture was on screen (global AppKit coords), used to pin it in place.
    var screenRect: CGRect?

    init(image: CGImage, scale: CGFloat, fileURL: URL? = nil, screenRect: CGRect? = nil) {
        kind = .image
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
        self.screenRect = screenRect
    }

    init(video url: URL) {
        kind = .video
        scale = 1
        fileURL = url
    }

    var pointSize: CGSize {
        guard let image else { return CGSize(width: 320, height: 200) }
        return CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// Returns a file for this capture, saving to a temp location if the user disabled auto-save.
    func ensureFile() -> URL? {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        guard let image else { return nil }
        let url = Storage.newURL(ext: Storage.imageExt, in: Storage.tempDir)
        do { try Storage.write(image, scale: scale, to: url) } catch { return nil }
        return url
    }

    @discardableResult
    func saveToFolder() -> URL? {
        if let fileURL, fileURL.path.hasPrefix(Storage.folder().path) { return fileURL }
        guard let image else { return fileURL }
        let url = Storage.newURL(ext: Storage.imageExt)
        do {
            try Storage.write(image, scale: scale, to: url)
            fileURL = url
            History.add(url)
            return url
        } catch {
            HUD.error("Не вдалося зберегти: \(error.localizedDescription)")
            return nil
        }
    }
}

@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    private var panels: [(item: CaptureItem, panel: NSPanel)] = []
    private var timers: [UUID: Timer] = [:]
    private let width: CGFloat = 250
    private let margin: CGFloat = 16

    func show(_ item: CaptureItem) {
        let thumb = Self.thumbnail(for: item)
        let aspect = thumb.size.height > 0 ? thumb.size.height / thumb.size.width : 0.62
        let height = min(max(width * aspect, 110), 300)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Exclusion.identifier
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        let view = QuickAccessView(item: item, thumb: thumb, size: CGSize(width: width, height: height),
                                   onHover: { [weak self] hovering in self?.hoverChanged(item, hovering) },
                                   act: { [weak self] action in self?.perform(action, item) })
        panel.contentView = NSHostingView(rootView: view)
        panels.append((item, panel))
        layout(animated: false, newPanel: panel)
        panel.orderFrontRegardless()
        scheduleClose(item)
    }

    private func layout(animated: Bool, newPanel: NSPanel? = nil) {
        let screen = NSScreen.withMouse.visibleFrame
        var y = screen.minY + margin
        for (_, p) in panels.reversed() {
            let target = CGRect(x: screen.minX + margin, y: y, width: p.frame.width, height: p.frame.height)
            if p === newPanel {
                p.setFrame(target.offsetBy(dx: -width - margin, dy: 0), display: false)
                p.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    p.animator().setFrame(target, display: true)
                    p.animator().alphaValue = 1
                }
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    p.animator().setFrame(target, display: true)
                }
            } else {
                p.setFrame(target, display: true)
            }
            y += p.frame.height + 10
        }
    }

    private func scheduleClose(_ item: CaptureItem) {
        timers[item.id]?.invalidate()
        let secs = Prefs.overlayAutoClose
        guard secs > 0 else { return }
        timers[item.id] = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(item) }
        }
    }

    private func hoverChanged(_ item: CaptureItem, _ hovering: Bool) {
        if hovering { timers[item.id]?.invalidate() } else { scheduleClose(item) }
    }

    func close(_ item: CaptureItem) {
        timers.removeValue(forKey: item.id)?.invalidate()
        guard let idx = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        let p = panels.remove(at: idx).panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: -60, dy: 0), display: true)
        }) {
            Task { @MainActor in p.orderOut(nil) }
        }
        layout(animated: true)
    }

    func closeAll() { panels.map(\.item).forEach(close) }

    enum Action { case copy, save, annotate, editVideo, pin, reveal, open, delete, gif, close, upload }

    private func perform(_ action: Action, _ item: CaptureItem) {
        switch action {
        case .copy:
            if let img = item.image { Clipboard.copy(img, scale: item.scale) } else if let u = item.fileURL { Clipboard.copy(file: u) }
            HUD.show("Скопійовано")
            close(item)
        case .save:
            if item.kind == .image, let url = item.saveToFolder() {
                HUD.show("Збережено", detail: url.lastPathComponent)
            } else if let u = item.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([u])
            }
            close(item)
        case .annotate:
            guard item.kind == .image else { return }
            EditorWindowController.open(item)
            close(item)
        case .editVideo:
            guard let u = item.fileURL else { return }
            VideoEditorWindowController.open(u)
            close(item)
        case .pin:
            if let img = item.image { PinWindow.pin(img, scale: item.scale, at: item.screenRect) }
            close(item)
        case .reveal:
            if let u = item.kind == .image ? item.saveToFolder() : item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        case .open:
            if let u = item.kind == .image ? item.ensureFile() : item.fileURL { NSWorkspace.shared.open(u) }
        case .delete:
            if let u = item.fileURL { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            close(item)
        case .gif:
            guard let u = item.fileURL else { return }
            Task { @MainActor in
                HUD.show("Конвертую в GIF…", symbol: "hourglass", seconds: 60)
                do {
                    let out = try await GIFExporter.export(video: u)
                    History.add(out)
                    Clipboard.copy(file: out)
                    HUD.show("GIF готовий і скопійований", detail: out.lastPathComponent)
                    QuickAccess.shared.show(CaptureItem(video: out))
                } catch {
                    HUD.error("GIF не вийшов: \(error.localizedDescription)")
                }
            }
            close(item)
        case .upload:
            if let u = item.kind == .image ? item.ensureFile() : item.fileURL { Share.show(u) }
        case .close:
            close(item)
        }
    }

    static func thumbnail(for item: CaptureItem) -> NSImage {
        if let img = item.image {
            return NSImage(cgImage: img, size: item.pointSize)
        }
        if let url = item.fileURL {
            if url.pathExtension.lowercased() == "gif", let g = NSImage(contentsOf: url) { return g }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 600, height: 600)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Native share sheet anchored to the mouse position.
@MainActor
enum Share {
    private static var anchor: NSWindow?

    static func show(_ url: URL) {
        let p = NSEvent.mouseLocation
        let w = NSWindow(contentRect: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.level = .floating
        w.orderFrontRegardless()
        anchor = w
        let picker = NSSharingServicePicker(items: [url])
        if let v = w.contentView { picker.show(relativeTo: v.bounds, of: v, preferredEdge: .minY) }
        Task { @MainActor in try? await Task.sleep(nanoseconds: 30_000_000_000); w.orderOut(nil) }
    }
}

private struct QuickAccessView: View {
    @ObservedObject var item: CaptureItem
    let thumb: NSImage
    let size: CGSize
    let onHover: (Bool) -> Void
    let act: (QuickAccess.Action) -> Void
    @Local private var hover = false

    var body: some View {
        ZStack {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
            if item.kind == .video && !hover {
                Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
            }
            if hover {
                Color.black.opacity(0.5)
                VStack(spacing: 0) {
                    HStack {
                        corner("xmark", "Закрити") { act(.close) }
                        Spacer()
                        if item.kind == .image { corner("pin.fill", "Закріпити поверх вікон") { act(.pin) } }
                        corner("square.and.arrow.up", "Поділитися") { act(.upload) }
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        pill("Копіювати") { act(.copy) }
                        pill(item.kind == .image ? "Зберегти" : "Показати у Finder") { act(.save) }
                    }
                    Spacer()
                    HStack {
                        if item.kind == .image {
                            corner("pencil.tip.crop.circle", "Редагувати") { act(.annotate) }
                        } else if item.fileURL?.pathExtension.lowercased() != "gif" {
                            corner("scissors", "Обрізати й експортувати") { act(.editVideo) }
                            corner("photo.stack", "Конвертувати в GIF") { act(.gif) }
                        }
                        Spacer()
                        corner("eye", "Відкрити") { act(.open) }
                        corner("trash", "У кошик") { act(.delete) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hover = h }
            onHover(h)
        }
        .onTapGesture(count: 2) {
            if item.kind == .image { act(.annotate) } else { act(item.fileURL?.pathExtension.lowercased() == "gif" ? .open : .editVideo) }
        }
        .onDrag {
            if let url = item.kind == .image ? item.ensureFile() : item.fileURL, let p = NSItemProvider(contentsOf: url) {
                return p
            }
            return NSItemProvider()
        }
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                .frame(width: 130, height: 28)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    private func corner(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
