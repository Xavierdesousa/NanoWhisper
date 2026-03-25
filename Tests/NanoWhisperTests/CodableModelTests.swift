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
}
