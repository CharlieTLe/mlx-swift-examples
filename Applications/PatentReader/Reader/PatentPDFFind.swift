// Copyright © 2026 Apple Inc.

import Foundation
import PDFKit

/// Find in the open patent: a query, every place it occurs in the office's PDF, and which
/// one the reader is on.
///
/// **This is not the library's find field, and the difference is the whole reason it
/// exists.** `LibrarySearch` reads a query as a request about *documents* — a number opens
/// one, a locator jumps, text filters the list — and it never looks at a word of the
/// specification. So the question a patent reader asks most had no answer: *where does this
/// patent say "thermal via"?* A term of art, a defined phrase, the spelling an examiner
/// used — those are all in the body text.
///
/// ## What changed from `DocumentFind`, which this replaces
///
/// A **class**, where that one was a value type with pure mutators. The reason is not
/// preference: a match here is a `PDFSelection`, which is a reference into a live
/// `PDFDocument`, so the state cannot be copied around and cannot be asserted against
/// without a PDF. What was testable there has moved to `PassagePlacement`, whose
/// `index(nearest:in:)` and `stepped(from:by:count:)` are this type's two pieces of
/// arithmetic lifted out verbatim so their assertions survive.
///
/// Everything else is smaller, because PDFKit already does the hard half. `DocumentFind` had
/// to walk every row, compute UTF-16 offsets that addressed a *computed* string, and
/// construct document order itself. `findString` returns document order and returns
/// selections that know where they are.
///
/// **Finding still does not select.** Landing on a hit scrolls to it and lights it up
/// through `PDFView.highlightedSelections`, and never through `setCurrentSelection` —
/// because a selection here scopes the reader's next question. Searching for a word to check
/// a spelling and thereby narrowing the next question to one paragraph is a side effect
/// nobody asked for. That is also why the marks, the find hits and the reader's own
/// selection are three separate mechanisms: none of them can disturb another.
@MainActor
@Observable
final class PatentPDFFind {

    /// Exactly what the reader typed, kept verbatim so the field can be bound to it.
    private(set) var query = ""

    /// Every occurrence, in document order — which is the order `findString` returns.
    private(set) var matches: [PDFSelection] = []

    /// Which match the reader is on, as an index into `matches`.
    private(set) var cursor: Int?

    /// Bumped every time the cursor lands somewhere, so the view knows to scroll.
    ///
    /// A counter and not the match: two hits in the same place would be "no change" and
    /// the second ⌘G would silently not scroll. That is not a corner case — it is a reader
    /// who panned away by hand looking at a highlight they cannot find.
    private(set) var step = 0

    /// The page each match is on, for `PassagePlacement.index(nearest:in:)`.
    private var pages: [Int] = []

    /// The shortest query worth running.
    ///
    /// One character matches a third of the document, which answers no question anybody
    /// has, and two is genuinely the shortest thing a patent reader looks for — a two-digit
    /// reference numeral, `Fi` on the way to `Fig. 3`. Below it the field reports nothing at
    /// all rather than "no matches", because the reader is still typing and a failure they
    /// did not cause is worse than silence.
    static let shortestQuery = 2

    var current: PDFSelection? {
        guard let cursor, matches.indices.contains(cursor) else { return nil }
        return matches[cursor]
    }

    /// Whether the query is long enough to have been run, which is not the same as having
    /// found something.
    var isActive: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.shortestQuery
    }

    /// `3 of 47`, or that nothing matched, or nothing at all while the query is too short
    /// to have been run.
    ///
    /// **The count is the feature, not decoration** — `FindBar` argues this at length. With a
    /// total on screen, ⌘G is a survey of how a term is used across the specification.
    var summary: String? {
        guard isActive else { return nil }
        guard !matches.isEmpty else { return "No matches" }
        return "\((cursor ?? 0) + 1) of \(matches.count)"
    }

    /// What `PDFView.highlightedSelections` is set to: every hit, with the one the reader is
    /// on drawn differently.
    ///
    /// Two colours because "the document contains this word 47 times" and "you are looking
    /// at the third one" are two different facts and the reader needs both at once. The
    /// values are the deleted row reader's, carried over so that find looked the same on
    /// the day one reader replaced the other.
    var highlighted: [PDFSelection] {
        for (offset, match) in matches.enumerated() {
            match.color = offset == cursor ? Self.currentHit : Self.hit
        }
        return matches
    }

    private static let hit = PlatformColor.systemYellow.withAlphaComponent(0.30)
    private static let currentHit = PlatformColor.systemOrange.withAlphaComponent(0.55)

    /// The reader typed.
    ///
    /// `near` is the page they are on, and it is what makes an incremental find behave: the
    /// cursor lands on the first hit at or after it, so ⌘F followed by a word takes the
    /// reader *forward* from where they are rather than throwing them back to page 1.
    func search(_ raw: String, in document: PDFDocument, near page: Int?) {
        query = raw
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= Self.shortestQuery else {
            matches = []
            pages = []
            cursor = nil
            return
        }

        // The same two options everything else in this app searches with. Case-insensitive
        // because a patent is full of capitalised terms of art and nobody types them the
        // same way twice; diacritic-insensitive because the PDF's `é` and the keyboard's
        // need not be the same code points.
        matches = document.findString(
            needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
        pages = matches.map { match in
            match.pages.first.map { document.index(for: $0) } ?? 0
        }
        cursor = matches.isEmpty ? nil : PassagePlacement.index(nearest: page, in: pages)
        step += 1
    }

    /// ⌘G and ⇧⌘G, and Return in the field.
    ///
    /// Wraps in both directions and reports where it landed, so the caller can scroll
    /// there. Wrapping silently is deliberate and is what a find field does: running off the
    /// end of a document is not an error, and the counter going back to `1 of 47` says what
    /// happened.
    @discardableResult
    func advance(by direction: Int) -> PDFSelection? {
        guard
            let next = PassagePlacement.stepped(
                from: cursor, by: direction, count: matches.count)
        else { return nil }
        cursor = next
        step += 1
        return matches[next]
    }

    /// The same query, run again against a different document.
    ///
    /// The query survives a document switch and the matches cannot. Keeping it is the point:
    /// a term of art is exactly the thing a reader carries from one patent to the next, so
    /// ⌘F and then clicking down the library is how they ask which of these patents talk
    /// about beam steering.
    func refind(in document: PDFDocument) {
        guard isActive else { return }
        search(query, in: document, near: nil)
    }

    /// Closing the field. The highlights go with it: a document still lit up for a query
    /// nobody can see is a document that looks wrong.
    func clear() {
        query = ""
        matches = []
        pages = []
        cursor = nil
        step += 1
    }
}
