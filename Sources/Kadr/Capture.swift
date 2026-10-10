import AppKit
import ScreenCaptureKit

struct DisplayShot {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

struct WindowCandidate {
    let window: SCWindow
    let frame: CGRect      // global CG coordinates (top-left of primary display), points
    let appName: String
    let title: String
}

@MainActor
enum Capture {
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw KadrError.noPermission
        }
    }

    static func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        let ids = Exclusion.windowIDs
        return content.windows.filter { ids.contains($0.windowID) }
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == screen.displayID }
    }

    /// Full-resolution image of one display, without our own overlay windows.
    static func shot(of screen: NSScreen, content: SCShareableContent, showCursor: Bool = false) async throws -> DisplayShot {
        guard let display = display(for: screen, in: content) else { throw KadrError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return DisplayShot(screen: screen, display: display, image: image)
    }

    static func shotsOfAllScreens() async throws -> (shots: [DisplayShot], content: SCShareableContent) {
        let content = try await content()
        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            if let s = try? await shot(of: screen, content: content) { shots.append(s) }
        }
        if shots.isEmpty { throw KadrError.noPermission }
        return (shots, content)
    }

    /// Captures a single window independent of what overlaps it (with or without its shadow).
    static func image(of window: SCWindow) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !Prefs.windowShadow
        config.shouldBeOpaque = false
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Area of a screen (display-local top-left points) captured live.
    static func image(of rect: CGRect, on screen: NSScreen) async throws -> (CGImage, CGFloat) {
        let content = try await content()
        let shot = try await shot(of: screen, content: content)
        guard let img = crop(shot.image, to: rect, scale: shot.scale) else { throw KadrError.noDisplay }
        return (img, shot.scale)
    }

    static func crop(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !px.isEmpty else { return nil }
        return image.cropping(to: px)
    }

    /// Normal app windows, front to back.
    static func windowCandidates(_ content: SCShareableContent) -> [WindowCandidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [WindowCandidate] = []
        for dict in info {
            guard let num = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own,
                  let w = byID[num], w.frame.width > 40, w.frame.height > 40 else { continue }
            let app = w.owningApplication?.applicationName ?? (dict[kCGWindowOwnerName as String] as? String ?? "")
            result.append(WindowCandidate(window: w, frame: w.frame, appName: app, title: w.title ?? ""))
        }
        return result
    }

    static func showPermissionAlert() {
        let a = NSAlert()
        a.messageText = "Kadr потрібен дозвіл на запис екрана"
        a.informativeText = "Відкрий Системні параметри → Приватність і безпека → Запис екрана й аудіо системи, увімкни Kadr і перезапусти додаток."
        a.addButton(withTitle: "Відкрити параметри")
        a.addButton(withTitle: "Пізніше")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
