import AppKit

/// UserDefaults-backed preferences. SwiftUI settings use @AppStorage with the same keys.
enum PrefKey {
    static let saveFolder = "saveFolder"
    static let imageFormat = "imageFormat"            // "png" | "jpg"
    static let afterSave = "afterSave"
    static let afterCopy = "afterCopy"
    static let afterOverlay = "afterOverlay"
    static let afterOpenEditor = "afterOpenEditor"
    static let downscaleRetina = "downscaleRetina"
    static let playSound = "playSound"
    static let windowShadow = "windowShadow"
    static let overlayAutoClose = "overlayAutoClose"  // seconds, 0 = never
    static let showMagnifier = "showMagnifier"
    static let recordFPS = "recordFPS"
    static let recordCursor = "recordCursor"
    static let recordClicks = "recordClicks"
    static let recordKeys = "recordKeys"
    static let recordSystemAudio = "recordSystemAudio"
    static let recordMic = "recordMic"
    static let recordHEVC = "recordHEVC"
    static let gifFPS = "gifFPS"
    static let gifMaxWidth = "gifMaxWidth"
    static let lastArea = "lastArea"
    static let history = "history"
}

enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            PrefKey.saveFolder: defaultFolder.path,
            PrefKey.imageFormat: "png",
            PrefKey.afterSave: true,
            PrefKey.afterCopy: true,
            PrefKey.afterOverlay: true,
            PrefKey.afterOpenEditor: false,
            PrefKey.downscaleRetina: false,
            PrefKey.playSound: true,
            PrefKey.windowShadow: true,
            PrefKey.overlayAutoClose: 20,
            PrefKey.showMagnifier: true,
            PrefKey.recordFPS: 60,
            PrefKey.recordCursor: true,
            PrefKey.recordClicks: true,
            PrefKey.recordKeys: false,
            PrefKey.recordSystemAudio: true,
            PrefKey.recordMic: false,
            PrefKey.recordHEVC: false,
            PrefKey.gifFPS: 15,
            PrefKey.gifMaxWidth: 960,
        ])
    }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Kadr", isDirectory: true)
    }

    static var saveFolder: URL {
        get { URL(fileURLWithPath: d.string(forKey: PrefKey.saveFolder) ?? defaultFolder.path, isDirectory: true) }
        set { d.set(newValue.path, forKey: PrefKey.saveFolder) }
    }
    static var imageFormat: String { d.string(forKey: PrefKey.imageFormat) ?? "png" }
    static var afterSave: Bool { d.bool(forKey: PrefKey.afterSave) }
    static var afterCopy: Bool { d.bool(forKey: PrefKey.afterCopy) }
    static var afterOverlay: Bool { d.bool(forKey: PrefKey.afterOverlay) }
    static var afterOpenEditor: Bool { d.bool(forKey: PrefKey.afterOpenEditor) }
    static var downscaleRetina: Bool { d.bool(forKey: PrefKey.downscaleRetina) }
    static var playSound: Bool { d.bool(forKey: PrefKey.playSound) }
    static var windowShadow: Bool { d.bool(forKey: PrefKey.windowShadow) }
    static var overlayAutoClose: Int { d.integer(forKey: PrefKey.overlayAutoClose) }
    static var showMagnifier: Bool { d.bool(forKey: PrefKey.showMagnifier) }
    static var recordFPS: Int { max(10, d.integer(forKey: PrefKey.recordFPS)) }
    static var recordCursor: Bool { d.bool(forKey: PrefKey.recordCursor) }
    static var recordClicks: Bool { d.bool(forKey: PrefKey.recordClicks) }
    static var recordKeys: Bool { d.bool(forKey: PrefKey.recordKeys) }
    static var recordSystemAudio: Bool { d.bool(forKey: PrefKey.recordSystemAudio) }
    static var recordMic: Bool { d.bool(forKey: PrefKey.recordMic) }
    static var recordHEVC: Bool { d.bool(forKey: PrefKey.recordHEVC) }
    static var gifFPS: Int { max(5, d.integer(forKey: PrefKey.gifFPS)) }
    static var gifMaxWidth: Int { max(240, d.integer(forKey: PrefKey.gifMaxWidth)) }

    /// Last captured area: display ID + rect in display-local points (top-left origin).
    static var lastArea: (CGDirectDisplayID, CGRect)? {
        get {
            guard let a = d.array(forKey: PrefKey.lastArea) as? [Double], a.count == 5 else { return nil }
            return (CGDirectDisplayID(a[0]), CGRect(x: a[1], y: a[2], width: a[3], height: a[4]))
        }
        set {
            guard case let (id, r)? = newValue else { d.removeObject(forKey: PrefKey.lastArea); return }
            d.set([Double(id), r.minX, r.minY, r.width, r.height], forKey: PrefKey.lastArea)
        }
    }
}
