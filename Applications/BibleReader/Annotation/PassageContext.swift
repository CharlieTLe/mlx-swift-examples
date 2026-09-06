// Copyright © 2026 Apple Inc.

import CryptoKit
import Foundation

/// Everything the model is told about a passage, assembled deterministically from the
/// edition's own structure.
///
/// No embeddings: the book / chapter / verse hierarchy is a better index than a vector
/// store here, and it is exact.
///
/// **The whole of this is authored text.** ShakespeareReader had to infer the things it
/// put in the prompt — who was on stage, what a scene was about — and the one inferred
/// field it had, `onStage`, is labelled as approximate all the way through. This app
/// gets to quote instead. The book preface, the chapter argument and the notes are
/// Challoner's own words, already in the corpus; the cross-references are harvested from
/// those notes and resolved against this same Bible. Nothing here is a guess, which is
/// what turns three of the four annotation layers from recall tasks into
/// explain-what-you-were-handed tasks.
struct PassageContext: Sendable, Hashable {

    /// One row as the prompt will render it.
    struct Verse: Sendable, Hashable {
        var number: String?
        var text: String
        var kind: Row.Kind
    }

    /// A Challoner note bearing on the selected verses.
    struct Note: Sendable, Hashable {
        /// The phrase from the verse the note is hung on. `nil` on the 17 that have none.
        var catchword: String?
        var text: String
    }

    var bookName: String
    var bookTitle: String
    var testament: Testament
    var division: Division
    var genre: Genre
    var deuterocanonical: Bool
    /// Challoner's introduction to the book, truncated to about two sentences.
    ///
    /// Truncated rather than quoted whole, and this is one of the three latency
    /// mitigations: Genesis' preface alone is 120 words, and the prompt is already
    /// carrying an argument, the notes and the cross-reference texts. Two sentences is
    /// what a reader needs to know where they are.
    var bookPreface: String?
    var chapter: Int
    /// Challoner's summary of the chapter. **The single best thing this edition gives the
    /// app**: a per-chapter synopsis that costs no model work at all, where
    /// ShakespeareReader had to generate one in the background and stream it in partial.
    var chapterArgument: String?
    var chapterVerseCount: Int
    /// The section heading in force over the selection, if any: `ALEPH.`, `THE PARABLES
    /// OF SOLOMON`, `Psalm 10 according to the Hebrews.`
    var sectionHeading: String?
    /// The notes attached to the selected verses, verbatim.
    ///
    /// The authority where they apply, and the prompt says so. These are the mitigation
    /// for the one thing a 4B model reliably gets wrong about a Catholic Bible — holding
    /// the Catholic reading on a contested verse — because Challoner wrote a note on very
    /// nearly all of those verses and was polemically explicit in it.
    var notes: [Note]
    /// Pre-resolved, each carrying its target verse's own words.
    var crossReferences: [CrossReference]
    var preceding: [Verse]
    var selected: [Verse]
    var following: [Verse]
    var citation: String
    var key: PassageKey
    /// SHA-256 of the selected verse text. This is what stops a re-parsed corpus with
    /// shifted row indices from serving an annotation of different verses — the one
    /// failure mode that would otherwise be invisible.
    var digest: String

    /// Six verses back and two forward.
    ///
    /// Not ShakespeareReader's 15 and 4, and the difference is a token budget rather than
    /// a change of mind. A line of Shakespeare is about ten words; a Douay-Rheims verse
    /// is about thirty. Six verses therefore costs roughly what fifteen lines cost there,
    /// and the windows come out the same size in the only unit that matters.
    static let precedingLimit = 6
    static let followingLimit = 2

