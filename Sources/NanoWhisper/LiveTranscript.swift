import Foundation

/// Text of a live transcription, rebuilt from the streaming engine's token revisions.
///
/// The engine edits one token sequence: each revision keeps the first `retainedCount`
/// tokens, appends new ones, and declares the first `stableCount` final. The transcript
/// renders the whole sequence as `text`, split into `stableText` (cannot change any more)
/// and `volatileText` (may still be revised). `stableText + volatileText == text` holds in
/// every state, and once `isFinal` the overlay shows `text` and the app pastes that exact
/// string (`finalText`).
struct LiveTranscript: Equatable, Sendable {

    /// One edit published by the streaming engine.
    struct Revision: Equatable, Sendable {
        /// Token count the transcript holds before this edit.
        var previousCount: Int
        /// Leading tokens kept; everything after them is replaced by `pieces`.
        var retainedCount: Int
        /// Leading tokens that are final after this edit. Never decreases.
        var stableCount: Int
        /// Text of the appended tokens; a piece that starts a word begins with a space.
        var pieces: [String]
        /// Last edit of the job: every token is final.
        var isTerminal: Bool
    }

    enum RevisionError: Error, Equatable {
        /// A revision arrived after the terminal one.
        case alreadyFinal
        /// The revision was built on a different token count (a lost or reordered edit).
        case outOfSequence(expected: Int, received: Int)
        /// The counts break the contract (retiring stable tokens, stable prefix shrinking…).
        case invalidCounts
    }

    /// SentencePiece unknown token; never part of the text (as in FluidAudio's own text).
    static let unknownPiece = "<unk>"
    /// SentencePiece word-boundary marker, rendered as a space.
    static let wordBoundary = "\u{2581}"

    private(set) var pieces: [String] = []
    private(set) var stableCount = 0
    private(set) var isFinal = false

    /// Whole transcript, trimmed like a batch transcription.
    private(set) var text = ""
    /// Prefix of `text` that cannot change any more.
    private(set) var stableText = ""
    /// Rest of `text`, still subject to revision.
    private(set) var volatileText = ""

    init() {}

    /// The text to paste: the whole transcript once the engine finalized it, else `nil`.
    var finalText: String? { isFinal ? text : nil }

    var isEmpty: Bool { text.isEmpty }

    /// Apply the engine's next revision.
    /// - Throws: `RevisionError` when the revision does not continue this transcript; the
    ///   transcript is then unchanged.
    mutating func apply(_ revision: Revision) throws {
        guard !isFinal else { throw RevisionError.alreadyFinal }
        guard revision.previousCount == pieces.count else {
            throw RevisionError.outOfSequence(expected: pieces.count, received: revision.previousCount)
        }
        let total = revision.retainedCount + revision.pieces.count
        guard revision.retainedCount >= stableCount,
              revision.retainedCount <= revision.previousCount,
              revision.stableCount >= stableCount,
              revision.stableCount <= total,
              !revision.isTerminal || revision.stableCount == total
        else { throw RevisionError.invalidCounts }

        pieces.removeLast(pieces.count - revision.retainedCount)
        pieces.append(contentsOf: revision.pieces)
        stableCount = revision.stableCount
        isFinal = revision.isTerminal
        render()
    }

    // MARK: - Rendering

    /// Join token pieces the way FluidAudio renders a transcript: `<unk>` dropped, word
    /// boundaries as spaces. Not trimmed.
    static func joined<S: Sequence>(_ pieces: S) -> String where S.Element == String {
        var result = ""
        for piece in pieces where !piece.isEmpty && piece != unknownPiece {
            result += piece
        }
        return result.replacingOccurrences(of: wordBoundary, with: " ")
    }

    /// Recompute `text`, `stableText` and `volatileText` from the pieces.
    private mutating func render() {
        let raw = Self.joined(pieces)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Where the stable pieces end inside `trimmed`, counted in Unicode scalars (the
        // trimming only removes whole scalars), then rounded down to a character boundary.
        let leadingTrim = raw.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
        let stableScalars = Self.joined(pieces.prefix(stableCount)).unicodeScalars.count
        let boundary = min(max(0, stableScalars - leadingTrim), trimmed.unicodeScalars.count)

        var split = trimmed.startIndex
        var scalarsBefore = 0
        while split < trimmed.endIndex {
            let next = trimmed.index(after: split)
            let width = trimmed.unicodeScalars.distance(from: split, to: next)
            guard scalarsBefore + width <= boundary else { break }
            scalarsBefore += width
            split = next
        }

        text = trimmed
        stableText = String(trimmed[..<split])
        volatileText = String(trimmed[split...])
    }
}
