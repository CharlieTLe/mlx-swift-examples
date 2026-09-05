// Copyright © 2026 Apple Inc.

import Foundation

/// A cross-reference: where it points, and why it is being offered.
struct CrossReference: Sendable, Hashable {
    var reference: ScriptureReference
    /// How the reference is written, in this edition's book names.
    var label: String
    /// The target verse's own words, truncated. **This is the point of the whole
    /// structure**: the model is handed the text, so explaining the connection is a
    /// reading task rather than a recall task.
    var text: String
    /// Where it came from, which the pane shows and the diagnostics count.
    var source: Source

    enum Source: String, Sendable, Hashable {
        /// Harvested from Challoner's own notes on the selected verses.
        case challoner
        /// From the bundled dataset. Phase 4.
        case dataset
    }
}

/// Where cross-references come from — and, just as importantly, where they do not.
///
/// **Not the model.** `ReferenceCheck` can remove a citation to a verse that does not
/// exist, but it cannot tell you that a real verse is irrelevant, and 4B models produce
/// plausible-and-wrong scriptural links at a high rate. So the model is never asked for
/// a cross-reference; it is handed a short list, with the target text, and asked to
/// explain those and no others.
///
/// Two tiers, and only the first is implemented:
///
/// **Tier 1 — Challoner's own references.** Roughly a hundred explicit `Gen. 2.24` and
/// `Matt. 19` forms across the notes, plus intra-book `chap. 5.3`. Small, but Catholic,
/// verse-anchored, zero licensing risk, available today — and the only source that
/// touches the deuterocanon at all.
///
/// **Tier 2 — a bundled dataset.** The Treasury of Scripture Knowledge, imported by
/// `tools/build_crossrefs.py`. Not in this phase, and gated on a licence question that
/// has to be answered before the importer is written rather than after: the 1830s work
/// is unambiguously public domain, a particular digitization of it may not be.
struct CrossReferenceStore: Sendable {
    private let bible: Bible
    private let table: BookTable

    init(bible: Bible, table: BookTable) {
        self.bible = bible
        self.table = table
    }

    /// At most `limit` references for a passage, resolved and carrying their target text.
    ///
    /// Capped, and the cap is a latency decision rather than a taste one: each entry
    /// costs a label plus up to `wordLimit` words of quoted verse, and the prompt is
    /// already carrying a book preface, a chapter argument and the notes. Five is what
    /// keeps `CROSS-REFERENCES` under about 150 tokens.
    static let limit = 5
    /// How much of a target verse is quoted. Enough to see what the connection is,
    /// short enough that five of them are not a second passage.
    static let wordLimit = 25

    func references(for rows: ArraySlice<Row>, in book: Book, chapter: Int)
        -> [CrossReference]
    {
        var seen: Set<ScriptureReference> = []
        var found: [CrossReference] = []

        for row in rows where row.kind == .note {
            for reference in Self.harvest(row.text, in: book, chapter: chapter, table: table) {
                guard !seen.contains(reference), found.count < Self.limit else { continue }
                guard let target = bible.book(reference.bookID),
                    let text = bible.verseText(reference)
                else { continue }
                seen.insert(reference)
                found.append(
                    CrossReference(
                        reference: reference,
                        label: reference.string(bookName: target.name),
                        text: Self.truncate(text),
                        source: .challoner))
            }
        }
        return found
    }

    /// `Gen. 2.24`, `Matt. 19`, `chap. 5.3`, `ver. 16`.
    ///
    /// Four shapes, and the last two are the reason this is not just `ReferenceParser`
    /// run over the note. Challoner writes an intra-book reference as `chap. 5.3` with no
    /// book name at all, and an intra-chapter one as `ver. 16`; both are extremely common
    /// in the notes and both are meaningless without knowing where they were read. That
    /// context is exactly what this function has and a general parser does not.
    ///
    /// The separator is a period rather than a colon, which is Challoner's convention
    /// throughout and the opposite of what a modern reader types — hence a pattern of its
    /// own rather than a second entry point into `ReferenceParser`.
    static func harvest(
        _ note: String, in book: Book, chapter: Int, table: BookTable
    ) -> [ScriptureReference] {
        scan(note, in: book, chapter: chapter, table: table).map(\.reference)
    }

