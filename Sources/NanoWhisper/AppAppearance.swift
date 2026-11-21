import AppKit

/// The app's appearance, chosen in Settings › General: System (follows macOS), Light or Dark.
/// It applies to the whole app through `NSApp.appearance`: Settings, onboarding, History, the
/// end-of-onboarding popover and the recording overlay. None of them sets an appearance of its
/// own, so each follows a change at once, also during a recording.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// `UserDefaults` key of the setting.
    static let defaultsKey = "appearance"
    static let defaultValue: AppAppearance = .system

    var id: String { rawValue }

    /// Name in Settings.
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The AppKit appearance it sets; nil follows macOS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    var nsAppearance: NSAppearance? { appearanceName.flatMap(NSAppearance.init(named:)) }

    /// The stored choice, or System when none or an unknown value is stored.
    static func load(from defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? defaultValue
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// Sets it on the application: every window without an appearance of its own follows.
    @MainActor
    func apply(to application: NSApplication? = NSApp) {
        application?.appearance = nsAppearance
    }
}
