// Copyright © 2026 Apple Inc.

import Foundation
import PDFKit

/// Every passage of one patent, located in the PDF the office published.
///
/// `PassageAnchors` says what to look for and `PassagePlacement` says which of the places it
/// was found is the right one; this is the part in between that talks to PDFKit. It is the
/// object that makes a citation chip land on a paragraph in a document that has no paragraph
/// index of its own.
///
/// ## Why the whole document, and not the eight passages an answer cited
///
/// Building only the targets of interest is the obvious economy and it destroys the
/// algorithm. `monotonic` works by requiring each placement to come after the previous one,
/// and with eight sparse targets the previous one is two hundred paragraphs back: the
/// constraint goes vacuous and every placement collapses to first-match, throwing away the
/// 42–58% of placements the ordering *corrects*. The passages either side of the one being
/// looked for are not overhead — they are the evidence that says which `[0042]` is `[0042]`.
///
/// So it costs what a whole document costs: about 2 ms per anchor warm, 0.3–2.6 s for a
/// document, the top of that range being a 131-page two-column grant with 1272 paragraphs.
/// Paid once per patent per launch, in a `Task` that yields every 32 anchors so the reader
/// can scroll and select while it runs, and cached by `PatentPDFService` for the launch.
/// `limitedTo:` is the escape hatch if a phone measures worse than a desk.
@MainActor
@Observable
final class PatentPDFMap {

    /// Where each passage is. A `PDFSelection` rather than a page number, because it is what
    /// both consumers need: `PatentPDFMarks` walks its lines to draw them, and the jump
    /// hands it straight to `PDFView.go(to:)`.
    private(set) var placed: [CitationTarget: PDFSelection] = [:]

    /// Anchored, looked for, and not found — 3% of paragraphs and about 6% of claims on the
    /// documents this was measured against. **Kept rather than discarded**, because the
    /// three places this app reports a failed jump all need to distinguish "no such
    /// paragraph" from "a real paragraph this app could not find in the PDF", and those two
    /// deserve different sentences.
    private(set) var unplaced: [CitationTarget] = []

    /// Every placement, ascending by text-stream position: the reverse index.
    ///
    /// What a selection is resolved against — see `target(containing:)`. Sorted rather than
    /// in anchor order because a binary search is what makes "which paragraph is this drag
    /// inside" a lookup rather than a scan of 1272 selections at drag speed.
    private(set) var ordinals: [(candidate: Candidate, target: CitationTarget)] = []

    /// Whether the whole document has been walked. Nothing reads `placed` as authoritative
    /// until this is true: a half-built map's `unplaced` is mostly "not looked for yet",
    /// which would report the wrong thing loudly.
    private(set) var isBuilt = false

    /// `anchored 428/437 paragraphs · 106/120 claims`, or `nil` before the build finishes.
    ///
    /// The document-wide diagnostics line, and the reason it exists is that the failure this
    /// feature has is *quiet*. A new document shape that drops to 60% looks, chip by chip,
    /// exactly like a few unlucky paragraphs. A number on screen turns it into something a
    /// reader can report.
    private(set) var summary: String?

    /// Anchor order — document order — so the nearest *placed* neighbour of a passage that
    /// could not be found is a walk outward from where it should have been.
    private var order: [CitationTarget] = []

    private let patent: Patent

    init(patent: Patent) {
        self.patent = patent
    }

    // MARK: - Building

    /// Anchors the whole document. Idempotent; re-entrant calls after the first return at
    /// once.
    ///
    /// `limitedTo` restricts the build to a slice of the anchor list. Unused today and kept
    /// from day one as the throttle: if a phone measures badly on a 1272-paragraph grant,
    /// the answer is a window around the reader rather than a feature that is switched off,
    /// and a parameter added under pressure is a parameter added in the wrong place.
    func build(in document: PDFDocument, limitedTo slice: ClosedRange<Int>? = nil) async {
        guard !isBuilt else { return }

        let anchors = PassageAnchors.anchors(in: patent)
        let range = slice.map { $0.clamped(to: 0 ... max(anchors.count - 1, 0)) }
        let wanted = range.map { Array(anchors[$0]) } ?? anchors

        var found: [[Candidate]] = []
        var selections: [[PDFSelection]] = []
        found.reserveCapacity(wanted.count)

        for (offset, anchor) in wanted.enumerated() {
            // Every 32, which at ~2 ms an anchor is a main-actor hop about every 60 ms —
            // frequent enough that a scroll stays smooth, rare enough that the hops are not
            // themselves the cost.
            if offset % 32 == 0 {
                await Task.yield()
                if Task.isCancelled { return }
            }

            var hits = search(anchor.needle, in: document)
            // The fallback only when the primary found nothing at all, which is what makes
            // it a fallback rather than a second opinion: a claim whose number the office
            // typeset in a separate run is the case it exists for.
            if hits.isEmpty, let fallback = anchor.fallback {
                hits = search(fallback, in: document)
            }
            selections.append(hits.map(\.selection))
            found.append(hits.map(\.candidate))
        }

        guard !Task.isCancelled else { return }

        let chosen = PassagePlacement.monotonic(found)
        var placed: [CitationTarget: PDFSelection] = [:]
        var unplaced: [CitationTarget] = []
        var ordinals: [(candidate: Candidate, target: CitationTarget)] = []

        for (offset, anchor) in wanted.enumerated() {
            guard let candidate = chosen[offset],
                let index = found[offset].firstIndex(of: candidate)
            else {
                unplaced.append(anchor.target)
                continue
            }
            placed[anchor.target] = selections[offset][index]
            ordinals.append((candidate, anchor.target))
        }

        self.placed = placed
        self.unplaced = unplaced
        // Already ascending — `monotonic` guarantees exactly that — and sorted anyway so the
        // binary search below rests on the sort rather than on a guarantee made elsewhere.
        self.ordinals = ordinals.sorted { $0.candidate < $1.candidate }
        self.order = wanted.map(\.target)
        self.summary = Self.summary(placed: Set(placed.keys), in: patent)
        self.isBuilt = true
    }

