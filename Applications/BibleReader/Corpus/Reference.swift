// Copyright © 2026 Apple Inc.

import Foundation

/// A pointer into the Bible: a book, a chapter, and optionally a verse or a run of them.
///
/// Always in this edition's own numbering. Nothing here is ever a Hebrew or Protestant
/// reference — those are converted at the boundary by `PsalmNumbering` and by
/// `BookTable`'s aliases, so that by the time a reference exists it is DRB.
struct ScriptureReference: Hashable, Sendable, Codable {
    var bookID: String
    var chapter: Int
    /// `nil` for a whole-chapter reference: `Ps 22`, `sir 3`.
    var verse: Int?
    /// The end of a run: `1 cor 13:4-7`. `nil` for a single verse.
    var lastVerse: Int?

    var chapterKey: ChapterKey { ChapterKey(bookID: bookID, chapter: chapter) }

    /// How the reference is written, given the book's short name.
    func string(bookName: String) -> String {
        guard let verse else { return "\(bookName) \(chapter)" }
        guard let lastVerse, lastVerse != verse else {
            return "\(bookName) \(chapter):\(verse)"
        }
        return "\(bookName) \(chapter):\(verse)-\(lastVerse)"
    }
}

/// A reference plus whatever the reader needs told about it.
///
/// The hint is rendered as a secondary one-line row and **never** as an auto-redirect.
/// Both of the cases that produce one are places where the reader's mental model and
/// this edition genuinely disagree, and silently sending them somewhere else would
/// teach them nothing.
struct ResolvedReference: Equatable, Sendable {
    var reference: ScriptureReference
    var hint: String?
}

/// How a citation is written, and what it admits about itself.
///
/// Mirrors `Citation.string`'s honesty in ShakespeareReader, which marked line numbers
/// "(this edition)" because they were not Folger's. The equivalent admission here is
/// the numbering system: `Genesis 15:6 · Douay-Rheims (Challoner), Vulgate numbering`.
/// A reader who looks up "Psalm 22" in a Protestant Bible and finds the wrong psalm
/// should be able to see from the citation why.
enum Citation {
    static let edition = "Douay-Rheims (Challoner), Vulgate numbering"

    /// The citation for a run of rows in a chapter.
    ///
    /// Reads the verses' *printed* numbers rather than counting, so Psalm 9's second
    /// half cites as `9a:1` — what this edition actually prints — rather than as a
    /// verse number it does not use. A selection that is nothing but notes and headings
    /// has no verse to name, so it cites the chapter.
    static func string(book: Book, chapter: Chapter, first: Int, last: Int) -> String {
        let rows = chapter.rows[first ... min(last, chapter.rows.count - 1)]
        let numbers = rows.compactMap { $0.isVerse ? $0.printedNumber : nil }

        let reference: String
        switch (numbers.first, numbers.last) {
        case (nil, _):
            reference = "\(book.name) \(chapter.number)"
        case (let start?, let end?) where start != end:
            reference = "\(book.name) \(chapter.number):\(start)-\(end)"
        case (let start?, _):
            reference = "\(book.name) \(chapter.number):\(start)"
        }
        return "\(reference) · \(edition)"
    }

    /// The selected rows with the citation appended, which is what makes a quote pasted
    /// into notes traceable.
    ///
    /// Here rather than in `ChapterReaderView` because the two platforms copy through
    /// different mechanisms from different views: macOS hands an `NSItemProvider` to the
    /// responder chain from the reader pane, iOS writes `UIPasteboard` from the reader
    /// toolbar. The *text* is the same either way.
    ///
    /// A verse carries its number, because a Bible quotation without verse numbers is
    /// not much of a quotation. A note is bracketed and marked as Challoner's, so a
    /// passage pasted into notes cannot be mistaken for scripture — which matters far
    /// more here than the equivalent did for a stage direction.
    static func quotation(
        book: Book, chapter: Chapter, range: ClosedRange<Int>
    ) -> String {
        let quoted = chapter.rows[range]
            .map { row -> String in
                switch row.kind {
                case .verse:
                    guard let number = row.printedNumber else { return row.text }
                    return "\(number). \(row.text)"
                case .sectionHeading:
                    return row.text
                case .note:
                    return "[note: \(row.displayText)]"
                }
            }
            .joined(separator: "\n")
        return quoted + "\n\n"
            + string(
                book: book, chapter: chapter, first: range.lowerBound,
                last: range.upperBound)
    }
}

/// Turns what a reader types into a reference.
///
/// `jn 3:16`, `John 3`, `1 cor 13:4-7`, `Gen 1.1`, `Ps 22`, `sir 3`, `rev 21`.
///
/// The front end of the navigator's find field, which is why it returns `nil` freely:
/// anything that is not a reference falls through to a book-name search rather than
/// being an error.
enum ReferenceParser {
    /// `<book> <chapter>[:.]<verse>[-<verse>]`
    ///
    /// The book name is everything up to the first digit that starts a chapter number,
    /// which is what lets `1 cor 13` work: a leading digit is part of the name, a digit
    /// after a space and a letter is the chapter. Matching greedily on the name and
    /// then folding it through `BookTable` is what keeps this from needing to know the
    /// 73 names itself.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(?<book>.*?[A-Za-z.])\s*(?<chapter>\d+)"#
            + #"(?:\s*[:.]\s*(?<verse>\d+)(?:\s*[-–]\s*(?<last>\d+))?)?\s*$"#)

    static func parse(_ query: String, table: BookTable, bible: Bible) -> ResolvedReference? {
        let range = NSRange(query.startIndex ..< query.endIndex, in: query)
        guard let match = pattern.firstMatch(in: query, range: range) else { return nil }

        func group(_ name: String) -> String? {
            let found = match.range(withName: name)
            guard found.location != NSNotFound, let swift = Range(found, in: query)
            else { return nil }
            return String(query[swift])
        }

        guard let bookText = group("book"), let chapterText = group("chapter"),
            let chapter = Int(chapterText),
            let resolution = table.resolve(bookText),
            let book = bible.book(resolution.bookID),
            book.chapter(chapter) != nil
        else { return nil }

        let verse = group("verse").flatMap(Int.init)
        var reference = ScriptureReference(
            bookID: book.id,
            chapter: chapter,
            verse: verse,
            lastVerse: group("last").flatMap(Int.init))

        // A backwards or degenerate range is not an error worth refusing over; it is a
        // typo, and dropping the end is what the reader meant.
        if let last = reference.lastVerse, let verse, last <= verse {
            reference.lastVerse = nil
        }

        return ResolvedReference(
            reference: reference,
            hint: resolution.hint ?? psalmHint(reference))
    }

    /// The other half of the numbering trap: `Ps 23` is a real DRB psalm *and* almost
    /// certainly not the one the reader wants.
    ///
    /// Only fires where the two numbering systems actually disagree, so `Ps 1` and
    /// `Ps 150` — which are the same psalm in both — say nothing.
    private static func psalmHint(_ reference: ScriptureReference) -> String? {
        guard reference.bookID == "psalms",
            let douay = PsalmNumbering.douay(forHebrew: reference.chapter),
            douay != reference.chapter
        else { return nil }
        return "You may mean Psalm \(douay) in this edition, which is Hebrew "
            + "\(reference.chapter)."
    }
}