    /// One reference found in a note, and the span of the note it was written in.
    ///
    /// The ranged half of `harvest`, for `ReferenceLinks.note` — which needs to know not
    /// merely *that* a note names Genesis 2:24 but *where*, so it can link those eleven
    /// characters and leave the rest of Challoner's sentence alone.
    ///
    /// **UTF-16 offsets and not `String.Index`**, for `Row.italicSpans`' reason: a note's
    /// `displayText` is computed, so it hands out a different `String` instance every
    /// time it is asked, and these spans are held in `VerseRow`'s `@State` across renders.
    /// Offsets survive that; indices into a string that no longer exists are a bet.
    struct Hit: Hashable, Sendable {
        var reference: ScriptureReference
        var range: Range<Int>
    }

    /// Every reference in a note, in the order `harvest` has always returned them: all
    /// the named forms, then the intra-book ones, then the intra-chapter ones.
    ///
    /// **The three passes overlap**, and deliberately so. `chap. 8. ver. 31` is matched
    /// whole by the intra-book pass and again, inside it, by the intra-chapter one — the
    /// second is wrong here and right in `as at ver. 16`, and only the span says which.
    /// Resolving that is the caller's, because the two callers want opposite things: the
    /// prompt wants every candidate reference, a link wants one span per stretch of text.
    static func scan(
        _ note: String, in book: Book, chapter: Int, table: BookTable
    ) -> [Hit] {
        let whole = NSRange(note.startIndex ..< note.endIndex, in: note)
        var found: [Hit] = []

        for match in named.matches(in: note, range: whole) {
            guard let name = group("book", match, note),
                let chapterText = group("chapter", match, note),
                let number = Int(chapterText),
                let resolution = table.resolve(name)
            else { continue }
            found.append(
                Hit(
                    reference: ScriptureReference(
                        bookID: resolution.bookID,
                        chapter: number,
                        verse: group("verse", match, note).flatMap(Int.init)),
                    range: utf16Span(match.range)))
        }

        for match in intraBook.matches(in: note, range: whole) {
            guard let chapterText = group("chapter", match, note),
                let number = Int(chapterText)
            else { continue }
            found.append(
                Hit(
                    reference: ScriptureReference(
                        bookID: book.id,
                        chapter: number,
                        verse: group("verse", match, note).flatMap(Int.init)),
                    range: utf16Span(match.range)))
        }

        for match in intraChapter.matches(in: note, range: whole) {
            guard let verseText = group("verse", match, note),
                let verse = Int(verseText)
            else { continue }
            found.append(
                Hit(
                    reference: ScriptureReference(
                        bookID: book.id, chapter: chapter, verse: verse),
                    range: utf16Span(match.range)))
        }

        return found
    }

    /// `Gen. 2.24`, `1 Cor. 13`, `Matt. 19.5`. The book name is a short run of letters
    /// with an optional leading numeral, which is how Challoner abbreviates throughout;
    /// `BookTable.resolve` is what decides whether the run is a real book, so a false
    /// positive here costs nothing.
    private static let named = try! NSRegularExpression(
        pattern: #"\b(?<book>[1-4]? ?[A-Z][a-z]{1,14}\.?)\s*(?<chapter>\d{1,3})"#
            + #"(?:\s*\.\s*(?<verse>\d{1,3}))?"#)

    /// `chap. 5.3` and `chap. 8. ver. 31` are both Challoner's, and the second is the
    /// commoner of the two: he writes the verse out as `ver. N` about as often as he
    /// abbreviates it to a second number. Accepting only the first form resolved those to
    /// a whole chapter, which is a reference to the right place and the wrong size.
    private static let intraBook = try! NSRegularExpression(
        pattern: #"\bchap\.\s*(?<chapter>\d{1,3})"#
            + #"(?:\s*\.?\s*(?:ver\.\s*)?(?<verse>\d{1,3}))?"#,
        options: .caseInsensitive)

    private static let intraChapter = try! NSRegularExpression(
        pattern: #"\bver\.\s*(?<verse>\d{1,3})"#, options: .caseInsensitive)

    private static func group(
        _ name: String, _ match: NSTextCheckingResult, _ text: String
    ) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let swift = Range(range, in: text)
        else { return nil }
        return String(text[swift])
    }

    /// An `NSRange` is already UTF-16, which is the whole reason `Hit.range` is.
    private static func utf16Span(_ range: NSRange) -> Range<Int> {
        range.location ..< (range.location + range.length)
    }

    private static func truncate(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > wordLimit else { return text }
        return words.prefix(wordLimit).joined(separator: " ") + "…"
    }
}
