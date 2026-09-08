// Copyright © 2026 Apple Inc.

import Foundation

/// Find in the open patent: a query, every place it occurs, and which one the reader is on.
///
/// **This is not the library's find field, and the difference is the whole reason it
/// exists.** `LibrarySearch` reads a query as a request about *documents* — a number opens
/// one, a locator jumps, text filters the list — and it never looks at a word of the
/// specification. So the question a patent reader asks most had no answer: *where does this
/// patent say "thermal via"?* A term of art, a defined phrase, the spelling an examiner
/// used — those are all in the body text, and until now the only way to find one was to
/// scroll.
///
/// A value type with pure mutators rather than logic inside a view, for `LibraryOutline`'s
/// reason: `SelfTest` can then assert the matching rules, the wrap-around and the offsets
/// without a view, and the offsets are exactly the part that fails silently — a match
/// highlighted one character to the left reads as a rendering quirk rather than as a bug.
///
/// Three decisions worth stating, because each had a plausible alternative:
///
/// - **Matches are UTF-16 offsets into the row's `plainText`**, which is the coordinate
///   system `PatentMarkup`'s spans already use and the one `MarkedText` subscripts an
///   `AttributedString` by. A row's text is *computed*, so it hands out a different
///   `String` instance every time it is asked and a `String.Index` from one is not valid in
///   the next.
///
/// - **Matching goes through `range(of:options:)`, not `LibrarySearch.fold`.** Folding is
///   the right tool for a filter, where only the verdict matters, and the wrong one here:
///   it *rewrites* the string — dropping an apostrophe, decomposing a diacritic — and an
///   offset into a rewritten string does not address the original. One `L'Oréal` earlier in
///   the paragraph would shift every highlight after it. `range(of:)` reports its answer in
///   the original's own indices with the same case- and diacritic-insensitivity, which
///   makes this correct by construction rather than by a compensating calculation.
///
/// - **Finding does not select.** Landing on a hit scrolls to it and lights it up, and
///   leaves `selection` alone, because a selection here scopes the reader's next question.
///   Searching for a word to check a spelling and thereby narrowing the next question to
///   one paragraph is a side effect nobody asked for — the same argument
///   `DocumentRowView`'s context menu makes about right-clicking.
struct DocumentFind: Equatable, Sendable {

    /// One occurrence: the row it is in, and where in that row's text.
    struct Match: Equatable, Sendable {
        let row: Int
        /// UTF-16 offsets into the row's `plainText`.
        let range: Range<Int>
    }

    /// What one row has to draw: every hit in it, and the current one if it is here.
    ///
    /// Handed to a row as a single value rather than as two parameters, so a row with
    /// nothing to draw is a `.none` that any diff can see through.
    struct Highlights: Equatable, Sendable {
        var ranges: [Range<Int>] = []
        /// The hit the reader is on, if it is in this row. Drawn differently, because "the
        /// document contains this word 47 times" and "you are looking at the third one" are
        /// two different facts and the reader needs both at once.
        var current: Range<Int>?

        var isEmpty: Bool { ranges.isEmpty }

        static let none = Highlights()

        /// The highlights that fall inside a slice of the row's text, rebased to it.
        ///
        /// A claim is **one** row whose text is its preamble and its elements joined, and
        /// `ClaimRowView` draws those pieces separately — so a highlight, which is an
        /// offset into the whole, has to be cut down to the piece being drawn. That is
        /// `preambleSpans`' problem next door with one difference that matters: a span
        /// filtered out is decoration nobody misses, where a highlight filtered out is a
        /// match the reader is looking for *right now*. So this clamps rather than drops,
        /// and each piece gets its share of a hit that straddles a join.
        func clipped(to slice: Range<Int>) -> Highlights {
            var clipped = Highlights()
            for range in ranges {
                let lower = max(range.lowerBound, slice.lowerBound)
                let upper = min(range.upperBound, slice.upperBound)
                guard lower < upper else { continue }
                let rebased = (lower - slice.lowerBound) ..< (upper - slice.lowerBound)
                clipped.ranges.append(rebased)
                if range == current { clipped.current = rebased }
            }
            return clipped
        }
    }

    /// Exactly what the reader typed, kept verbatim so the field can be bound to it.
    private(set) var query = ""

    /// Every occurrence, in reading order: by row, and by position within the row.
    private(set) var matches: [Match] = []

    /// Which match the reader is on, as an index into `matches`.
    private(set) var cursor: Int?

