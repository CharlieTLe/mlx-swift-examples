// Copyright © 2026 Apple Inc.

import Foundation

/// A selection of document rows, as an anchor and a moving head.
///
/// `LineSelection` from ShakespeareReader, renamed for what it selects and otherwise
/// unchanged in shape, because the reasoning transfers exactly: SwiftUI's `Text` does not
/// expose a selected character range, the document is row-structured, and row indices are
/// what the citation, the cache key and the scroll target are all built on.
///
/// Anchor and head are kept separate rather than normalized into a range because
/// shift-clicking and shift-arrowing have to extend from the *original* anchor, including
/// backwards through it.
struct PassageSelection: Equatable, Sendable, Codable {
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

    /// The whole unit containing `index`, which is what a double-click takes.
    ///
    /// In a play that was a speech — a contiguous run of one speaker. Here the unit is
    /// simpler and the reason is worth stating: a patent paragraph and a patent claim are
    /// each already the whole thing they are, so there is no run to gather. What a
    /// double-click adds is the **section**: double-clicking a heading takes the heading
    /// and everything under it, which is how a reader selects "the Background" to copy or
    /// to scope a question to.
    static func unit(at index: Int, in rows: [DocumentRow]) -> PassageSelection {
        guard rows.indices.contains(index) else { return PassageSelection(at: index) }
        guard rows[index].isHeading else { return PassageSelection(at: index) }

        var last = index
        while last + 1 < rows.count, !rows[last + 1].isHeading { last += 1 }
        return PassageSelection(anchor: index, head: last)
    }

    /// Moves the head, keeping the anchor. Used by shift-click and shift-arrow.
    mutating func extend(to index: Int) {
        head = index
    }

    /// Where an arrow key moves a selection: one row in `step`'s direction, extending
    /// from the anchor when shift is held.
    ///
    /// `nil` means there is no row that way in this document, which is the caller's cue
    /// to do nothing — unlike a play, where it rolled into the next scene. A patent is
    /// not a sequence the way a play's scenes are, and rolling from the last claim of one
    /// patent into the first paragraph of an alphabetically adjacent one would be a jump
    /// nobody asked for.
    ///
    /// With nothing selected the first press *lands* rather than steps, on the opening
    /// row whichever way it was pressed — stepping from an implied head of 0 made ↓ skip
    /// the first row of every document.
    static func moved(
        from current: PassageSelection?, by step: Int, extending: Bool,
        in rows: [DocumentRow]
    ) -> PassageSelection? {
        guard !rows.isEmpty else { return nil }
        let upper = rows.count - 1
        guard let current else { return PassageSelection(at: 0) }

        let target = current.head + step
        guard rows.indices.contains(target) else {
            guard extending else { return nil }
            var stopped = current
            stopped.extend(to: min(max(0, target), upper))
            return stopped
        }
        guard extending else { return PassageSelection(at: target) }
        var extended = current
        extended.extend(to: target)
        return extended
    }

    /// Clamps into a document, so a stale selection can never index out of bounds after
    /// the reader switches patents.
    func clamped(to rows: [DocumentRow]) -> PassageSelection? {
        guard !rows.isEmpty else { return nil }
        let upper = rows.count - 1
        return PassageSelection(
            anchor: min(max(0, anchor), upper),
            head: min(max(0, head), upper))
    }
}
