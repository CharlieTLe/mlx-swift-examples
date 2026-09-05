// Copyright © 2026 Apple Inc.

import Foundation

/// A reference the model produced, and what became of it.
struct CheckedReference: Identifiable, Equatable, Sendable {
    enum Verdict: String, Equatable, Sendable {
        /// The verse exists **and** was in the supplied `CROSS-REFERENCES`. A link.
        case ok
        /// The verse exists but was not supplied, so the *connection* is the model's
        /// invention even though the reference is real. Plain text, no link.
        case ungiven
        /// `Hezekiah 4:2`, `Genesis 51:1`, `Jude 2:3`, `Psalms 151:1`. Struck through.
        case nonexistent
    }

    var id: String { label + note }
    var reference: ScriptureReference
    /// How the model wrote it, normalized to this edition's book name where it resolved.
    var label: String
    /// The model's own "why it connects", or empty.
    var note: String
    var verdict: Verdict
}

/// Checks the model's scripture references against this Bible.
///
/// `QuoteCheck`'s sibling, and the split between them is the split between quoting a
/// verse and naming one. A 4B model asked about scripture invents both, and the two need
/// different answers.
///
/// **This one strips where `QuoteCheck` does not, and the departure is deliberate.**
/// `QuoteCheck` reports and never removes, because a misquoted line is evidence and half
/// of what ShakespeareReader learned came from reading them. That rule is right for a bad
/// quotation. A *nonexistent scripture citation shown as if it were scripture* is a
/// different category: it is the app asserting a false fact about the Bible to a reader
/// who has no way to check it, and "Hezekiah 4:2" looks exactly as authoritative as
/// "Isaias 7:14" in the same typeface. So it is struck through and labelled rather than
/// rendered plain.
///
/// Nothing is deleted. The text stays, the verdict is attached to it, and counts of all
/// three land in the diagnostics strip — so the signal survives and the reader can see
/// that the model tried.
enum ReferenceCheck {

    /// Every reference in `text`, checked against the corpus and against what was
    /// supplied.
    ///
    /// `supplied` is the set the prompt actually handed over. A reference outside it is
    /// `.ungiven` however real the verse is, because the prompt says "explain these and
    /// no others" and a reference the model reached for on its own is a link it invented.
    static func check(
        _ text: String, supplied: [CrossReference], bible: Bible, table: BookTable
    ) -> [CheckedReference] {
        let given = Set(supplied.map(\.reference))
        var seen: Set<String> = []
        var checked: [CheckedReference] = []

        for hit in scan(text) {
            guard seen.insert(hit.label).inserted else { continue }

            guard let resolution = table.resolve(hit.book) else {
                // No such book in this edition. `Hezekiah` is the canonical example, and
                // note that `Revelation` is *not* one: it is an alias of the Apocalypse,
                // so a model using Protestant names resolves rather than being flagged.
                checked.append(
                    CheckedReference(
                        reference: ScriptureReference(
                            bookID: "", chapter: hit.chapter, verse: hit.verse),
                        label: hit.label, note: hit.note, verdict: .nonexistent))
                continue
            }

            let reference = hit.reference(in: resolution.bookID)
            let name = table.name(of: resolution.bookID) ?? hit.book
            let label = reference.string(bookName: name)

            guard bible.rowIndex(of: reference) != nil else {
                // The book is real and the chapter or verse is not: `Genesis 51:1`,
                // `Jude 2:3`, `Psalms 151:1`. This is the common shape of the failure,
                // and it is invisible to any check that only validates book names.
                checked.append(
                    CheckedReference(
                        reference: reference, label: label, note: hit.note,
                        verdict: .nonexistent))
                continue
            }

            // A supplied whole-chapter reference covers a verse inside it: the prompt
            // handed over the chapter, so naming a verse of it is not reaching outside.
            //
            // Tested against a **range-stripped** copy. `lastVerse` is set from the
            // model's own `4-7` now that the link builder needs the end of the run, and
            // nothing in `supplied` ever carries one — so comparing the reference whole
            // would drop every ranged citation out of `SEE ALSO` for a reason that has
            // nothing to do with whether it was given.
            let single = ScriptureReference(
                bookID: reference.bookID, chapter: reference.chapter,
                verse: reference.verse)
            let wasGiven =
                given.contains(single)
                || given.contains(
                    ScriptureReference(bookID: reference.bookID, chapter: reference.chapter))
            checked.append(
                CheckedReference(
                    reference: reference, label: label, note: hit.note,
                    verdict: wasGiven ? .ok : .ungiven))
        }
        return checked
    }

