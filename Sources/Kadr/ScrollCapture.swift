import AppKit
import ScreenCaptureKit
import SwiftUI

/// Scrolling capture: the user scrolls the selected area, frames are stitched by matching overlapping rows.
@MainActor
final class ScrollCapture: ObservableObject {
    static let shared = ScrollCapture()

    @Published private(set) var running = false
    @Published private(set) var heightPx = 0
    private var strips: [CGImage] = []
    private var lastSig: RowSignature?
    private var loop: Task<Void, Never>?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var scale: CGFloat = 2
    private var chrome: [NSWindow] = []
    private let maxHeight = 40_000

    func start() async {
        guard !running else { finish(); return }
        guard let sel = await SelectionController.run(mode: .area, allowWindowMode: true, hint: "Скролінг-знімок") else { return }
        let (screen, r) = sel.screenAndRect
        let rect = r.integral
        guard rect.width >= 40, rect.height >= 80 else { HUD.error("Область замала для скролінгу"); return }

        showChrome(rect: rect, on: screen)
        do {
            let content = try await Capture.content()
            guard let display = Capture.display(for: screen, in: content) else { throw KadrError.noDisplay }
            filter = SCContentFilter(display: display, excludingWindows: Capture.excludedWindows(in: content))
            let cfg = SCStreamConfiguration()
            scale = screen.backingScaleFactor
            cfg.sourceRect = rect
            cfg.width = Int(rect.width * scale)
            cfg.height = Int(rect.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            cfg.colorSpaceName = CGColorSpace.sRGB
            config = cfg
        } catch {
            tearDown()
            Capture.showPermissionAlert()
            return
        }

        strips = []
        lastSig = nil
        heightPx = 0
        running = true
        loop = Task { [weak self] in
            while let self, self.running {
                await self.tick()
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }
    }

    private func tick() async {
        guard let filter, let config,
              let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        let sig = await Task.detached(priority: .userInitiated) { RowSignature(img) }.value
        guard let sig else { return }
        guard let last = lastSig else {
            strips = [img]
            lastSig = sig
            heightPx = img.height
            return
        }
        let dy = await Task.detached(priority: .userInitiated) { RowSignature.offset(from: last, to: sig) }.value
        guard let dy, dy > 0 else { return }
        if let strip = img.cropping(to: CGRect(x: 0, y: img.height - dy, width: img.width, height: dy)) {
            strips.append(strip)
            heightPx += dy
        }
        lastSig = sig
        if heightPx >= maxHeight { finish() }
    }

    func finish() {
        guard running else { return }
        running = false
        loop?.cancel()
        loop = nil
        tearDown()
        guard let image = compose() else { HUD.error("Нічого не знято"); return }
        AppCoordinator.shared.deliver(image: image, scale: scale, screenRect: nil)
    }

    func cancel() {
        running = false
        loop?.cancel()
        loop = nil
        strips = []
        tearDown()
    }

    private func compose() -> CGImage? {
        guard let first = strips.first else { return nil }
        let w = first.width
        let h = strips.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = h
        for s in strips {
            y -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: y, width: w, height: s.height))
        }
        return ctx.makeImage()
    }

    private func showChrome(rect: CGRect, on screen: NSScreen) {
        let g = screen.globalRect(fromTopLeft: rect)
        let border = NSWindow(contentRect: g.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        border.identifier = Exclusion.identifier
        border.isReleasedWhenClosed = false
        border.level = .screenSaver
        border.backgroundColor = .clear
        border.isOpaque = false
        border.ignoresMouseEvents = true
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bv = NSView(frame: CGRect(origin: .zero, size: border.frame.size))
        bv.wantsLayer = true
        bv.layer?.borderColor = NSColor.systemBlue.cgColor
        bv.layer?.borderWidth = 2.5
        bv.layer?.cornerRadius = 3
        border.contentView = bv
        border.orderFrontRegardless()
        chrome.append(border)

        let size = CGSize(width: 330, height: 44)
        var origin = CGPoint(x: g.midX - size.width / 2, y: g.maxY + 10)
        if origin.y + size.height > screen.visibleFrame.maxY { origin.y = g.minY - size.height - 10 }
        if origin.y < screen.visibleFrame.minY { origin = CGPoint(x: g.midX - size.width / 2, y: g.maxY - size.height - 10) }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Exclusion.identifier
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ScrollControls(capture: self))
        panel.orderFrontRegardless()
        chrome.append(panel)
    }

    private func tearDown() {
        chrome.forEach { $0.orderOut(nil) }
        chrome.removeAll()
        filter = nil
        config = nil
        lastSig = nil
    }
}

private struct ScrollControls: View {
    @ObservedObject var capture: ScrollCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").foregroundStyle(.white)
            Text(capture.heightPx == 0 ? "Скроль повільно вниз" : "\(capture.heightPx) px")
                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
            Spacer()
            Button("Готово") { capture.finish() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { capture.cancel() } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.8)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: 330, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.85)))
    }
}

/// Per-row luminance samples used to find how far content moved between two frames.
struct RowSignature: Sendable {
    let rows: Int
    let cols: Int
    let data: [Float]

    init?(_ image: CGImage, cols: Int = 96) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let c = min(cols, w)
        var d = [Float](repeating: 0, count: h * c)
        for r in 0..<h {
            let rowBase = r * w * 4
            for i in 0..<c {
                let x = (i * w + w / 2) / c
                let o = rowBase + x * 4
                d[r * c + i] = 0.299 * Float(buf[o]) + 0.587 * Float(buf[o + 1]) + 0.114 * Float(buf[o + 2])
            }
        }
        rows = h
        self.cols = c
        data = d
    }

    private func variance(rows start: Int, count: Int) -> Float {
        var sum: Float = 0, sq: Float = 0
        let n = Float(count * cols)
        for r in start..<(start + count) {
            for i in 0..<cols { let v = data[r * cols + i]; sum += v; sq += v * v }
        }
        let mean = sum / n
        return sq / n - mean * mean
    }

    /// Vertical scroll distance in pixels from `p` to `f` (content moved up), or nil if no confident match.
    static func offset(from p: RowSignature, to f: RowSignature) -> Int? {
        guard p.rows == f.rows, p.cols == f.cols, p.rows > 60 else { return nil }
        let h = p.rows, cols = p.cols
        let t = max(16, min(64, h / 8))
        // Pick a template band in the previous frame that has some texture.
        var tStart: Int?
        for frac in [0.6, 0.45, 0.75, 0.3] {
            let s = Int(Double(h) * frac)
            if s + t < h, p.variance(rows: s, count: t) > 20 { tStart = s; break }
        }
        guard let ts = tStart else { return nil }

        var bestErr = Float.infinity
        var bestY = ts
        // y = template position in the new frame; scanning from ts downwards prefers small offsets on ties.
        for y in stride(from: ts, through: 0, by: -1) {
            var err: Float = 0
            for k in 0..<t {
                let pr = (ts + k) * cols, fr = (y + k) * cols
                for i in 0..<cols { err += abs(p.data[pr + i] - f.data[fr + i]) }
                if err >= bestErr { break }
            }
            if err < bestErr { bestErr = err; bestY = y }
        }
        let meanErr = bestErr / Float(t * cols)
        guard meanErr < 4 else { return nil }
        return ts - bestY
    }
}
