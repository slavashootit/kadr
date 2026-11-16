import AppKit
import UniformTypeIdentifiers

enum KadrError: LocalizedError {
    case noPermission
    case noDisplay
    case writeFailed
    case nothingToDo(String)

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Немає дозволу на запис екрана."
        case .noDisplay: return "Не знайшов дисплей."
        case .writeFailed: return "Не вдалося записати файл."
        case .nothingToDo(let s): return s
        }
    }
}

enum Storage {
    static func folder() -> URL {
        let url = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// "Kadr 2026-10-10 at 14.03.22.png", made unique within the folder.
    static func newURL(prefix: String = "Kadr", ext: String, in dir: URL? = nil) -> URL {
        let base = "\(prefix) \(stamp.string(from: Date()))"
        let dir = dir ?? folder()
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static var tempDir: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kadr", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var imageExt: String { Prefs.imageFormat == "jpg" ? "jpg" : "png" }

    /// Writes an image; `scale` is stored as DPI so Preview shows Retina shots at their point size.
    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let type = (isJPEG ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw KadrError.writeFailed }
        var props: [String: Any] = [
            kCGImagePropertyDPIWidth as String: 72 * scale,
            kCGImagePropertyDPIHeight as String: 72 * scale,
        ]
        if isJPEG { props[kCGImageDestinationLossyCompressionQuality as String] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw KadrError.writeFailed }
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Every write goes through one ordered queue. Image data is encoded *before* the pasteboard is
/// cleared, so clipboard managers never catch it empty, and consecutive writes are spaced out so a
/// manager that polls `changeCount` sees each capture of a rapid series, not only the last one.
enum Clipboard {
    /// Marks a pasteboard item as coming from Kadr; the value is the saved file path (may be empty).
    static let sourceType = NSPasteboard.PasteboardType("com.slava.kadr.source")
    /// Posted right after each write so Bufer can read it immediately instead of waiting for its poll.
    static let didWrite = Notification.Name("com.slava.kadr.clipboardDidWrite")

    /// Longest poll interval we protect against (Bufer's default is 0.5 s).
    private static let minGap: TimeInterval = 0.6
    private static let encodeQueue = DispatchQueue(label: "kadr.clipboard.encode", qos: .userInitiated)
    private static var pending: [() -> Void] = []   // main thread only
    private static var draining = false
    private static var lastWrite = Date.distantPast

    static func copy(_ image: CGImage, scale: CGFloat, file: URL? = nil) {
        encodeQueue.async {
            let rep = NSBitmapImageRep(cgImage: image)
            let png = rep.representation(using: .png, properties: [:])
            // Point size makes Retina shots paste at their on-screen size in apps that read TIFF.
            rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw])
            enqueue {
                let item = NSPasteboardItem()
                if let png { item.setData(png, forType: .png) }
                if let tiff { item.setData(tiff, forType: .tiff) }
                item.setString(file?.path ?? "", forType: sourceType)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([item])
            }
        }
    }

    static func copy(file url: URL) {
        // Through the encode queue too, so it keeps its place among image copies.
        encodeQueue.async {
            enqueue {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([url as NSURL])
            }
        }
    }

    static func copy(text: String) {
        encodeQueue.async {
            enqueue {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    private static func enqueue(_ write: @escaping () -> Void) {
        DispatchQueue.main.async {
            pending.append(write)
            drain()
        }
    }

    private static func drain() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        let wait = max(0, minGap - Date().timeIntervalSince(lastWrite))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            let write = pending.removeFirst()
            write()
            lastWrite = Date()
            DistributedNotificationCenter.default().postNotificationName(didWrite, object: nil, userInfo: nil, deliverImmediately: true)
            draining = false
            drain()
        }
    }

    static func image() -> (CGImage, CGFloat)? {
        guard let ns = NSImage(pasteboard: NSPasteboard.general) else { return nil }
        var rect = CGRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let scale = ns.size.width > 0 ? CGFloat(cg.width) / ns.size.width : 1
        return (cg, max(1, scale.rounded()))
    }
}

enum Sound {
    static func shutter() {
        guard Prefs.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let s = NSSound(contentsOfFile: path, byReference: true) { s.play() } else { NSSound(named: "Tink")?.play() }
    }

    static func start() {
        guard Prefs.playSound else { return }
        NSSound(named: "Pop")?.play()
    }
}

/// Recent captures, newest first.
enum History {
    static let limit = 300

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: PrefKey.history) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: PrefKey.history) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: PrefKey.history)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: PrefKey.history) }
}

extension CGImage {
    func scaled(by factor: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(width) * factor)), h = max(1, Int(CGFloat(height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var withMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    /// Converts a rect in this screen's local top-left coordinates (points) to global AppKit coordinates.
    func globalRect(fromTopLeft r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}

/// Marks windows that must never appear in our own captures (overlays, HUDs, recording chrome).
@MainActor
enum Exclusion {
    static let identifier = NSUserInterfaceItemIdentifier("kadr.exclude")

    static var windowIDs: Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.identifier == identifier && $0.isVisible }.map { CGWindowID($0.windowNumber) })
    }
}
