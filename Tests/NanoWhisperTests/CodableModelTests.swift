import Foundation
import Testing
@testable import NanoWhisper

@Suite("Codable Models")
struct CodableModelTests {

    // MARK: - HistoryEntry

    @Test("HistoryEntry roundtrip without debugInfo")
    func historyEntryBasic() throws {
        let entry = HistoryEntry(text: "Hello world")

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.id == entry.id)
        #expect(decoded.text == "Hello world")
        #expect(decoded.debugInfo == nil)
    }

    @Test("HistoryEntry roundtrip with debugInfo")
    func historyEntryWithDebug() throws {
        let debug = TranscriptionDebugInfo(audioDuration: 5.2, transcribeDuration: 1.1, rtf: 0.21)
        let entry = HistoryEntry(text: "Test transcription", debugInfo: debug)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.text == "Test transcription")
        #expect(decoded.debugInfo?.audioDuration == 5.2)
        #expect(decoded.debugInfo?.transcribeDuration == 1.1)
        #expect(decoded.debugInfo?.rtf == 0.21)
    }

    // MARK: - TranscriptionDebugInfo

    @Test("TranscriptionDebugInfo uses snake_case CodingKeys")
    func debugInfoSnakeCase() throws {
        let debug = TranscriptionDebugInfo(audioDuration: 3.0, transcribeDuration: 0.5, rtf: 0.17)
        let data = try JSONEncoder().encode(debug)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("audio_duration"))
        #expect(json.contains("transcribe_duration"))
        #expect(json.contains("rtf"))
        #expect(!json.contains("audioDuration"))
    }

    @Test("TranscriptionDebugInfo with nil optionals")
    func debugInfoNils() throws {
        let debug = TranscriptionDebugInfo(audioDuration: nil, transcribeDuration: nil, rtf: nil)

        let data = try JSONEncoder().encode(debug)
        let decoded = try JSONDecoder().decode(TranscriptionDebugInfo.self, from: data)

        #expect(decoded.audioDuration == nil)
        #expect(decoded.transcribeDuration == nil)
        #expect(decoded.rtf == nil)
    }

    // MARK: - Parakeet variant persistence / migration

    /// Fresh, isolated UserDefaults suite for each test.
    private func makeDefaults() -> UserDefaults {
        let suite = "NanoWhisperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("New install (empty defaults) gets Ultra and persists it")
    func migrationNewInstall() {
        let defaults = makeDefaults()
        #expect(ParakeetVariant.loadOrMigrate(from: defaults) == .ultra)
        #expect(defaults.string(forKey: ParakeetVariant.defaultsKey) == "ultra")
    }

    @Test("New install that quits mid-onboarding stays on Ultra at next launch")
    func migrationNewInstallRelaunch() {
        let defaults = makeDefaults()
        _ = ParakeetVariant.loadOrMigrate(from: defaults)
        defaults.set("parakeet", forKey: "selectedModelType")
        #expect(ParakeetVariant.loadOrMigrate(from: defaults) == .ultra)
    }

    @Test("Existing installs (any pre-existing setting) stay on v3", arguments: [
        "onboardingComplete", "selectedModelType", "whisperSettings",
    ])
    func migrationExistingInstall(markerKey: String) {
        let defaults = makeDefaults()
        switch markerKey {
        case "onboardingComplete": defaults.set(true, forKey: markerKey)
        case "selectedModelType": defaults.set("parakeet", forKey: markerKey)
        default: defaults.set(Data("{}".utf8), forKey: markerKey)
        }
        #expect(ParakeetVariant.loadOrMigrate(from: defaults) == .v3)
        #expect(defaults.string(forKey: ParakeetVariant.defaultsKey) == "v3")
    }

    @Test("An explicit choice is kept across launches")
    func migrationKeepsExplicitChoice() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set("ultra", forKey: ParakeetVariant.defaultsKey)
        #expect(ParakeetVariant.loadOrMigrate(from: defaults) == .ultra)
    }

    @Test("ParakeetVariant Codable roundtrip")
    func parakeetVariantCodable() throws {
        for variant in ParakeetVariant.allCases {
            let data = try JSONEncoder().encode(variant)
            #expect(try JSONDecoder().decode(ParakeetVariant.self, from: data) == variant)
        }
    }

    @Test("WhisperSettings with Large v3 Turbo roundtrips; legacy large-v3 still decodes")
    func whisperSettingsTurboCodable() throws {
        var settings = WhisperSettings()
        settings.modelSize = .largev3Turbo
        let data = try JSONEncoder().encode(settings)
        #expect(String(data: data, encoding: .utf8)!.contains("large-v3-turbo"))
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data) == settings)

        let legacy = Data(#"{"modelSize":"large-v3","promptText":""}"#.utf8)
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: legacy).modelSize == .largev3)
    }
}
