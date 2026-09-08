// Copyright © 2026 Apple Inc.

import Foundation

/// Where in a document one anchor's text was found: a **text-stream** position.
///
/// The two fields together are `(document.index(for: page), selection.range(at: 0, on:
/// page).location)`, which is PDFKit's own reading order — the order the text was laid down
/// in the content stream, which for a well-made PDF is the order it is meant to be read in.
///
/// **The alternative was geometry, and geometry is wrong.** Ordering candidates by
/// `(page, y)` instead placed 93 of 1241 paragraphs on a two-column US grant, against 1241
/// with this: on a two-column page, reading order runs down the left column and back up to
/// the top of the right, so a paragraph that comes *later* in the document sits *higher* on
/// the page, and every monotonic step over it fails. The text stream has that ordering
/// already and needs no layout analysis to recover it.
struct Candidate: Comparable, Hashable, Sendable {
    /// Zero-based, `PDFDocument.index(for:)`.
    let page: Int
    /// UTF-16 location of the match within that page's own text.
    let offset: Int

    /// Lexicographic: page first, then position in the page.
    static func < (lhs: Candidate, rhs: Candidate) -> Bool {
        lhs.page == rhs.page ? lhs.offset < rhs.offset : lhs.page < rhs.page
    }
}

/// Choosing, out of everywhere each anchor was found, the one place each anchor *is*.
///
/// Pure and PDFKit-free, so the ordering rule — which is the whole algorithm — is asserted
/// by `--selftest` over synthetic candidate lists rather than only ever exercised against a
/// document nobody has checked in.
///
/// Also the home of the find cursor's two pieces of arithmetic, which are lifted verbatim
/// out of the deleted `DocumentFind` so that the assertions written against them survive it.
enum PassagePlacement {

    /// The earliest candidate for each target that comes after the one chosen for the
    /// previous target, in order.
    ///
    /// ## Why this is not "take the first match"
    ///
    /// **Ambiguity is the norm, not the exception.** Of 437 paragraphs anchored in a PCT
    /// publication, 242 matched in two or more places; of 1272 in a two-column grant, 820
    /// did. That is what a patent is: a document that says "the internal matrix 130" in the
    /// summary, again in the detailed description, and again in a claim. Taking the first
    /// match would put a third of the highlights in the summary.
    ///
    /// A document read front to back visits its paragraphs in order, so the constraint is
    /// simply that the placements ascend. Walking the targets in document order and taking
    /// the earliest candidate strictly after the previous choice enforces it in one pass.
    /// It *changed* 179 of 428 placements on the publication and 715 of 1241 on the grant —
    /// 42% and 58% — which is the measurement that makes this worth a file.
    ///
    /// ## Getting stuck
    ///
    /// When a target has no candidate after the cursor, it is left unplaced and **the cursor
    /// does not move**. The alternative — reset the cursor, or take the earliest candidate
    /// anywhere — trades one lost chip for a stray early match that then drags every
    /// subsequent target back up the document with it. One paragraph that cannot be located
    /// is a band under the jump saying so; a cascade is a reader who no longer trusts any of
    /// them. Across the three probes nothing got stuck: 428, 1241 and 284 placed, 0 unplaced.
    ///
    /// Returns one entry per input, in the same order, `nil` where nothing could be placed.
    static func monotonic(_ candidates: [[Candidate]]) -> [Candidate?] {
        var placed: [Candidate?] = []
        placed.reserveCapacity(candidates.count)
        var cursor: Candidate?

        for list in candidates {
            // Sorted rather than assumed sorted: `findString` returns document order, but
            // an anchor with a fallback contributes two searches' results concatenated, and
            // the fallback's hits are not after the primary's.
            let pick = list.sorted().first { candidate in
                cursor.map { candidate > $0 } ?? true
            }
            placed.append(pick)
            if let pick { cursor = pick }
        }
        return placed
    }

    // MARK: - The find cursor

    /// The first match at or after a page, wrapping to the first match in the document.
    ///
    /// Lifted from `DocumentFind.index(nearest:in:)` with `row` widened to `page`, which is
    /// the same idea one coordinate system over: it is what stops ⌘F from throwing the
    /// reader back to page 1 when they are reading page 40.
    static func index(nearest page: Int?, in pages: [Int]) -> Int {
        guard let page else { return 0 }
        return pages.firstIndex { $0 >= page } ?? 0
    }

    /// ⌘G and ⇧⌘G. Wraps in both directions; `nil` when there is nothing to step through.
    ///
    /// Lifted from `DocumentFind.advance(by:)`. Wrapping silently is deliberate and is what
    /// a find field does: running off the end of a document is not an error, and the counter
    /// going back to `1 of 47` says what happened.
    static func stepped(from cursor: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let from = cursor ?? 0
        // `%` keeps the sign of its left operand in Swift, so a step backwards off zero
        // needs the second modulo to come back into range.
        return ((from + step) % count + count) % count
    }
}
