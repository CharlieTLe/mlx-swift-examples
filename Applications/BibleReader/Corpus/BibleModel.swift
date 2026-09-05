// Copyright © 2026 Apple Inc.

import Foundation

/// One book, as produced by `tools/build_corpus.py`.
///
/// The JSON is checked in, so nothing here depends on the script having been run.
/// Decoding is strict — a field the parser stopped emitting is a decode failure the
/// self test catches, not a silently empty reader pane.
struct Book: Codable, Sendable, Identifiable {
    let schemaVersion: Int
    /// The JSON filename and the stable identifier in `ReadingProgress` and the
    /// annotation cache, so it must not be renamed casually. `"genesis"`,
    /// `"1-machabees"`.
    let id: String
    /// The short name the chapter headings use: `"Genesis"`, `"1 Kings"`. This is what
    /// a citation prints and what the reference parser resolves to.
    let name: String
    /// The transcription's own heading, title-cased: `"The Book of Genesis"`.
    let title: String
    let testament: Testament
    let division: Division
    /// 1…73, in canonical order.
    let canonicalIndex: Int
    /// The seven books absent from the Protestant canon.
    ///
    /// A book-level flag, so it cannot say "partly": Esther and Daniel are `false`
    /// despite both carrying deuterocanonical sections inline (Esther 10:4–16:24,
    /// Daniel 3:24–90 and 13–14). The flag is what the navigator's dagger annotates,
    /// and those books as a whole are protocanonical.
    let deuterocanonical: Bool
    let genre: Genre
    /// Feeds `ReferenceParser`, not the UI. Ships Protestant and common-English names
    /// as aliases, because nobody types "Paralipomenon".
    let abbreviations: [String]
    /// Challoner's introduction to the book, one string per paragraph.
    let preface: [String]
    let source: Source
    let chapters: [Chapter]

    struct Source: Codable, Sendable {
        let kind: String
        let ebookID: Int
        let url: String
        let retrieved: String
        let textSHA256: String
        let parserVersion: Int
        let note: String
    }

    func chapter(_ number: Int) -> Chapter? {
        chapters.first { $0.number == number }
    }
}

enum Testament: String, Codable, Sendable, Hashable, CaseIterable {
    case old, new

    var name: String {
        switch self {
        case .old: "Old Testament"
        case .new: "New Testament"
        }
    }
}

/// The navigator's nine groups.
///
/// Nine rather than two, because two testament rows expanding to 46 and 27 books is not
/// navigation. The counts are 5 + 16 + 7 + 18 = 46 and 4 + 1 + 14 + 7 + 1 = 27.
enum Division: String, Codable, Sendable, Hashable, CaseIterable {
    case pentateuch, historical, wisdom, prophets
    case gospels, acts, pauline, catholic, apocalypse

    var name: String {
        switch self {
        case .pentateuch: "Pentateuch"
        case .historical: "Historical"
        case .wisdom: "Wisdom"
        case .prophets: "Prophets"
        case .gospels: "Gospels"
        case .acts: "Acts"
        case .pauline: "Pauline Epistles"
        case .catholic: "Catholic Epistles"
        case .apocalypse: "Apocalypse"
        }
    }

    var testament: Testament {
        switch self {
        case .pentateuch, .historical, .wisdom, .prophets: .old
        case .gospels, .acts, .pauline, .catholic, .apocalypse: .new
        }
    }
}

/// What kind of writing a book is, which the reader pane uses for measure and leading.
///
/// `.poetry` is the one that changes anything: those books get a narrower measure,
/// looser leading and a hanging indent, so a verse reads as a stanza rather than a
/// paragraph. That is typography and not invented structure — see `Chapter.rows`.
enum Genre: String, Codable, Sendable, Hashable {
    case narrative, law, poetry, prophecy, epistle
}

struct Chapter: Codable, Sendable, Hashable {
    let number: Int
    /// Psalms only: `"Beati immaculati."` Every psalm has one.
    let latinIncipit: String?
    /// Challoner's summary of the chapter. 1,296 of the 1,334 chapters have one.
    ///
    /// Rendered in the heading where ShakespeareReader put `scene.setting`, and fed to
    /// the prompt. It is deliberately **not** part of `rows`: a Challoner summary must
    /// not be selectable and annotatable as if it were scripture.
    let argument: String?
    let rows: [Row]

    var verseCount: Int { rows.count { $0.kind == .verse } }

