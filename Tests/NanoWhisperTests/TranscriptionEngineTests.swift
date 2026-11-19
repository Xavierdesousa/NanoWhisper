import Foundation
import Testing
import FluidAudio
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
        #expect(model.displayName == "Parakeet")
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
        #expect(WhisperModelSize.small.whisperKitModel == "openai_whisper-small")
        #expect(WhisperModelSize.medium.whisperKitModel == "openai_whisper-medium")
        #expect(WhisperModelSize.largev3.whisperKitModel == "openai_whisper-large-v3")
    }

    @Test("Large v3 Turbo maps to OpenAI's v20240930 release in WhisperKit")
    func largeV3TurboIdentifier() {
        let turbo = WhisperModelSize.largev3Turbo
        #expect(turbo.rawValue == "large-v3-turbo")
        #expect(turbo.displayName == "Large v3 Turbo")
        #expect(turbo.whisperKitModel == "openai_whisper-large-v3-v20240930_626MB")
        #expect(turbo.sizeDescription == "~630 MB")
    }

    @Test("Model sizes keep their persisted raw values")
    func modelSizeRawValues() {
        #expect(WhisperModelSize.allCases.map(\.rawValue)
                == ["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"])
    }

    @Test("WhisperKit identifiers are unique")
    func uniqueWhisperKitIdentifiers() {
        let ids = WhisperModelSize.allCases.map(\.whisperKitModel)
        #expect(ids.count == Set(ids).count)
    }

    // MARK: - ParakeetVariant

    @Test("Parakeet variants: display, size and raw values")
    func parakeetVariantProperties() {
        #expect(ParakeetVariant.allCases == [.v3, .ultra])
        #expect(ParakeetVariant.v3.rawValue == "v3")
        #expect(ParakeetVariant.ultra.rawValue == "ultra")
        #expect(ParakeetVariant.v3.displayName == "Parakeet TDT 0.6B v3")
        #expect(ParakeetVariant.ultra.displayName == "Parakeet Ultra")
        for variant in ParakeetVariant.allCases {
            #expect(!variant.sizeDescription.isEmpty)
        }
    }

    @Test("Parakeet variants map to FluidAudio model versions and repos")
    func parakeetVariantIdentifiers() {
        #expect(ParakeetVariant.v3.asrModelVersion == .v3)
        #expect(ParakeetVariant.ultra.asrModelVersion == .ultra)
        #expect(ParakeetVariant.v3.huggingFaceRepo == "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        #expect(ParakeetVariant.ultra.huggingFaceRepo == "FluidInference/parakeet-ultra-coreml")
    }

    @Test("Parakeet variants use separate FluidAudio cache folders")
    func parakeetCacheFolders() {
        let v3 = AsrModels.defaultCacheDirectory(for: ParakeetVariant.v3.asrModelVersion)
        let ultra = AsrModels.defaultCacheDirectory(for: ParakeetVariant.ultra.asrModelVersion)
        #expect(v3.lastPathComponent == "parakeet-tdt-0.6b-v3")
        #expect(ultra.lastPathComponent == "parakeet-ultra")
        // The pre-0.18 folder differs from the current one: that is why legacy adoption exists.
        #expect(v3.lastPathComponent != SetupManager.legacyParakeetV3FolderName)
    }

    // MARK: - Legacy Parakeet v3 cache adoption

    private func makeModelsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Legacy v3 cache is copied to the current folder and kept in place")
    func adoptLegacyCache() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let legacy = models.appendingPathComponent(SetupManager.legacyParakeetV3FolderName)
        let encoder = legacy.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: encoder.appendingPathComponent("weight.bin"))
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")

        #expect(SetupManager.adoptLegacyParakeetV3Cache(currentDirectory: current))
        let copied = current.appendingPathComponent("Encoder.mlmodelc/weight.bin")
        #expect(try Data(contentsOf: copied) == Data("weights".utf8))
        #expect(FileManager.default.fileExists(atPath: encoder.path))
    }

    @Test("Legacy adoption is a no-op when the current cache exists or no legacy cache exists")
    func adoptLegacyCacheNoOp() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")

        #expect(!SetupManager.adoptLegacyParakeetV3Cache(currentDirectory: current))
        #expect(!FileManager.default.fileExists(atPath: current.path))

        let legacy = models.appendingPathComponent(SetupManager.legacyParakeetV3FolderName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(!SetupManager.adoptLegacyParakeetV3Cache(currentDirectory: current))
    }

    @Test("New installs default to Ultra, existing installs stay on v3")
    func parakeetVariantResolution() {
        #expect(ParakeetVariant.resolve(storedValue: nil, isExistingInstall: false) == .ultra)
        #expect(ParakeetVariant.resolve(storedValue: nil, isExistingInstall: true) == .v3)
        #expect(ParakeetVariant.resolve(storedValue: "ultra", isExistingInstall: true) == .ultra)
        #expect(ParakeetVariant.resolve(storedValue: "v3", isExistingInstall: false) == .v3)
        #expect(ParakeetVariant.resolve(storedValue: "bogus", isExistingInstall: false) == .ultra)
        #expect(ParakeetVariant.resolve(storedValue: "bogus", isExistingInstall: true) == .v3)
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