    /// One needle, everywhere it occurs, with its text-stream ordinal.
    ///
    /// `.caseInsensitive` because the office sets the opening words of a paragraph in small
    /// capitals often enough to matter, and `.diacriticInsensitive` for the reason every
    /// other search in this app has it: the parse's `é` and the PDF's `é` need not be the
    /// same two code points.
    private func search(_ needle: String, in document: PDFDocument)
        -> [(candidate: Candidate, selection: PDFSelection)]
    {
        document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
            .compactMap { selection in
                guard let page = selection.pages.first else { return nil }
                let index = document.index(for: page)
                guard index != NSNotFound else { return nil }
                let range = selection.range(at: 0, on: page)
                guard range.location != NSNotFound else { return nil }
                return (Candidate(page: index, offset: range.location), selection)
            }
    }

    private static func summary(placed: Set<CitationTarget>, in patent: Patent) -> String {
        var paragraphs = 0
        var claims = 0
        for target in placed {
            switch target {
            case .paragraph: paragraphs += 1
            case .claim: claims += 1
            }
        }
        return "anchored \(paragraphs)/\(patent.paragraphs.count) paragraphs · "
            + "\(claims)/\(patent.claims.count) claims"
    }

    // MARK: - Reading

    func selection(for target: CitationTarget) -> PDFSelection? { placed[target] }

    /// The nearest passage to this one that *was* found, in document order.
    ///
    /// The first of the three things that happen when a jump cannot land: the reader is put
    /// next door rather than left where they were. Being one paragraph off, and told so, is
    /// a far better answer than a chip that appears to do nothing — which is what "click a
    /// citation, land on the passage" degrades to without this.
    ///
    /// Walks outward from where the passage should have been, preferring the one before it,
    /// because a paragraph reads down and landing above the gap puts the missing text on
    /// screen below.
    func nearestPlaced(to target: CitationTarget) -> CitationTarget? {
        guard let home = order.firstIndex(of: target) else { return nil }
        var before = home - 1
        var after = home + 1
        while before >= 0 || after < order.count {
            if before >= 0 {
                if placed[order[before]] != nil { return order[before] }
                before -= 1
            }
            if after < order.count {
                if placed[order[after]] != nil { return order[after] }
                after += 1
            }
        }
        return nil
    }

    /// Which passage a position in the text stream falls inside.
    ///
    /// The last placement at or before it, which is the passage that was open at that point
    /// in the document. **This never compares text**, which is the whole reason it is
    /// preferred over `PassageAnchors.target(containing:)`: hyphenation, OCR damage and a
    /// two-column drag that scrambles the order cannot defeat an integer comparison.
    ///
    /// `nil` before the first placement, which is the front matter — a cover page, an
    /// abstract, a drawing sheet — where there is genuinely no passage to name.
    func target(at position: Candidate) -> CitationTarget? {
        var low = 0
        var high = ordinals.count
        while low < high {
            let middle = (low + high) / 2
            if ordinals[middle].candidate <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? ordinals[low - 1].target : nil
    }

    /// The text-stream position of a point in a `PDFSelection`, for `target(at:)`.
    ///
    /// `first: false` asks for the selection's *end*, which is what a range citation needs:
    /// a drag across three paragraphs has to resolve both ends or it cites only the first.
    static func position(of selection: PDFSelection, first: Bool, in document: PDFDocument)
        -> Candidate?
    {
        guard let page = first ? selection.pages.first : selection.pages.last
        else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0 else { return nil }
        let range = selection.range(at: first ? 0 : count - 1, on: page)
        guard range.location != NSNotFound else { return nil }
        return Candidate(
            page: index, offset: first ? range.location : range.location + range.length)
    }
}
