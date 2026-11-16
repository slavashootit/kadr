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
    /// Set on the newest thumbnail only: how many captures are waiting in the stack.
    @Published var stackCount = 0
    @Published var collapsed = false

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
            TextIndex.index([url])
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

    private struct Entry {
        let item: CaptureItem
        let panel: NSPanel
        let size: CGSize
    }

    private var entries: [Entry] = []          // oldest first
    private var timers: [UUID: Timer] = [:]
    private var hovered: Set<UUID> = []
    private var expanded = false
    private var collapseWork: DispatchWorkItem?
    private let width: CGFloat = 250
    private let margin: CGFloat = 16
    /// More thumbnails than this fold into a deck instead of growing up the screen.
    private let deckThreshold = 3

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Slight overshoot, reads as a spring settling.
    private let spring = CAMediaTimingFunction(controlPoints: 0.3, 1.32, 0.5, 1)
    private let glide = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    func show(_ item: CaptureItem) {
        let thumb = Self.thumbnail(for: item)
        let aspect = thumb.size.width > 0 ? thumb.size.height / thumb.size.width : 0.62
        let size = CGSize(width: width, height: min(max(width * aspect, 110), 300))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
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

        let view = QuickAccessView(item: item, thumb: thumb,
                                   onHover: { [weak self] hovering in self?.hoverChanged(item, hovering) },
                                   act: { [weak self] action in self?.perform(action, item) })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        entries.append(Entry(item: item, panel: panel, size: size))
        layout(animated: true, newPanel: panel, flyFrom: item.screenRect)
        scheduleClose(item)
    }

    /// Newest sits at the bottom-left. Up to `deckThreshold` thumbnails form a column; more than that
    /// fold into a deck behind the newest one until the pointer opens it.
    private func layout(animated: Bool, newPanel: NSPanel? = nil, flyFrom: CGRect? = nil) {
        let screen = NSScreen.withMouse.visibleFrame
        let deck = entries.count > deckThreshold && !expanded
        let origin = CGPoint(x: screen.minX + margin, y: screen.minY + margin)
        let newest = entries.last
        var y = origin.y

        for (depth, e) in entries.reversed().enumerated() {
            var target: CGRect
            var alpha: CGFloat = 1
            if deck, depth > 0, let front = newest {
                let d = CGFloat(min(depth, 3))
                target = CGRect(x: origin.x + 7 * d, y: origin.y + 8 * d,
                                width: front.size.width - 14 * d, height: front.size.height)
                if depth > 3 { alpha = 0 }
            } else {
                target = CGRect(origin: CGPoint(x: origin.x, y: y), size: e.size)
                if target.maxY > screen.maxY - margin { alpha = 0 }
                y += e.size.height + 10
            }
            e.item.stackCount = depth == 0 ? entries.count : 0
            e.item.collapsed = deck
            e.panel.ignoresMouseEvents = alpha == 0

            if e.panel === newPanel {
                appear(e.panel, at: target, from: flyFrom)
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = reduceMotion ? 0.12 : 0.34
                    ctx.timingFunction = reduceMotion ? CAMediaTimingFunction(name: .easeOut) : spring
                    e.panel.animator().setFrame(target, display: true)
                    e.panel.animator().alphaValue = alpha
                }
            } else {
                e.panel.setFrame(target, display: true)
                e.panel.alphaValue = alpha
            }
        }
        // Keep the newest on top of the deck.
        for e in entries where e.panel !== newPanel { e.panel.orderFront(nil) }
        newest?.panel.orderFrontRegardless()
    }

    /// A new capture shrinks from the place it was taken into its slot; without a source rect
    /// (recordings) or with Reduce Motion it slides in from the edge.
    private func appear(_ p: NSPanel, at target: CGRect, from: CGRect?) {
        if let from, !reduceMotion, from.width > target.width {
            p.setFrame(from, display: true)
            p.alphaValue = 1
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.42
                ctx.timingFunction = glide
                p.animator().setFrame(target, display: true)
            }
        } else {
            p.setFrame(target.offsetBy(dx: -width - margin, dy: 0), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 1
            }
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

    /// While the pointer is over any thumbnail nothing closes, and a folded deck opens.
    private func hoverChanged(_ item: CaptureItem, _ hovering: Bool) {
        if hovering {
            hovered.insert(item.id)
            collapseWork?.cancel()
            timers.values.forEach { $0.invalidate() }
            if entries.count > deckThreshold, !expanded {
                expanded = true
                layout(animated: true)
            }
        } else {
            hovered.remove(item.id)
            guard hovered.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovered.isEmpty else { return }
                if self.expanded {
                    self.expanded = false
                    self.layout(animated: true)
                }
                self.entries.forEach { self.scheduleClose($0.item) }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    func close(_ item: CaptureItem) {
        timers.removeValue(forKey: item.id)?.invalidate()
        hovered.remove(item.id)
        guard let idx = entries.firstIndex(where: { $0.item.id == item.id }) else { return }
        let p = entries.remove(at: idx).panel
        if entries.count <= deckThreshold { expanded = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: -60, dy: 0), display: true)
        }) {
            Task { @MainActor in p.orderOut(nil) }
        }
        layout(animated: true)
    }

    func closeAll() { entries.map(\.item).forEach(close) }

    enum Action { case copy, copyAll, save, annotate, editVideo, pin, reveal, open, delete, gif, close, upload }

    private func perform(_ action: Action, _ item: CaptureItem) {
        switch action {
        case .copy:
            if let img = item.image { Clipboard.copy(img, scale: item.scale, file: item.fileURL) } else if let u = item.fileURL { Clipboard.copy(file: u) }
            HUD.show("Скопійовано")
            close(item)
        case .copyAll:
            // Oldest first, so they paste in the order they were taken.
            let urls = entries.compactMap { $0.item.kind == .image ? $0.item.ensureFile() : $0.item.fileURL }
            guard !urls.isEmpty else { return }
            Clipboard.copy(files: urls)
            HUD.show("Скопійовано знімків: \(urls.count)", detail: "⌘V вставить усі разом")
            closeAll()
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
            let longest = CGFloat(max(img.width, img.height))
            let small = longest > 1400 ? img.scaled(by: 1400 / longest) ?? img : img
            return NSImage(cgImage: small, size: item.pointSize)
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
    let onHover: (Bool) -> Void
    let act: (QuickAccess.Action) -> Void
    @Local private var hover = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                if item.kind == .video && !hover {
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                }
                if item.collapsed, item.stackCount > 1, !hover {
                    VStack {
                        HStack {
                            Spacer()
                            Text("×\(item.stackCount)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(.regularMaterial))
                        }
                        Spacer()
                    }
                    .padding(8)
                    .transition(.opacity)
                }
                // Controls only once the thumbnail has landed at its resting width.
                if hover, geo.size.width < 300 {
                    Rectangle().fill(.ultraThinMaterial)
                    controls.padding(8)
                }
            }
        }
        .environment(\.colorScheme, .dark)
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

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                corner("xmark", "Закрити") { act(.close) }
                Spacer()
                if item.kind == .image { corner("pin.fill", "Закріпити поверх вікон") { act(.pin) } }
                corner("square.and.arrow.up", "Поділитися") { act(.upload) }
            }
            Spacer()
            VStack(spacing: 6) {
                pill("Копіювати") { act(.copy) }
                if item.stackCount > 1 {
                    pill("Скопіювати всі \(item.stackCount)") { act(.copyAll) }
                } else {
                    pill(item.kind == .image ? "Зберегти" : "Показати у Finder") { act(.save) }
                }
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
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 150, height: 28)
                .background(Capsule().fill(Color.white.opacity(0.22)))
                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func corner(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.22)))
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
