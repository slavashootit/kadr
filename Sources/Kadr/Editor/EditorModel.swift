import AppKit
import CoreImage
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, filledRect, ellipse, pen, highlighter, text, counter, pixelate, blur, spotlight, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .filledRect: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .blur: return "drop"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return "Вибір і переміщення (V)"
        case .arrow: return "Стрілка (A)"
        case .line: return "Лінія (L)"
        case .rect: return "Прямокутник (R)"
        case .filledRect: return "Заливка (F)"
        case .ellipse: return "Еліпс (O)"
        case .pen: return "Олівець (P)"
        case .highlighter: return "Маркер (H)"
        case .text: return "Текст (T)"
        case .counter: return "Нумерація кроків (N)"
        case .pixelate: return "Пікселізація (X)"
        case .blur: return "Розмиття (B)"
        case .spotlight: return "Прожектор (S)"
        case .crop: return "Обрізати (C)"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .filledRect: return "f"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "x"
        case .blur: return "b"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }
}

struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable { case arrow, line, rect, filledRect, ellipse, pen, highlighter, text, counter, pixelate, blur, spotlight }

    var id = UUID()
    var kind: Kind
    var color: CGColor
    var width: CGFloat          // image pixels
    var start: CGPoint          // image pixel coords, top-left origin
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var unit: CGFloat = 1       // image pixels per point (Retina scale)

    var rect: CGRect { CGRect(p1: start, p2: end) }

    var fontSize: CGFloat { 12 * unit + 3 * width }

    func textFont() -> NSFont { NSFont.systemFont(ofSize: fontSize, weight: .bold) }

    func textSize() -> CGSize {
        let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: textFont()])
        return s.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin]).size
    }

    var counterRadius: CGFloat { 9 * unit + 1.6 * width }

    /// Hit/selection bounds in image pixels.
    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -width, dy: -width)
        case .text:
            let s = textSize()
            return CGRect(x: start.x - 6, y: start.y - 4, width: s.width + 12, height: s.height + 8)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            return rect.insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= max(width, tolerance)
        case .pen, .highlighter:
            for i in 1..<max(1, points.count) where distance(from: p, toSegment: points[i - 1], points[i]) <= max(width, tolerance) { return true }
            return points.count == 1 && hypot(p.x - points[0].x, p.y - points[0].y) <= tolerance
        case .rect, .ellipse:
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }

    mutating func move(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    static func == (a: Annotation, b: Annotation) -> Bool {
        a.id == b.id && a.start == b.start && a.end == b.end && a.points == b.points && a.text == b.text
            && a.width == b.width && a.color == b.color && a.number == b.number && a.kind == b.kind && a.unit == b.unit
    }
}

func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

struct BackgroundStyle: Equatable {
    var enabled = false
    var padding: CGFloat = 64        // points
    var cornerRadius: CGFloat = 12   // points
    var shadow = true
    var preset = 0

    static let presets: [[CGColor]] = [
        [CGColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 1), CGColor(red: 0.13, green: 0.70, blue: 0.98, alpha: 1)],
        [CGColor(red: 0.98, green: 0.45, blue: 0.40, alpha: 1), CGColor(red: 0.99, green: 0.76, blue: 0.33, alpha: 1)],
        [CGColor(red: 0.13, green: 0.80, blue: 0.62, alpha: 1), CGColor(red: 0.20, green: 0.47, blue: 0.95, alpha: 1)],
        [CGColor(red: 0.95, green: 0.38, blue: 0.70, alpha: 1), CGColor(red: 0.55, green: 0.35, blue: 0.98, alpha: 1)],
        [CGColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1), CGColor(red: 0.33, green: 0.35, blue: 0.43, alpha: 1)],
        [CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1), CGColor(red: 0.80, green: 0.83, blue: 0.89, alpha: 1)],
        [CGColor(red: 0.99, green: 0.84, blue: 0.26, alpha: 1), CGColor(red: 0.98, green: 0.47, blue: 0.20, alpha: 1)],
        [CGColor(red: 0.04, green: 0.08, blue: 0.20, alpha: 1), CGColor(red: 0.18, green: 0.10, blue: 0.40, alpha: 1)],
    ]
}

@MainActor
final class EditorModel: ObservableObject {
    let base: CGImage
    let scale: CGFloat
    let item: CaptureItem

    @Published var tool: Tool = .arrow { didSet { if tool != .select { selectedID = nil } } }
    @Published var color: CGColor = EditorModel.palette[0]
    @Published var strokeWidth: CGFloat = 4    // points
    @Published var annotations: [Annotation] = []
    @Published var crop: CGRect
    @Published var background = BackgroundStyle()
    @Published var selectedID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var dirty = false

    static let palette: [CGColor] = [
        CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        CGColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        CGColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        CGColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]

    private struct Snapshot { var annotations: [Annotation]; var crop: CGRect; var background: BackgroundStyle }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(item: CaptureItem) {
        self.item = item
        base = item.image!
        scale = item.scale
        crop = CGRect(x: 0, y: 0, width: base.width, height: base.height)
    }

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    var pixelWidth: CGFloat { strokeWidth * scale }

    func pushUndo() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop, background: background))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
        refreshUndoState()
    }

    /// Drops the last snapshot without restoring (e.g. an aborted tiny drag).
    func discardUndo() {
        _ = undoStack.popLast()
        refreshUndoState()
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop, background: background))
        apply(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop, background: background))
        apply(s)
    }

    private func apply(_ s: Snapshot) {
        annotations = s.annotations
        crop = s.crop
        background = s.background
        selectedID = nil
        dirty = true
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations.removeAll()
    }

    var nextCounter: Int { (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    /// Applies current color/width to the selected annotation.
    func styleChanged() {
        guard let id = selectedID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[i].color = color
        annotations[i].width = pixelWidth
    }

    // MARK: Filter caches

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    lazy var pixelated: CGImage? = {
        let ci = CIImage(cgImage: self.base)
        let f = CIFilter(name: "CIPixellate")
        f?.setValue(ci, forKey: kCIInputImageKey)
        f?.setValue(max(8, 10 * self.scale), forKey: kCIInputScaleKey)
        f?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = f?.outputImage?.cropped(to: ci.extent) else { return nil }
        return self.ciContext.createCGImage(out, from: ci.extent)
    }()

    lazy var blurred: CGImage? = {
        let ci = CIImage(cgImage: self.base)
        let f = CIFilter(name: "CIGaussianBlur")
        f?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f?.setValue(14 * self.scale, forKey: kCIInputRadiusKey)
        guard let out = f?.outputImage?.cropped(to: ci.extent) else { return nil }
        return self.ciContext.createCGImage(out, from: ci.extent)
    }()

    // MARK: Export

    /// Output size in pixels: crop plus background padding.
    var documentSize: CGSize {
        let pad = background.enabled ? background.padding * scale : 0
        return CGSize(width: crop.width + pad * 2, height: crop.height + pad * 2)
    }

    func render() -> CGImage? {
        let size = documentSize
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        Renderer.compose(ctx, model: self, editingCrop: false)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