    /// The verses of this chapter in reading order, which is what the citation and the
    /// context windows count in.
    var verses: [Row] { rows.filter { $0.kind == .verse } }
}

/// One rendered row: a verse, a section heading, or one of Challoner's notes.
///
/// The exact analogue of ShakespeareReader's `Line`, and keeping it heterogeneous is
/// what lets `VerseSelection`, `RowFrames`, `SweepRecognizer`, `WordHitTest` and
/// `VerseRow` come across nearly untouched. Notes live in `rows` rather than in a
/// sidecar because that is what makes the app a Challoner study Bible rather than a
/// plain text with an AI layer on top.
struct Row: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        /// Left, prose measure. The `.verse` slot.
        case verse
        /// Centred, small caps — `ALEPH.`, `THE PARABLES OF SOLOMON`, `Alleluia.` The
        /// `.sceneDescription` slot.
        case sectionHeading
        /// Indented, smaller, secondary, catchword italic. The `.bracketedDirection`
        /// slot.
        case note
    }

    let kind: Kind
    /// The verse number. `nil` for a heading or a note.
    let number: Int?
    /// The printed label, when it is not just the number.
    ///
    /// Set on exactly 18 rows in the corpus: the second half of Psalm 9, which this
    /// edition prints as `9a:1` through `9a:18` under the rubric `Psalm 10 according to
    /// the Hebrews.` DRB Psalm 9 spans Hebrew Psalms 9 and 10, and this is the one
    /// place the Vulgate numbering becomes visible in the text itself. Kept as printed
    /// rather than renumbered to 9:22–39, so the gutter and the citation both say what
    /// the edition says.
    let label: String?
    let text: String
    /// Notes only, and 17 of the 1,772 have none: the phrase from the verse that the
    /// note is hung on, which Challoner prints before an ellipsis.
    let catchword: String?

    var isVerse: Bool { kind == .verse }

    /// What the gutter prints and what a citation names.
    var printedNumber: String? {
        if let label { return label }
        guard let number else { return nil }
        return String(number)
    }

    /// The string the row actually draws, which for a note is its catchword and its
    /// commentary run together.
    ///
    /// One string rather than two `Text`s, because everything downstream operates on a
    /// single string: `WordHitTest` lays it out, `WordTokenizer` splits it, the copy
    /// command puts it on the pasteboard, and `QuoteCheck` normalizes it. Two views
    /// would mean four of those five things having to know a row can be in halves.
    ///
    /// The separator is a period and a space, which is how Challoner's own text reads
    /// once the ellipsis is taken off: `A firmament.... By this name is here understood`
    /// becomes `A firmament. By this name is here understood`.
    var displayText: String {
        guard kind == .note, let catchword, !catchword.isEmpty else { return text }
        return "\(catchword). \(text)"
    }

    /// The italic runs of `displayText`, as UTF-16 ranges.
    ///
    /// At most one, always the catchword, and only on a note. This transcription has no
    /// `_..._` markup anywhere — the whole 5.9 MB body was checked, not sampled — so the
    /// catchword is the only italic in the app that carries meaning, and it is the only
    /// reason `WordHitTest.Layout.italics` survived the port.
    ///
    /// The trailing period is included in the span. It belongs to the catchword: it is
    /// the mark that closes the quoted phrase, and setting it upright would leave a
    /// visible hitch between the italic and the roman.
    var italicSpans: [Range<Int>] {
        guard kind == .note, let catchword, !catchword.isEmpty else { return [] }
        return [0 ..< (catchword.utf16.count + 1)]
    }
}

/// Addresses one chapter. Selections never cross a chapter boundary because the reader
/// renders one chapter at a time, so this is also the unit the annotation cache is
/// keyed on.
struct ChapterKey: Hashable, Sendable, Codable {
    var bookID: String
    var chapter: Int

    var slug: String { "\(bookID)-c\(chapter)" }
}

/// Addresses one selected passage.
///
/// `first` and `last` are indices into `Chapter.rows`, **not** verse numbers. Indices
/// are always defined — a selection can consist of nothing but notes — and a re-parse
/// that shifts them is caught by the passage digest rather than by the key.
struct PassageKey: Hashable, Sendable, Codable {
    var chapter: ChapterKey
    var first: Int
    var last: Int

    var slug: String { "\(chapter.slug)-\(first)_\(last)" }
}
