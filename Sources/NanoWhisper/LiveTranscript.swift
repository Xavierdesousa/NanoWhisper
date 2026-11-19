import Foundation

/// Text shown in the overlay during a live transcription.
///
/// While recording, every partial decode of the audio so far replaces the text. Its leading
/// words that the previous decode had too (same word, same position) form `stableText`; the
/// rest is `volatileText`, shown dimmed. When the recording stops, `finalize(_:)` sets the
/// final transcription, which is what the app pastes: the overlay then shows exactly that
/// string. `stableText + volatileText == text` holds in every state.
struct LiveTranscript: Equatable, Sendable {
    /// Whole text: the latest partial decode, or the final transcription.
    private(set) var text = ""
    /// Leading words of `text` confirmed by two consecutive decodes (all of it once final).
    private(set) var stableText = ""
    /// Rest of `text`, still likely to change.
    private(set) var volatileText = ""
    private(set) var isFinal = false
    /// How many partial decodes changed words that were already shown as stable.
    private(set) var stableRevisionCount = 0

    /// Words of the previous partial decode.
    private var previousWords: [Substring] = []
    /// Number of words in `stableText`.
    private var stableWordCount = 0

    init() {}

    /// The final transcription (what is pasted) once set, else `nil`.
    var finalText: String? { isFinal ? text : nil }

    var isEmpty: Bool { text.isEmpty }

    /// Show a new partial decode of all the audio recorded so far.
    mutating func update(partial: String) {
        guard !isFinal else { return }
        let words = Self.wordRanges(in: partial)
        let current = words.map { partial[$0] }

        if !Array(current.prefix(stableWordCount)).elementsEqual(previousStableWords()) {
            stableRevisionCount += 1
        }
        var common = 0
        while common < min(current.count, previousWords.count), current[common] == previousWords[common] {
            common += 1
        }

        let split = common > 0 ? words[common - 1].upperBound : partial.startIndex
        text = partial
        stableText = String(partial[..<split])
        volatileText = String(partial[split...])
        stableWordCount = common
        previousWords = current
    }

    /// Show the final transcription: the exact string that is pasted, all stable.
    mutating func finalize(_ finalText: String) {
        text = finalText
        stableText = finalText
        volatileText = ""
        isFinal = true
        stableWordCount = 0
        previousWords = []
    }

    private func previousStableWords() -> ArraySlice<Substring> {
        previousWords.prefix(stableWordCount)
    }

    /// Ranges of the whitespace-separated words of `text` (punctuation stays attached).
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let wordStart = start {
                    ranges.append(wordStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            ranges.append(wordStart..<text.endIndex)
        }
        return ranges
    }
}