    /// `matches` grouped by row, so drawing a row is a dictionary lookup.
    ///
    /// Precomputed at search time rather than filtered per row, for the reason
    /// `DocumentSpansBox` exists: a row's `body` re-evaluates on every selection change and
    /// at frame rate through a drag, and a linear scan of a few hundred matches inside it
    /// would be paid a few hundred times a frame.
    private var rowIndex: [Int: [Range<Int>]] = [:]

    /// The shortest query worth running.
    ///
    /// One character matches a third of the document, which answers no question anybody
    /// has, and two is genuinely the shortest thing a patent reader looks for — a two-digit
    /// reference numeral, `Fi` on the way to `Fig. 3`. Below it the field reports nothing at
    /// all rather than "no matches", because the reader is still typing and a failure they
    /// did not cause is worse than silence.
    static let shortestQuery = 2

    var current: Match? {
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
    var summary: String? {
        guard isActive else { return nil }
        guard !matches.isEmpty else { return "No matches" }
        return "\((cursor ?? 0) + 1) of \(matches.count)"
    }

    /// The reader typed.
    ///
    /// `near` is the row they are reading, and it is what makes an incremental find behave:
    /// the cursor lands on the first hit at or after it, so ⌘F followed by a word takes the
    /// reader *forward* from where they are rather than throwing them back to `[0001]`.
    /// Approximated by the selection's head, which is the same approximation
    /// `DocumentReaderView` already makes when it puts the reader back after a font change —
    /// the app knows which row is selected, not which row is centred.
    mutating func search(_ raw: String, in rows: [DocumentRow], near row: Int?) {
        query = raw
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= Self.shortestQuery else {
            matches = []
            rowIndex = [:]
            cursor = nil
            return
        }

        matches = Self.matches(of: needle, in: rows)
        rowIndex = Dictionary(grouping: matches, by: \.row).mapValues { $0.map(\.range) }
        cursor = matches.isEmpty ? nil : Self.index(nearest: row, in: matches)
    }

    /// Every occurrence of a needle, in reading order.
    ///
    /// Separate and `static` so `SelfTest` can assert the matching rules against a real
    /// fixture without building a state machine around them.
    static func matches(of needle: String, in rows: [DocumentRow]) -> [Match] {
        guard !needle.isEmpty else { return [] }
        var found: [Match] = []
        for row in rows {
            let text = row.plainText
            var searched = text.startIndex
            while searched < text.endIndex,
                let hit = text.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searched ..< text.endIndex)
            {
                // The *reported* range, never the needle's length: an insensitive match is
                // not required to be as long as what it matched — a one-character `o`
                // matches a decomposed `ö`, which is two UTF-16 units.
                found.append(
                    Match(
                        row: row.index,
                        range: hit.lowerBound.utf16Offset(in: text)
                            ..< hit.upperBound.utf16Offset(in: text)))
                // Past the hit, so occurrences do not overlap, which is what every find
                // field does. The `index(after:)` branch cannot be reached with a non-empty
                // needle and is there so a future caller cannot spin here.
                searched =
                    hit.upperBound > hit.lowerBound
                    ? hit.upperBound : text.index(after: hit.lowerBound)
            }
        }
        return found
    }

    /// The first match at or after a row, wrapping to the first match in the document.
    static func index(nearest row: Int?, in matches: [Match]) -> Int {
        guard let row else { return 0 }
        return matches.firstIndex { $0.row >= row } ?? 0
    }

    /// ⌘G and ⇧⌘G, and Return in the field.
    ///
    /// Wraps in both directions and reports where it landed, so the caller can scroll
    /// there. Wrapping silently is deliberate and is what a find field does: running off the
    /// end of a document is not an error, and the counter going back to `1 of 47` says what
    /// happened.
    mutating func advance(by step: Int) -> Match? {
        guard !matches.isEmpty else { return nil }
        let from = cursor ?? 0
        // `%` keeps the sign of its left operand in Swift, so a step backwards off zero
        // needs the second modulo to come back into range.
        let next = ((from + step) % matches.count + matches.count) % matches.count
        cursor = next
        return matches[next]
    }

    /// What one row draws.
    func highlights(in row: Int) -> Highlights {
        guard let ranges = rowIndex[row] else { return .none }
        let current = current
        return Highlights(
            ranges: ranges, current: current?.row == row ? current?.range : nil)
    }

    /// Closing the field. The highlights go with it: a document still lit up for a query
    /// nobody can see is a document that looks wrong.
    mutating func clear() {
        query = ""
        matches = []
        rowIndex = [:]
        cursor = nil
    }
}