    /// A verse the model quoted the *text* of, checked against the whole Bible.
    ///
    /// The other half of a cross-reference going wrong. `QuoteCheck` compares against the
    /// selected passage alone, which is right for turn 1's own subject and wrong for a
    /// cross-reference: quoting Romans 4:3 while annotating Genesis 15:6 is exactly what
    /// the prompt asked for, and `QuoteCheck` would report it as unsupported.
    ///
    /// So the haystack is the corpus. Same normalization, so the two agree about what
    /// counts as the same words, and this is deliberately the **whole Bible** rather than
    /// the referenced verse: a quotation that is real scripture attached to the wrong
    /// reference is a different and milder error than one that is not scripture at all,
    /// and only the second is worth a reader's attention.
    static func quotedVerse(_ text: String, in corpus: CorpusHaystack) -> [String] {
        QuoteCheck.spans(in: text)
            .filter { $0.split(separator: " ").count >= minimumQuotedWords }
            .filter { !corpus.contains($0) }
    }

    /// Below this a "quotation" is a phrase, and a phrase appears in 35,805 verses by
    /// accident. Five words is where a match starts meaning something.
    private static let minimumQuotedWords = 5

    // MARK: - Scanning

    /// One reference found in prose, and where it sits.
    struct Hit {
        var book: String
        var chapter: Int
        var verse: Int?
        /// The end of a run: the `25` of `Matthew 7:24-25`. `nil` for a single verse.
        var lastVerse: Int?
        var label: String
        var note: String
        /// **The reference itself and nothing else** — book through verse range, stopping
        /// before the dash that opens a `SEE ALSO` note. `note` greedily eats to the end
        /// of the line, and linking that would turn half a sentence blue.
        var range: Range<String.Index>

        /// The reference this hit names, once its book has been resolved.
        func reference(in bookID: String) -> ScriptureReference {
            ScriptureReference(
                bookID: bookID, chapter: chapter, verse: verse, lastVerse: lastVerse)
        }
    }

    /// `Genesis 15:6`, `1 Cor 13:4-7`, `Rom. 4:3 — because…`, `John 3`.
    ///
    /// The book name is a word or two of letters with an optional leading numeral, and
    /// resolution decides whether it is a book — so `chapter 15` and `verse 6` cannot
    /// match, because neither `chapter` nor `verse` is in the alias table.
    ///
    /// `note` is everything after an em dash, en dash or hyphen on the same line, which is
    /// the shape `SEE ALSO` asks for. Empty for a reference in running prose.
    /// The leading-numeral group is all-or-nothing — `(?:(?:[1-4]|…)\s)?` and not
    /// `(?:[1-4]|…)?\s?` — because the looser form matched an empty numeral followed by
    /// a real space and pulled that space into `book`. Two mentions of the same verse
    /// then carried the labels `Romans 4:3` and ` Romans 4:3`, which are different
    /// strings, so the deduplication silently stopped working.
    ///
    /// `last` used to be an unnamed throwaway, so `Matthew 7:24-25` resolved to verse 24
    /// alone and following it selected one verse of a two-verse citation. The separator
    /// is `[-–]` to match `ReferenceParser`'s, since a model writes both.
    ///
    /// `reference` wraps everything a link may cover. It is a group rather than
    /// `match.range` because the latter includes the note, and a `SEE ALSO` line's note
    /// is a sentence.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<reference>"#
            + #"(?<book>(?:(?:[1-4]|I{1,3}|IV)\s?)?[A-Z][A-Za-z]{1,14}\.?"#
            + #"(?:\s+of\s+[A-Z][A-Za-z]{1,14})?)"#
            + #"\s+(?<chapter>\d{1,3})(?::(?<verse>\d{1,3}))?"#
            + #"(?:\s*[-–]\s*(?<last>\d{1,3}))?"#
            + #")"#
            + #"(?:\s*[—–-]\s*(?<note>[^\n]*))?"#)

