import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask
    var key: String         // human-readable key, e.g. "1", "A", "F5"

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func keyName(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        if let s = special[Int(event.keyCode)] { return s }
        let c = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        return c.isEmpty ? "#\(event.keyCode)" : c
    }

    /// Menu key equivalent (only for plain characters).
    var menuKey: String { key.count == 1 ? key.lowercased() : "" }
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case area, window, fullscreen, previousArea, recordVideo, recordGIF, ocr, scrolling, pinClipboard, toggleDesktop, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Знімок області"
        case .window: return "Знімок вікна"
        case .fullscreen: return "Знімок усього екрана"
        case .previousArea: return "Повторити попередню область"
        case .recordVideo: return "Запис відео (старт/стоп)"
        case .recordGIF: return "Запис GIF (старт/стоп)"
        case .ocr: return "Розпізнати текст (OCR)"
        case .scrolling: return "Скролінг-знімок"
        case .pinClipboard: return "Закріпити з буфера"
        case .toggleDesktop: return "Сховати/показати іконки"
        case .history: return "Історія знімків"
        }
    }

    var defaultCombo: KeyCombo? {
        let m = UInt32(optionKey | shiftKey)
        switch self {
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: m, key: "1")
        case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: m, key: "2")
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: m, key: "3")
        case .previousArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: m, key: "4")
        case .recordVideo: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: m, key: "5")
        case .recordGIF: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: m, key: "6")
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: m, key: "7")
        case .scrolling: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: m, key: "8")
        case .pinClipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: m, key: "P")
        case .toggleDesktop: return nil
        case .history: return KeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: m, key: "H")
        }
    }

    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

enum HotKeyStore {
    private static func key(_ a: HotKeyAction) -> String { "hotkey.\(a.rawValue)" }

    static func combo(for a: HotKeyAction) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key(a)) else { return a.defaultCombo }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)   // empty data = explicitly cleared
    }

    static func set(_ c: KeyCombo?, for a: HotKeyAction) {
        let data = c.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key(a))
        NotificationCenter.default.post(name: .kadrHotKeysChanged, object: nil)
    }

    static func reset() {
        for a in HotKeyAction.allCases { UserDefaults.standard.removeObject(forKey: key(a)) }
        NotificationCenter.default.post(name: .kadrHotKeysChanged, object: nil)
    }
}

extension Notification.Name {
    static let kadrHotKeysChanged = Notification.Name("kadr.hotKeysChanged")
}

/// Global hotkeys via Carbon: works without Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private(set) var failed: [HotKeyAction] = []

    func registerAll(_ handler: @escaping (HotKeyAction) -> Void) {
        unregisterAll()
        installHandlerIfNeeded()
        failed = []
        for a in HotKeyAction.allCases {
            guard let c = HotKeyStore.combo(for: a) else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x4B41_4452), id: a.hotKeyID)  // 'KADR'
            let status = RegisterEventHotKey(c.keyCode, c.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[a.hotKeyID] = ref
                actions[a.hotKeyID] = { handler(a) }
            } else {
                failed.append(a)
            }
        }
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            let id = hkID.id
            Task { @MainActor in HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
