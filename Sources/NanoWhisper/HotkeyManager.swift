import Carbon
import AppKit

// Global reference for the C callback
nonisolated(unsafe) private var hotkeyManagerInstance: HotkeyManager?

// C-compatible callback
private func hotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    hotkeyManagerInstance?.onHotkeyPressed?()
    return noErr
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    // Default: Option + Space
    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    // Persist to UserDefaults
    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcut_keyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "shortcut_modifiers")
    }

    static func load() -> Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "shortcut_keyCode") != nil else {
            return .default
        }
        let keyCode = UInt32(defaults.integer(forKey: "shortcut_keyCode"))
        let modifiers = UInt32(defaults.integer(forKey: "shortcut_modifiers"))
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// Convert NSEvent modifier flags to Carbon modifier mask
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onHotkeyPressed: (() -> Void)?
    private(set) var currentShortcut: Shortcut

    init() {
        currentShortcut = Shortcut.load()
        hotkeyManagerInstance = self
        registerHotkey(currentShortcut)
    }

    deinit {
        unregisterHotkey()
    }

    func updateShortcut(_ shortcut: Shortcut) {
        currentShortcut = shortcut
        shortcut.save()
        registerHotkey(shortcut)
    }

    func registerHotkey(_ shortcut: Shortcut) {
        unregisterHotkey()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4E57), // "NW"
            id: 1
        )

        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}

// MARK: - Key code to string mapping

private func keyCodeToString(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab: return "⇥"
    case kVK_Delete: return "⌫"
    case kVK_Escape: return "⎋"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    default:
        // Use the system to get the character for this key code
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        if length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return "?"
    }
}
