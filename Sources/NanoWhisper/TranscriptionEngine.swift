import Foundation

// MARK: - Model type selection

enum TranscriptionModelType: String, Codable, CaseIterable {
    case parakeet
    case whisper

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeet: return "NVIDIA · 25 European languages · Fastest"
        case .whisper: return "OpenAI · 99 languages · Vocabulary hints"
        }
    }
}

// MARK: - Parakeet variants

/// Parakeet TDT 0.6B weights to load. Both share the architecture, the 25 European
/// languages (detected automatically) and the speed; only the weights differ. Both stay
/// selectable while they are published upstream (maintainer rule, 2026-11-20).
enum ParakeetVariant: String, Codable, CaseIterable, Sendable {
    /// NVIDIA Parakeet TDT 0.6B v3.
    case v3
    /// Parakeet Ultra: post-trained v3 with lower error rates in every measured language.
    case ultra

    /// UserDefaults key holding the persisted variant.
    static let defaultsKey = "parakeetVariant"

    /// Variant used by new installs.
    static let newInstallDefault: ParakeetVariant = .ultra
    /// Variant kept by installs that predate the choice (their models are already on disk).
    static let existingInstallDefault: ParakeetVariant = .v3

    /// Shown with a "Recommended" badge in the pickers. Ultra is also the new-install default
    /// and the target of the v3 migration step (`ModelMigrations.steps`).
    var isRecommended: Bool { self == .ultra }

    var displayName: String {
        switch self {
        case .v3: return "Parakeet TDT 0.6B v3"
        case .ultra: return "Parakeet Ultra"
        }
    }

    /// Approximate download size of the Core ML bundle.
    var sizeDescription: String {
        switch self {
        case .v3: return "~480 MB"
        case .ultra: return "~630 MB"
        }
    }

    /// Hugging Face repository FluidAudio downloads this variant from.
    var huggingFaceRepo: String {
        switch self {
        case .v3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .ultra: return "FluidInference/parakeet-ultra-coreml"
        }
    }

    /// Resolve the variant to use at launch.
    ///
    /// - Parameters:
    ///   - storedValue: raw value persisted under `defaultsKey`, if any.
    ///   - isExistingInstall: whether the app was set up before variants existed
    ///     (onboarding completed or a model type already persisted).
    /// - Returns: the stored variant when valid; otherwise v3 for existing installs (what
    ///   0.0.5 resolved them to) and Ultra for new installs. `ModelMigrations` then moves v3
    ///   installs to Ultra once, without a gap in dictation.
    static func resolve(storedValue: String?, isExistingInstall: Bool) -> ParakeetVariant {
        if let storedValue, let variant = ParakeetVariant(rawValue: storedValue) {
            return variant
        }
        return isExistingInstall ? existingInstallDefault : newInstallDefault
    }

    /// UserDefaults keys whose presence shows the app was already set up before.
    static let existingInstallMarkerKeys = ["onboardingComplete", "selectedModelType", "whisperSettings"]

    /// Read the persisted variant, migrating installs that predate it, and persist the result
    /// so the decision is made once (a new install that quits mid-onboarding stays on Ultra).
    static func loadOrMigrate(from defaults: UserDefaults) -> ParakeetVariant {
        let isExistingInstall = existingInstallMarkerKeys.contains { defaults.object(forKey: $0) != nil }
        let variant = resolve(
            storedValue: defaults.string(forKey: defaultsKey),
            isExistingInstall: isExistingInstall
        )
        defaults.set(variant.rawValue, forKey: defaultsKey)
        return variant
    }
}

// MARK: - Whisper model sizes

/// Whisper sizes. Offered: Base, Small, Large v3 Turbo. Tiny, Medium and Large v3 are obsolete
/// (see `replacement`): kept so a stored choice decodes and is replaced smoothly, and so their
/// folders can be recognized and removed.
enum WhisperModelSize: String, Codable, CaseIterable, Sendable {
    /// Obsolete since 0.0.6 (curation), replaced by Base.
    case tiny
    case base
    case small
    /// Obsolete since 0.0.5: no longer in WhisperKit's supported-model list for any Mac.
    case medium
    /// Obsolete since 0.0.6 (curation), replaced by Large v3 Turbo.
    case largev3 = "large-v3"
    case largev3Turbo = "large-v3-turbo"

