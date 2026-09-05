// Copyright © 2026 Apple Inc.

import Foundation

/// A selection of rows, as an anchor and a moving head.
///
/// SwiftUI's `Text` does not expose a selected character range, and a chapter is
/// row-structured anyway, so selection is a range of indices into `Chapter.rows`. That
/// is the better fit regardless: row indices are what the context window, the cache
/// key, and the citation are all built on.
///
/// Anchor and head are kept separate rather than normalized into a range because
/// shift-clicking and shift-arrowing have to extend from the *original* anchor,
/// including backwards through it.
struct VerseSelection: Equatable, Sendable, Codable {
    var anchor: Int
    var head: Int

    init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    init(at index: Int) {
        self.init(anchor: index, head: index)
    }

    var range: ClosedRange<Int> {
        min(anchor, head) ... max(anchor, head)
    }

    var count: Int { range.count }

    func contains(_ index: Int) -> Bool { range.contains(index) }

    /// The whole syntactic period containing `index`: the run of consecutive verses
    /// that make one sentence.
    ///
    /// This replaces ShakespeareReader's `speech(at:in:)`, and it is not an arbitrary
    /// substitute. Douay-Rheims verses are frequently mid-sentence, and a reader who
    /// double-taps one of them wants the thought, not the versification. Genesis
    /// 15:19-21 is literally *"The Cineans, and Cenezites, the Cedmonites,"* / *"And
    /// the Hethites…"* / *"And the Amorrhites…"* — three verses, one list.
    ///
    /// Decidable from the text and cheap, and its failure mode is a selection that is
    /// slightly too short rather than one that is wrong. A note or a section heading
    /// selects just itself; notes *inside* the run do not break it, the way an
    /// interleaved stage direction did not break a speech.
    static func period(at index: Int, in rows: [Row]) -> VerseSelection {
        guard rows.indices.contains(index), rows[index].isVerse else {
            return VerseSelection(at: index)
        }

        var first = index
        while let previous = verseIndex(before: first, in: rows),
            continues(rows[previous].text)
        {
            first = previous
        }

        var last = index
        while continues(rows[last].text),
            let next = verseIndex(after: last, in: rows)
        {
            last = next
        }

        // A run should not end on a note that happens to trail the last verse.
        while last > first, !rows[last].isVerse { last -= 1 }
        while first < last, !rows[first].isVerse { first += 1 }

        return VerseSelection(anchor: first, head: last)
    }

    /// Whether a verse runs on into the next one.
    ///
    /// Three signals, and all three are in the text: a comma, a semicolon or a colon at
    /// the end, or no terminal punctuation at all — which in this edition shows up as a
    /// final lowercase word. Trailing quotation marks and brackets are stepped over
    /// first, since they close a quotation rather than end a sentence.
    static func continues(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t\"”’')]"))
        guard let last = trimmed.last else { return false }
        if last == "," || last == ";" || last == ":" { return true }
        return last.isLetter && last.isLowercase
    }

    private static func verseIndex(before index: Int, in rows: [Row]) -> Int? {
        (0 ..< index).last { rows[$0].isVerse }
    }

    private static func verseIndex(after index: Int, in rows: [Row]) -> Int? {
        (index + 1 ..< rows.count).first { rows[$0].isVerse }
    }

    /// The whole chapter, which the "Select chapter" toolbar item needs.
    static func chapter(_ rows: [Row]) -> VerseSelection? {
        guard !rows.isEmpty else { return nil }
        return VerseSelection(anchor: 0, head: rows.count - 1)
    }

    /// Moves the head, keeping the anchor. Used by shift-click and shift-arrow.
    mutating func extend(to index: Int) {
        head = index
    }

    /// Where an arrow key moves a selection: one row in `step`'s direction, extending
    /// from the anchor when shift is held.
    ///
    /// `nil` means there is no row that way in this chapter, which is the caller's cue
    /// to roll into the neighbouring one. Extending never returns `nil`: a selection is
    /// chapter-scoped by design, so shift-arrow stops at the edge rather than crossing.
    /// With nothing selected the first press *lands* rather than steps, on the opening
    /// row whichever way it was pressed.
    static func moved(
        from current: VerseSelection?, by step: Int, extending: Bool, in rows: [Row]
    ) -> VerseSelection? {
        guard !rows.isEmpty else { return nil }
        let upper = rows.count - 1
        guard let current else { return VerseSelection(at: 0) }

        let target = current.head + step
        guard rows.indices.contains(target) else {
            guard extending else { return nil }
            var stopped = current
            stopped.extend(to: min(max(0, target), upper))
            return stopped
        }
        guard extending else { return VerseSelection(at: target) }
        var extended = current
        extended.extend(to: target)
        return extended
    }

    /// Clamps into a chapter, so a stale selection can never index out of bounds after
    /// the reader switches chapters.
    func clamped(to rows: [Row]) -> VerseSelection? {
        guard !rows.isEmpty else { return nil }
        let upper = rows.count - 1
        return VerseSelection(
            anchor: min(max(0, anchor), upper),
            head: min(max(0, head), upper))
    }
}
