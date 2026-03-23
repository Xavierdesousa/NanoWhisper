import Foundation

// MARK: - Model type selection

enum TranscriptionModelType: String, Codable, CaseIterable {
    case parakeet
    case whisper

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet TDT 0.6B v3"
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

// MARK: - Whisper model sizes

enum WhisperModelSize: String, Codable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case largev3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev3: return "Large v3"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~150 MB"
        case .small: return "~500 MB"
        case .medium: return "~1.5 GB"
        case .largev3: return "~3 GB"
        }
    }

    /// Model identifier for WhisperKit
    var whisperKitModel: String {
        return "openai_whisper-\(rawValue)"
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
