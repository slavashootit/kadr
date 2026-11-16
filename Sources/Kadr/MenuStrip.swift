import AppKit
import ImageIO
import SwiftUI

/// Small decoded thumbnails of saved captures, so menus and lists never decode full Retina shots.
enum Thumbs {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL, maxPixel: Int = 320) -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }

    /// Full image plus its Retina scale (stored as DPI when Kadr wrote the file).
    static func full(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (cg, max(1, CGFloat(dpi / 72).rounded()))
    }
}

/// Row of the latest captures inside the status menu: click copies, drag gives the file.
struct RecentStrip: View {
    let urls: [URL]
    let pick: (URL) -> Void

    static let height: CGFloat = 74

    var body: some View {
        HStack(spacing: 8) {
            ForEach(urls, id: \.self) { url in
                RecentThumb(url: url) { pick(url) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 320, height: Self.height, alignment: .leading)
    }
}

private struct RecentThumb: View {
    let url: URL
    let action: () -> Void
    @Local private var hover = false
    @Local private var pressed = false

    private var isImage: Bool { ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08))
            if isImage, let img = Thumbs.image(for: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(hover ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hover ? 2 : 0.5)
        )
        .scaleEffect(pressed ? 0.94 : (hover ? 1.06 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .onHover { hover = $0 }
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                pressed = false
                action()
            }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("\(url.lastPathComponent)\nКлік — скопіювати, перетягни — файл")
    }
}

/// Talks to Bufer (the clipboard history app) when it is installed.
@MainActor
enum BuferLink {
    static let bundleID = "com.slava.bufer"
    static let showPanel = Notification.Name("com.slava.bufer.showPanel")

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    static func openHistory() {
        let post = {
            DistributedNotificationCenter.default().postNotificationName(showPanel, object: nil, userInfo: nil, deliverImmediately: true)
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: post)
            }
        } else {
            post()
        }
    }
}