    /// For an obsolete size (no longer offered), the size that replaces it. A stored obsolete
    /// size is replaced at launch (`ObsoleteModels`) with the smooth switchover, language and
    /// vocabulary hint kept. Not a migration step: steps move people to a better recommended
    /// model; a replacement exists because the old model is no longer offered.
    ///
    /// Tiny and Large v3 are still published upstream but were dropped from the app on purpose
    /// (maintainer curation, 2026-11-20): on Apple Silicon Tiny is no faster than Base in
    /// practice and much less accurate, and Large v3 is superseded by its Turbo variant.
    var replacement: WhisperModelSize? {
        switch self {
        case .tiny: return .base
        case .medium, .largev3: return .largev3Turbo
        case .base, .small, .largev3Turbo: return nil
        }
    }

    /// Whether the size is offered in the pickers.
    var isSelectable: Bool { replacement == nil }

    /// Sizes offered in the pickers, in display order.
    static var selectable: [WhisperModelSize] { allCases.filter(\.isSelectable) }

    /// Shown with a "Recommended" badge in the pickers. Large v3 Turbo: accuracy close to
    /// Large v3 at a fifth of the size. Whisper users are not migrated: they keep their size.
    var isRecommended: Bool { self == .largev3Turbo }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev3: return "Large v3"
        case .largev3Turbo: return "Large v3 Turbo"
        }
    }

    /// Approximate download size (sum of the files in argmaxinc/whisperkit-coreml).
    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~150 MB"
        case .small: return "~490 MB"
        case .medium: return "~1.5 GB"
        case .largev3: return "~3.1 GB"
        case .largev3Turbo: return "~630 MB"
        }
    }

    /// Model folder name in the argmaxinc/whisperkit-coreml repository.
    var whisperKitModel: String {
        switch self {
        case .largev3Turbo:
            // OpenAI's large-v3-turbo (release v20240930), compressed to 626 MB. Supported on
            // every Apple Silicon Mac in WhisperKit's model-support config and the default on M1.
            return "openai_whisper-large-v3-v20240930_626MB"
        default:
            return "openai_whisper-\(rawValue)"
        }
    }
}

// MARK: - Whisper settings

struct WhisperSettings: Codable, Equatable {
    var modelSize: WhisperModelSize = .base
    var language: String? = nil // nil = auto-detect
    var promptText: String = "" // vocabulary hint / initial prompt

    /// UserDefaults key holding the JSON-encoded settings.
    static let defaultsKey = "whisperSettings"

    /// Load the persisted settings. An obsolete size (Medium) decodes as itself; it is replaced
    /// at launch by `ObsoleteModels.replace`, which keeps Medium working until the replacement
    /// is downloaded. 0.0.5 rewrote a stored Medium here; such installs already hold Large v3
    /// Turbo and are not replaced again.
    static func load(from defaults: UserDefaults) -> WhisperSettings? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WhisperSettings.self, from: data)
    }

    /// Display string for the selected language
    var languageDisplayName: String {
        guard let lang = language else { return "Auto-detect" }
        return WhisperLanguage.displayName(for: lang)
    }

    var modelDisplayName: String {
        let lang = languageDisplayName
        return "Whisper \(modelSize.displayName) · \(lang)"
    }
}

// MARK: - Supported Whisper languages

enum WhisperLanguage {
    static let supported: [(code: String, name: String)] = [
        ("af", "Afrikaans"),
        ("ar", "Arabic"),
        ("hy", "Armenian"),
        ("az", "Azerbaijani"),
        ("be", "Belarusian"),
        ("bs", "Bosnian"),
        ("bg", "Bulgarian"),
        ("ca", "Catalan"),
        ("zh", "Chinese"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("gl", "Galician"),
        ("de", "German"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("hi", "Hindi"),
        ("hu", "Hungarian"),
        ("is", "Icelandic"),
        ("id", "Indonesian"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("kn", "Kannada"),
        ("kk", "Kazakh"),
        ("ko", "Korean"),
        ("lv", "Latvian"),
        ("lt", "Lithuanian"),
        ("mk", "Macedonian"),
        ("ms", "Malay"),
        ("mr", "Marathi"),
        ("mi", "Maori"),
        ("ne", "Nepali"),
        ("no", "Norwegian"),
        ("fa", "Persian"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sr", "Serbian"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("es", "Spanish"),
        ("sw", "Swahili"),
        ("sv", "Swedish"),
        ("tl", "Tagalog"),
        ("ta", "Tamil"),
        ("th", "Thai"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("ur", "Urdu"),
        ("vi", "Vietnamese"),
        ("cy", "Welsh"),
    ]

    static func displayName(for code: String) -> String {
        supported.first(where: { $0.code == code })?.name ?? code
    }
}
