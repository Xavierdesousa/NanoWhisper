import Foundation
import os
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
        #expect(model.subtitle.contains("NVIDIA"))
        #expect(model.subtitle.contains("25 European languages"))
        #expect(!model.subtitle.contains("English only"))
    }

    // MARK: - ModelComparisonView

    @Test("Comparison view covers every variant and size without invented percentages")
    @MainActor func comparisonViewContent() {
        var views = ParakeetVariant.allCases.map {
            ModelComparisonView(modelType: .parakeet, parakeetVariant: $0)
        }
        views += WhisperModelSize.allCases.map {
            ModelComparisonView(modelType: .whisper, whisperModelSize: $0)
        }
        for view in views {
            #expect(!view.bulletPoints.isEmpty)
            #expect(!view.bulletPoints.joined().contains("English-optimized"))
            #expect(!view.bulletPoints.joined().contains("Near-perfect"))
        }
    }

    @Test("Ultra ranks above v3 on accuracy and matches it on speed")
    @MainActor func comparisonParakeetTiers() {
        let v3 = ModelComparisonView(modelType: .parakeet, parakeetVariant: .v3)
        let ultra = ModelComparisonView(modelType: .parakeet, parakeetVariant: .ultra)
        #expect(ultra.accuracy.rawValue > v3.accuracy.rawValue)
        #expect(ultra.speed == v3.speed)
    }

    @Test("Whisper tiers: Turbo is faster than Large v3, accuracy grows with size")
    @MainActor func comparisonWhisperTiers() {
        func view(_ size: WhisperModelSize) -> ModelComparisonView {
            ModelComparisonView(modelType: .whisper, whisperModelSize: size)
        }
        #expect(view(.largev3Turbo).speed.rawValue > view(.largev3).speed.rawValue)
        let ordered: [WhisperModelSize] = [.tiny, .base, .small, .largev3Turbo, .largev3]
        let accuracies = ordered.map { view($0).accuracy.rawValue }
        #expect(accuracies == accuracies.sorted())
    }

    @Test("Comparison values for each engine and model the Engine section offers")
    func comparisonValuesPerModel() {
        func values(_ model: ModelComparison) -> (MetricTier, MetricTier, Int) {
            (model.speed, model.accuracy, model.bulletPoints.count)
        }
        let ultra = values(ModelComparison(modelType: .parakeet, parakeetVariant: .ultra))
        #expect(ultra == (.highest, .highest, 4))
        let v3 = values(ModelComparison(modelType: .parakeet, parakeetVariant: .v3))
        #expect(v3 == (.highest, .high, 3))
        #expect(values(ModelComparison(modelType: .whisper, whisperModelSize: .base)) == (.high, .low, 3))
        #expect(values(ModelComparison(modelType: .whisper, whisperModelSize: .small)) == (.medium, .medium, 3))
        #expect(values(ModelComparison(modelType: .whisper, whisperModelSize: .largev3Turbo)) == (.medium, .high, 3))
        // The view shows the same values as the model it is given.
        let view = ModelComparisonView(modelType: .whisper, parakeetVariant: .ultra, whisperModelSize: .small)
        #expect(view.speed == .medium && view.accuracy == .medium)
        #expect(view.comparison == ModelComparison(modelType: .whisper, whisperModelSize: .small))
    }

    @Test("Comparison identity ignores the other engine's choice; every offered model is reserved once")
    func comparisonOffered() {
        // Whisper's size does not change Parakeet's comparison (no cross-fade for nothing).
        #expect(ModelComparison(modelType: .parakeet, parakeetVariant: .ultra, whisperModelSize: .base)
            == ModelComparison(modelType: .parakeet, parakeetVariant: .ultra, whisperModelSize: .small))
        #expect(ModelComparison(modelType: .parakeet, parakeetVariant: .ultra)
            != ModelComparison(modelType: .whisper, whisperModelSize: .base))
        let current = ModelComparison(modelType: .parakeet, parakeetVariant: .ultra, whisperModelSize: .small)
        let offered = ModelComparison.offered(including: current)
        #expect(offered.count == ParakeetVariant.allCases.count + WhisperModelSize.selectable.count)
        #expect(Set(offered).count == offered.count)
        // A stored size no longer offered is added, so its text is laid out too.
        let obsolete = ModelComparison(modelType: .whisper, whisperModelSize: .medium)
        #expect(ModelComparison.offered(including: obsolete).last == obsolete)
        // The tallest text (the reserved height) is one of the offered models': Ultra, 4 points.
        #expect(offered.map(\.bulletPoints.count).max() == 4)
    }

    // MARK: - Whisper vocabulary hint

    @Test("Prompt tokens: leading space, special tokens dropped")
    func promptTokenEncoding() {
        var encodedInput: String?
        let tokens = WhisperEngine.promptTokens(
            for: "  NanoWhisper CoreML \n",
            encode: { text in
                encodedInput = text
                return [50258, 11, 22, 50359, 33]
            },
            specialTokenBegin: 50257
        )
        #expect(encodedInput == " NanoWhisper CoreML")
        #expect(tokens == [11, 22, 33])
    }

    @Test("Prompt tokens: blank or all-special hints are ignored")
    func promptTokenEmpty() {
        let encode: (String) -> [Int] = { _ in [50258] }
        #expect(WhisperEngine.promptTokens(for: "", encode: encode, specialTokenBegin: 50257) == nil)
        #expect(WhisperEngine.promptTokens(for: "   ", encode: encode, specialTokenBegin: 50257) == nil)
        #expect(WhisperEngine.promptTokens(for: "word", encode: encode, specialTokenBegin: 50257) == nil)
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
        #expect(WhisperModelSize.largev3.whisperKitModel == "openai_whisper-large-v3")
    }

    @Test("Offered sizes: Base, Small, Large v3 Turbo; obsolete ones decode and name a replacement")
    func whisperLineup() throws {
        #expect(WhisperModelSize.selectable == [.base, .small, .largev3Turbo])
        #expect(WhisperModelSize.tiny.replacement == .base)
        #expect(WhisperModelSize.medium.replacement == .largev3Turbo)
        #expect(WhisperModelSize.largev3.replacement == .largev3Turbo)
        for size in WhisperModelSize.allCases {
            // A replacement is always offered (no chains).
            if let replacement = size.replacement { #expect(replacement.isSelectable) }
            #expect(size.isSelectable == (size.replacement == nil))
        }
        #expect(WhisperModelSize.medium.whisperKitModel == "openai_whisper-medium")
        #expect(try JSONDecoder().decode(WhisperModelSize.self, from: Data(#""medium""#.utf8)) == .medium)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WhisperModelSize.self, from: Data(#""bogus""#.utf8))
        }
    }

    @Test("Exactly one recommended model per engine, offered, and Ultra is the new-install default")
    func recommendedModels() {
        #expect(ParakeetVariant.allCases.filter(\.isRecommended) == [.ultra])
        #expect(ParakeetVariant.newInstallDefault.isRecommended)
        #expect(WhisperModelSize.allCases.filter(\.isRecommended) == [.largev3Turbo])
        #expect(WhisperModelSize.largev3Turbo.isSelectable)
        #expect(ModelLabel.pickerTitle(name: "Parakeet Ultra", size: "~630 MB", isRecommended: true)
                == "Parakeet Ultra (~630 MB) · Recommended")
        #expect(ModelLabel.pickerTitle(name: "Base", size: "~150 MB", isRecommended: false) == "Base (~150 MB)")
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

    // MARK: - Legacy Parakeet v3 cache migration

    private func makeModelsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Legacy folder with one fake model file, as FluidAudio 0.12 laid it out.
    private func makeLegacyCache(in models: URL) throws -> URL {
        let legacy = models.appendingPathComponent(SetupManager.legacyParakeetV3FolderName)
        let encoder = legacy.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: encoder.appendingPathComponent("weight.bin"))
        return legacy
    }

    @Test("Legacy v3 cache is moved: contents at the new path, nothing left at the old one")
    func migrateLegacyCacheMoves() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let legacy = try makeLegacyCache(in: models)
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")

        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .moved)
        let moved = current.appendingPathComponent("Encoder.mlmodelc/weight.bin")
        #expect(try Data(contentsOf: moved) == Data("weights".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // Idempotent.
        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .notNeeded)
    }

    @Test("Legacy migration without a legacy folder does nothing")
    func migrateLegacyCacheNotNeeded() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")

        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    /// A load-ready FluidAudio 0.18 v3 layout: every required bundle has `coremldata.bin`.
    private func makeCompleteV3Cache(at current: URL) throws {
        let fm = FileManager.default
        for bundle in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            let dir = current.appendingPathComponent("\(bundle).mlmodelc")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: current.appendingPathComponent("parakeet_vocab.json"))
    }

    @Test("Fake complete layout passes FluidAudio's load-ready check; a .partial file fails it")
    func completenessCheckMatchesFluidAudio() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try makeCompleteV3Cache(at: current)
        #expect(AsrModels.modelsExist(at: current, version: .v3))

        let weights = current.appendingPathComponent("Encoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent("weight.bin.partial"))
        #expect(!AsrModels.modelsExist(at: current, version: .v3))
    }

    @Test("When the new folder is complete, the legacy folder is deleted and the new one kept")
    func migrateLegacyCacheRemovesDuplicate() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let legacy = try makeLegacyCache(in: models)
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try makeCompleteV3Cache(at: current)

        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .removedDuplicate)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(AsrModels.modelsExist(at: current, version: .v3))
        #expect(!FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Encoder.mlmodelc/weight.bin").path))
    }

    @Test("When the new folder is an interrupted download, it is replaced by the legacy cache")
    func migrateLegacyCacheReplacesIncomplete() throws {
        let models = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: models) }
        let legacy = try makeLegacyCache(in: models)
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")
        // Interrupted download: only a partial encoder weight, no coremldata.bin.
        let partialWeights = current.appendingPathComponent("Encoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: partialWeights, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: partialWeights.appendingPathComponent("weight.bin.partial"))
        #expect(!AsrModels.modelsExist(at: current, version: .v3))

        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .replacedIncomplete)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let moved = current.appendingPathComponent("Encoder.mlmodelc/weight.bin")
        #expect(try Data(contentsOf: moved) == Data("weights".utf8))
        #expect(!FileManager.default.fileExists(atPath: partialWeights.appendingPathComponent("weight.bin.partial").path))
    }

    @Test("Two concurrent migrations (production and debug app launching together) keep the moved cache")
    func migrateLegacyCacheConcurrently() throws {
        // Each call opens its own lock file description, so two threads contend exactly like
        // two processes. Repeat to make the unguarded race (one move wins, the other's failure
        // path deleted the winner's folder) show up reliably.
        for _ in 0..<40 {
            let models = try makeModelsDirectory()
            defer { try? FileManager.default.removeItem(at: models) }
            _ = try makeLegacyCache(in: models)
            let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")

            let results = OSAllocatedUnfairLock(initialState: [SetupManager.LegacyCacheMigration]())
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                let result = SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current)
                results.withLock { $0.append(result) }
            }

            let outcomes = results.withLock { $0 }
            #expect(outcomes.filter { $0 == .moved }.count == 1)
            #expect(outcomes.filter { $0 == .notNeeded }.count == 1)
            let moved = current.appendingPathComponent("Encoder.mlmodelc/weight.bin")
            #expect(FileManager.default.fileExists(atPath: moved.path))
        }
    }

    @Test("A failed move does not crash and leaves no folder at the new path")
    func migrateLegacyCacheFailure() throws {
        let models = try makeModelsDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: models.path)
            try? FileManager.default.removeItem(at: models)
        }
        let legacy = try makeLegacyCache(in: models)
        let current = models.appendingPathComponent("parakeet-tdt-0.6b-v3")
        // A read-only models directory makes the rename fail (and the cleanup too).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: models.path)

        #expect(SetupManager.migrateLegacyParakeetV3Cache(currentDirectory: current) == .failed)
        // FluidAudio will see no cache at the new path and download normally.
        #expect(!FileManager.default.fileExists(atPath: current.path))
        // Cleanup of the old folder is best effort; here the directory is read-only.
        #expect(FileManager.default.fileExists(atPath: legacy.path))
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
        settings.modelSize = .small
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