    /// Every reference in `text`, with its source range. Shared with `ReferenceLinks`,
    /// which needs the same spans in order to link them where they stand.
    static func scan(_ text: String) -> [Hit] {
        let whole = NSRange(text.startIndex ..< text.endIndex, in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            guard let book = group("book", match, text),
                let chapterText = group("chapter", match, text),
                let chapter = Int(chapterText),
                let span = range("reference", match, text)
            else { return nil }
            let verse = group("verse", match, text).flatMap(Int.init)
            // A backwards or degenerate range is a typo rather than an error worth
            // refusing over, exactly as it is in `ReferenceParser`: keep the start and
            // drop the end. A range with no start at all — `John 3-4` — is a run of
            // chapters, which nothing downstream can select, so it drops too.
            let end = group("last", match, text).flatMap(Int.init)
            let lastVerse = end.flatMap { $0 > (verse ?? $0) ? $0 : nil }
            let written = verse.map { "\(book) \(chapter):\($0)" } ?? "\(book) \(chapter)"
            return Hit(
                book: book.trimmingCharacters(in: .whitespaces),
                chapter: chapter,
                verse: verse,
                lastVerse: lastVerse,
                label: written,
                note: group("note", match, text)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                range: span)
        }
    }

    private static func group(
        _ name: String, _ match: NSTextCheckingResult, _ text: String
    ) -> String? {
        range(name, match, text).map { String(text[$0]) }
    }

    private static func range(
        _ name: String, _ match: NSTextCheckingResult, _ text: String
    ) -> Range<String.Index>? {
        let found = match.range(withName: name)
        guard found.location != NSNotFound else { return nil }
        return Range(found, in: text)
    }
}

/// The whole corpus as one normalized string, for `ReferenceCheck.quotedVerse`.
///
/// A value that is expensive to build and cheap to hold: about 4 MB, and roughly a
/// tenth of a second of `lowercased()` and whitespace folding over 35,805 verses.
/// Rebuilding it per annotation would be a visible stall on a path that is supposed to
/// be free, so whoever needs it builds one and keeps it — `AnnotationService` does.
///
/// Not a cache inside `ReferenceCheck`, deliberately. A `static var` would need
/// synchronization the deployment target cannot express cheaply (`Mutex` is macOS 15),
/// and an actor would make a pure string comparison `async`. An explicitly owned value
/// is simpler than either and says who pays for it.
struct CorpusHaystack: Sendable {
    private let text: String

    init(_ bible: Bible) {
        text = Self.fold(
            bible.books
                .flatMap(\.chapters)
                .flatMap(\.rows)
                .filter(\.isVerse)
                .map(\.text)
                .joined(separator: " "))
    }

    func contains(_ span: String) -> Bool {
        text.contains(Self.fold(span))
    }

    /// `QuoteCheck.normalized`, **plus punctuation**, and the difference is the whole
    /// reason this is not just that function.
    ///
    /// `QuoteCheck` keeps punctuation on purpose: it asks "is this exactly what the
    /// passage says", and a moved comma is a mild misquotation worth reporting. This
    /// asks a different and much blunter question — "is this scripture at all" — and it
    /// answers it in red. Punctuation is the wrong thing to fail that on.
    ///
    /// The case that forced it is real and is the app's own canonical example. Genesis
    /// 15:6 reads `Abram believed God, and it was reputed to him unto justice.` and
    /// Romans 4:3 quotes it back as `Abraham believed God: and it was reputed to him
    /// unto justice.` — a comma against a colon, in the very pair of verses the
    /// cross-reference layer exists to connect. A model reproducing one verse's
    /// punctuation for the other has not fabricated anything, and telling a reader that
    /// what they are looking at is "not in this Bible at all" would be false.
    private static func fold(_ text: String) -> String {
        QuoteCheck.normalized(text)
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "\u{27}" }
    }
}