    static func build(
        book: Book,
        key: ChapterKey,
        chapter: Chapter,
        rows: [Row],
        selection: VerseSelection,
        crossReferences: CrossReferenceStore?
    ) -> PassageContext? {
        guard let clamped = selection.clamped(to: rows) else { return nil }
        let range = clamped.range

        let precedingStart = precedingWindowStart(range.lowerBound, in: rows)
        let preceding = verses(rows[precedingStart ..< range.lowerBound])
        let selected = verses(rows[range])

        // Challoner prints a note *after* the verse it annotates, so a reader who selects
        // one verse selects a range that stops just short of its own note. Taking only
        // the notes inside the range therefore dropped the note on every single-verse
        // selection — which is the commonest selection there is, and the one the whole
        // `NOTES FROM THIS EDITION` block exists for.
        //
        // So the note window runs past the selection to the end of the contiguous run of
        // notes that follows it. Only notes: a section heading after the selection opens
        // the *next* section and does not belong to this passage.
        let attached = attachedNoteEnd(range.upperBound, in: rows)

        // Half-open, and starting after the attached notes rather than after the
        // selection, so a note is not shown twice — once as authority and once as
        // context, which would read as two different notes.
        let followingStart = attached + 1
        let followingEnd = min(rows.count, followingStart + followingLimit)
        let following =
            followingStart < followingEnd
            ? verses(rows[followingStart ..< followingEnd]) : []

        // The citation is read off the **rendered** chapter, not `chapter`, for the same
        // reason `ChapterReaderView.quotation()` is: `range` indexes `rows`, and with
        // Challoner's notes hidden those two arrays disagree by one per note above the
        // selection. Citing against `chapter.rows` therefore named a verse that many
        // earlier than the one highlighted — Romans 4:9, which has three notes above it,
        // cited as `Romans 4:6` — which is the worst possible place to be off by three,
        // since the citation is the app's claim about *which verse this is*.
        let rendered = Chapter(
            number: chapter.number, latinIncipit: chapter.latinIncipit,
            argument: chapter.argument, rows: rows)

        return PassageContext(
            bookName: book.name,
            bookTitle: book.title,
            testament: book.testament,
            division: book.division,
            genre: book.genre,
            deuterocanonical: book.deuterocanonical,
            bookPreface: preface(book),
            chapter: key.chapter,
            chapterArgument: chapter.argument,
            chapterVerseCount: chapter.verseCount,
            sectionHeading: sectionHeading(above: range.lowerBound, in: rows),
            notes: notes(in: rows[range.lowerBound ... attached]),
            crossReferences: crossReferences?
                .references(
                    for: rows[range.lowerBound ... attached], in: book,
                    chapter: key.chapter) ?? [],
            preceding: preceding,
            selected: selected,
            following: following,
            citation: Citation.string(
                book: book, chapter: rendered, first: range.lowerBound,
                last: range.upperBound),
            key: PassageKey(
                chapter: key, first: range.lowerBound, last: range.upperBound),
            digest: digest(of: selected))
    }

    /// True when `other` names the same rows of the same chapter.
    ///
    /// Not `==`: the disk cache is keyed on `key` + `digest` alone
    /// (`AnnotationCache.passage(for:digest:)`), so comparing the whole value would call
    /// a passage "new" for a difference the cache does not record.
    func isSamePassage(as other: PassageContext) -> Bool {
        key == other.key && digest == other.digest
    }

    /// The first two sentences of the book's preface.
    ///
    /// Sentence-counted rather than word-counted, because a preface cut mid-clause reads
    /// as a transcription error and a model handed one will sometimes try to finish it.
    static func preface(_ book: Book) -> String? {
        guard let first = book.preface.first else { return nil }
        var sentences: [String] = []
        var current = ""
        for character in first {
            current.append(character)
            if character == "." || character == "?" || character == "!" {
                sentences.append(current)
                current = ""
                if sentences.count == 2 { break }
            }
        }
        let joined = (sentences.isEmpty ? [current] : sentences)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Start of the preceding window, pulled back to the start of the chapter when the
    /// floor would fall outside it.
    ///
    /// Clamping at zero is all it takes, because the reader renders one chapter at a time
    /// and the array *is* the chapter: a window can no more cross a chapter boundary than
    /// a selection can. That is one of the three things "one chapter, whole" buys.
    private static func precedingWindowStart(_ lowerBound: Int, in rows: [Row]) -> Int {
        max(0, lowerBound - precedingLimit)
    }

    /// The last index of the run of notes hanging off the end of the selection, or
    /// `upperBound` if there is none.
    private static func attachedNoteEnd(_ upperBound: Int, in rows: [Row]) -> Int {
        var end = upperBound
        while end + 1 < rows.count, rows[end + 1].kind == .note { end += 1 }
        return end
    }

    /// The nearest section heading at or above the selection.
    ///
    /// Only Psalm 118's stanza letters, Proverbs' `THE PARABLES OF SOLOMON`, the psalter's
    /// `Alleluia.` rubrics and Psalm 9's `Psalm 10 according to the Hebrews.` ever produce
    /// one — 61 rows in the whole corpus — but where it exists it is the most locating
    /// single fact about where the reader is.
    private static func sectionHeading(above index: Int, in rows: [Row]) -> String? {
        (0 ... min(index, rows.count - 1)).reversed()
            .first { rows[$0].kind == .sectionHeading }
            .map { rows[$0].text }
    }

    private static func notes(in rows: ArraySlice<Row>) -> [Note] {
        rows.filter { $0.kind == .note }
            .map { Note(catchword: $0.catchword, text: $0.text) }
    }

    private static func verses(_ rows: ArraySlice<Row>) -> [Verse] {
        rows.map { Verse(number: $0.printedNumber, text: $0.text, kind: $0.kind) }
    }

    /// Over `text` and not `displayText`, so a note's catchword is outside the digest.
    /// The catchword is derived from the same JSON as the text, so including it would add
    /// nothing a change to the text would not already catch.
    private static func digest(of selected: [Verse]) -> String {
        let joined = selected.map(\.text).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
