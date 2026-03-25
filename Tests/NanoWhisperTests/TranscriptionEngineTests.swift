import Foundation
import Testing
@testable import NanoWhisper

@Suite("TranscriptionEngine")
struct TranscriptionEngineTests {

    // MARK: - TranscriptionModelType

    @Test("All model types have non-empty displayName and subtitle")
    func modelTypeProperties() {
        for model in TranscriptionModelType.allCases {
            #expect(!model.displayName.isEmpty)
            #expect(!model.subtitle.isEmpty)
        }
    }

    @Test("Parakeet display values")
    func parakeetDisplay() {
        let model = TranscriptionModelType.parakeet
        #expect(model.displayName == "Parakeet TDT 0.6B v3")
        #expect(model.subtitle.contains("Nvidia"))
    }

    @Test("Whisper display values")
    func whisperDisplay() {
        let model = TranscriptionModelType.whisper
        #expect(model.displayName == "Whisper")
        #expect(model.subtitle.contains("OpenAI"))
    }

    // MARK: - WhisperModelSize

    @Test("All model sizes have non-empty properties")
    func modelSizeProperties() {
        for size in WhisperModelSize.allCases {
            #expect(!size.displayName.isEmpty)
            #expect(!size.sizeDescription.isEmpty)
            #expect(size.whisperKitModel.hasPrefix("openai_whisper-"))
        }
    }

    @Test("WhisperKit model identifier format")
    func whisperKitModelFormat() {
        #expect(WhisperModelSize.tiny.whisperKitModel == "openai_whisper-tiny")
        #expect(WhisperModelSize.base.whisperKitModel == "openai_whisper-base")
        #expect(WhisperModelSize.largev3.whisperKitModel == "openai_whisper-large-v3")
    }

    // MARK: - WhisperSettings

    @Test("Default WhisperSettings values")
    func defaultSettings() {
        let settings = WhisperSettings()
        #expect(settings.modelSize == .base)
        #expect(settings.language == nil)
        #expect(settings.promptText == "")
    }

    @Test("WhisperSettings Codable roundtrip")
    func settingsCodable() throws {
        var settings = WhisperSettings()
        settings.modelSize = .medium
        settings.language = "fr"
        settings.promptText = "NanoWhisper CoreML"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(WhisperSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("languageDisplayName returns Auto-detect when nil")
    func autoDetectLanguage() {
        let settings = WhisperSettings()
        #expect(settings.languageDisplayName == "Auto-detect")
    }

    @Test("languageDisplayName returns correct name for known code")
    func knownLanguage() {
        var settings = WhisperSettings()
        settings.language = "en"
        #expect(settings.languageDisplayName == "English")
    }

    @Test("modelDisplayName format")
    func modelDisplayName() {
        var settings = WhisperSettings()
        settings.modelSize = .small
        settings.language = "ja"
        #expect(settings.modelDisplayName == "Whisper Small · Japanese")
    }

    // MARK: - WhisperLanguage

    @Test("displayName for known codes")
    func languageLookup() {
        #expect(WhisperLanguage.displayName(for: "en") == "English")
        #expect(WhisperLanguage.displayName(for: "ja") == "Japanese")
        #expect(WhisperLanguage.displayName(for: "fr") == "French")
    }

    @Test("displayName returns raw code for unknown language")
    func unknownLanguage() {
        #expect(WhisperLanguage.displayName(for: "xx") == "xx")
    }

    @Test("All language codes are unique")
    func uniqueLanguageCodes() {
        let codes = WhisperLanguage.supported.map(\.code)
        #expect(codes.count == Set(codes).count)
    }
}
