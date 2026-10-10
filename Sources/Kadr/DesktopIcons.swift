import AppKit
import ScreenCaptureKit

/// Hides desktop icons by covering them with a wallpaper-only window (Finder is never restarted).
@MainActor
final class DesktopIcons {
    static let shared = DesktopIcons()
    private var windows: [NSWindow] = []
    var isHidden: Bool { !windows.isEmpty }

    func toggle() { isHidden ? show() : hide() }

    func show() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    func hide() {
        guard !isHidden else { return }
        Task {
            let wallpapers = await wallpaperShots()
            for screen in NSScreen.screens {
                let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.setFrame(screen.frame, display: false)
                w.isReleasedWhenClosed = false
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                w.ignoresMouseEvents = true
                w.hasShadow = false
                let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
                v.wantsLayer = true
                if let img = wallpapers[screen.displayID] {
                    v.layer?.contents = img
                } else if let url = NSWorkspace.shared.desktopImageURL(for: screen), let img = NSImage(contentsOf: url) {
                    v.layer?.contents = img
                } else {
                    v.layer?.backgroundColor = (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor ?? .black).cgColor
                }
                v.layer?.contentsGravity = .resizeAspectFill
                w.contentView = v
                w.orderFront(nil)
                windows.append(w)
            }
            HUD.show("Іконки робочого столу сховано", symbol: "eye.slash")
        }
    }

    /// Captures the Dock-owned wallpaper windows, which works for dynamic and aerial wallpapers too.
    private func wallpaperShots() async -> [CGDirectDisplayID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        var result: [CGDirectDisplayID: CGImage] = [:]
        let candidates = content.windows.filter {
            ($0.title ?? "").hasPrefix("Wallpaper") &&
                ["com.apple.dock", "com.apple.wallpaper.agent", "com.apple.WallpaperAgent"].contains($0.owningApplication?.bundleIdentifier ?? "")
        }
        for screen in NSScreen.screens {
            let bounds = CGDisplayBounds(screen.displayID)
            guard let w = candidates.first(where: { $0.frame.intersects(bounds) && abs($0.frame.width - bounds.width) < 2 }) else { continue }
            if let r = try? await Capture.image(of: w) { result[screen.displayID] = r.0 }
        }
        return result
    }
}
