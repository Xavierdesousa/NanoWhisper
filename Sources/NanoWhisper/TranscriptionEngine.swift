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
        case .parakeet: return "Nvidia · English only · Fast"
        case .whisper: return "OpenAI · Multilingual · Flexible"
        }
    }
}

// MARK: - Parakeet variants

/// Parakeet TDT 0.6B weights to load. Both share the architecture, the 25 European
/// languages (detected automatically) and the speed; only the weights differ.
enum ParakeetVariant: String, Codable, CaseIterable {
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
    /// - Returns: the stored variant when valid; otherwise v3 for existing installs (so an
    ///   update never triggers a surprise ~600 MB download) and Ultra for new installs.
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

enum WhisperModelSize: String, Codable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case largev3 = "large-v3"
    case largev3Turbo = "large-v3-turbo"

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
