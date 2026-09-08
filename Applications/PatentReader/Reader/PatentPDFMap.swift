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
    var summary: String? { report?.summary }

    /// Everything the walk learned about itself, or `nil` until it finishes.
    ///
    /// Kept because `--anchor` prints it, and `--anchor` is how the 97% is re-measured on a
    /// patent that is not one of this repository's four HTML fixtures — in particular on the
    /// case the fixtures cannot cover at all, where the parse came from Google's HTML and
    /// the PDF from `patentimages`, so the two can genuinely disagree. Without it the only
    /// way to know whether anchoring works on a document is to click every chip.
    private(set) var report: Report?

    /// What the walk found. Every field is a number the plan this was built from measured,
    /// so a regression is a diff rather than an impression.
    struct Report: Sendable {
        var totalParagraphs = 0
        var totalClaims = 0
        /// Long enough to anchor at all. See `PassageAnchors`.
        var anchoredParagraphs = 0
        var anchoredClaims = 0
        /// Anchored, found, and ordered into place.
        var placedParagraphs = 0
        var placedClaims = 0
        /// Anchors whose needle matched in two or more places. Expected to be *most* of
        /// them — 242 of 437 on one probe, 820 of 1272 on another — which is the fact that
        /// makes the ordering pass load-bearing rather than a refinement.
        var ambiguous = 0
        /// Placements the monotonic pass moved off the first match. 42% and 58% on the two
        /// big probes: this is the number that says what the algorithm is worth.
        var corrected = 0
        /// Anchors whose primary needle found nothing and whose fallback was tried.
        var fellBack = 0
        var seconds: TimeInterval = 0

        var summary: String {
            "anchored \(placedParagraphs)/\(totalParagraphs) paragraphs · "
                + "\(placedClaims)/\(totalClaims) claims"
        }
    }

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
        let started = Date()

        let anchors = PassageAnchors.anchors(in: patent)
        let range = slice.map { $0.clamped(to: 0 ... max(anchors.count - 1, 0)) }
        let wanted = range.map { Array(anchors[$0]) } ?? anchors

        var report = Report(
            totalParagraphs: patent.paragraphs.count, totalClaims: patent.claims.count)
        for anchor in wanted {
            switch anchor.target {
            case .paragraph: report.anchoredParagraphs += 1
            case .claim: report.anchoredClaims += 1
            }
        }

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
                if !hits.isEmpty { report.fellBack += 1 }
            }
            if hits.count > 1 { report.ambiguous += 1 }
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
            if index > 0 { report.corrected += 1 }
            switch anchor.target {
            case .paragraph: report.placedParagraphs += 1
            case .claim: report.placedClaims += 1
            }
            placed[anchor.target] = selections[offset][index]
            ordinals.append((candidate, anchor.target))
        }

        report.seconds = Date().timeIntervalSince(started)

        self.placed = placed
        self.unplaced = unplaced
        // Already ascending — `monotonic` guarantees exactly that — and sorted anyway so the
        // binary search below rests on the sort rather than on a guarantee made elsewhere.
        self.ordinals = ordinals.sorted { $0.candidate < $1.candidate }
        self.order = wanted.map(\.target)
        self.report = report
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
        // A needle that opens with a claim's printed number must not be allowed to match
        // *inside* a longer number, and `findString` knows nothing of word boundaries.
        // `8. The method of claim` occurs in `108. The method of claim` — so on a document
        // with a hundred-odd claims, claim 8's needle finds claim 108 and nothing else,
        // because claim 8's own number is set at the end of a line and the primary needle
        // never matches there at all. Measured on WO 2020247738 A9: this one collision
        // placed claim 8 forty pages downstream, and since `monotonic` only ever moves the
        // cursor *forward*, it stranded claims 9-120 behind it — 13 placed of 120, against
        // 113 with the guard. The forward jump is the damage; the substring match is the
        // cause, and it is also what suppressed the fallback that exists for exactly the
        // line-broken-number case, since a fallback only fires when the primary finds
        // nothing.
        let guarded = needle.first?.isNumber ?? false
        return document
            .findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
            .compactMap { selection in
                guard let page = selection.pages.first else { return nil }
                let index = document.index(for: page)
                guard index != NSNotFound else { return nil }
                let range = selection.range(at: 0, on: page)
                guard range.location != NSNotFound else { return nil }
                if guarded, range.location > 0, let text = page.string as NSString? {
                    let before = text.substring(
                        with: NSRange(location: range.location - 1, length: 1))
                    if before.rangeOfCharacter(from: .decimalDigits) != nil { return nil }
                }
                return (Candidate(page: index, offset: range.location), selection)
            }
    }

    // MARK: - Reading

    func selection(for target: CitationTarget) -> PDFSelection? { placed[target] }

    /// The whole passage, for painting: from where it starts to where the next one does.
    ///
    /// **The needle is an address, not the thing being addressed**, and for a while the marks
    /// were drawn on the address. A reader who asked a question and got back evidence painted
    /// onto the document saw six words of a paragraph lit up — or, on a document that prints
    /// its markers, the bare `[00355]` and nothing else — under a tooltip reading "the passage
    /// you asked for". It was pointing *at* the passage while claiming to *be* it.
    ///
    /// The extent is already known and costs nothing to read: `ordinals` is every placement in
    /// document order, so a passage runs from its own position to the next placement, and two
    /// entries of an array that is already sorted answer it.
    ///
    /// Bounded by the passage's own length as the parse measured it, because the next
    /// placement is not always the next passage. A paragraph that could not be located leaves
    /// a gap, and the last placement in the document has nothing after it at all — a claim at
    /// the end of a PCT publication would otherwise paint the twenty-six pages of sequence
    /// listing behind it.
    ///
    /// **An eighth over, and no constant.** The eighth is what the PDF's own text carries that
    /// the parse took out: a line break per printed line, and the margin line numbers
    /// `PatentPDFImporter` strips. A flat slack on top of it looked harmless and was not —
    /// eighty characters is nothing against a long paragraph and doubles a short one, and
    /// short paragraphs are most of the tail. Measured over the three documents: with
    /// `n/2 + 80`, 321 of the grant's 1241 passages painted more than a quarter past their
    /// own end and the 90th percentile was exactly twice the passage; with `n/8` it is 16 and
    /// 1.20, for one extra passage cut short. The 28 that do come up short are the placement
    /// drift this bound cannot see and does not cause — where the *next* passage was placed
    /// inside this one, the next placement wins and the mark stops early.
    func extent(of target: CitationTarget, in document: PDFDocument) -> PDFSelection? {
        guard let start = placed[target].flatMap({
            Self.position(of: $0, first: true, in: document)
        }) else { return nil }

        let budget = expectedLength(of: target)
        var end = advance(start, by: budget + budget / 8, in: document)
        if let next = ordinals.first(where: { $0.candidate > start })?.candidate, next < end {
            end = next
        }
        guard
            let startPage = document.page(at: start.page),
            let endPage = document.page(at: end.page)
        else { return placed[target] }
        // `atCharacterIndex` is inclusive at both ends, so the last character of the passage
        // is the one before the next passage's first.
        let last = end.page == start.page ? max(end.offset - 1, start.offset) : end.offset - 1
        return document.selection(
            from: startPage, atCharacterIndex: start.offset,
            to: endPage, atCharacterIndex: max(last, 0)) ?? placed[target]
    }

    /// How many characters this passage ran to in the parse.
    private func expectedLength(of target: CitationTarget) -> Int {
        switch target {
        case .paragraph(let key):
            patent.paragraph(numbered: key.number)?.text.count ?? 0
        case .claim(let key):
            patent.claim(numbered: key.number)?.fullText.count ?? 0
        }
    }

    /// `characters` further into the text stream, walking pages as it runs off their ends.
    private func advance(_ start: Candidate, by characters: Int, in document: PDFDocument)
        -> Candidate
    {
        var page = start.page
        var remaining = start.offset + characters
        while page < document.pageCount {
            let length = document.page(at: page)?.string?.utf16.count ?? 0
            if remaining <= length { return Candidate(page: page, offset: remaining) }
            remaining -= length
            page += 1
        }
        let last = max(document.pageCount - 1, 0)
        return Candidate(
            page: last, offset: document.page(at: last)?.string?.utf16.count ?? 0)
    }

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

    /// Every passage a selection touches, in document order.
    ///
    /// **This is the leg ⇧⌘C runs on, and it never compares a character.** The reader's drag
    /// has two ends; each end is a `(page, offset)` in the text stream; each falls inside the
    /// bracket of whichever passage was open there. Two binary searches and a slice. Nothing
    /// in that can be defeated by hyphenation, by justification, or by the OCR damage that
    /// makes US10123456B2 claim 5 read "wherein fon ling the internal matrix" in Google's
    /// text and something else in the office's PDF — which is exactly why it is preferred to
    /// `PassageAnchors.target(containing:)`, the textual fallback for a selection that lands
    /// outside every bracket.
    ///
    /// Empty for a drag over a cover page, a drawing sheet or anything else before the first
    /// placement, which is a real answer: there is no passage there to name.
    func targets(spanning selection: PDFSelection, in document: PDFDocument)
        -> [CitationTarget]
    {
        guard
            let start = Self.position(of: selection, first: true, in: document),
            let end = Self.position(of: selection, first: false, in: document),
            let low = index(containing: start)
        else { return [] }
        let high = index(containing: end) ?? low
        guard low <= high else { return [] }
        return ordinals[low ... high].map(\.target)
    }

    /// The index into `ordinals` of the passage a position falls inside.
    private func index(containing position: Candidate) -> Int? {
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
        return low > 0 ? low - 1 : nil
    }

    /// Which passage a position in the text stream falls inside.
    ///
    /// The last placement at or before it, which is the passage that was open at that point
    /// in the document.
    ///
    /// `nil` before the first placement, which is the front matter — a cover page, an
    /// abstract, a drawing sheet — where there is genuinely no passage to name.
    func target(at position: Candidate) -> CitationTarget? {
        index(containing: position).map { ordinals[$0].target }
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

    /// Something inside one passage: the first occurrence of a string within that passage's
    /// own span of the document.
    ///
    /// A reference numeral, and only that. Searching the whole document for `130` and taking
    /// the first hit would answer a different question — the numeral appears in every figure
    /// caption — and would quietly replace the pure "first paragraph that mentions it" rule
    /// this app decided on with "first mention anywhere". Bracketing keeps that rule intact
    /// and only sharpens where in the paragraph the reader lands.
    ///
    /// `nil` when the passage was never placed, or when the string is not in it after all,
    /// in which case the caller lands on the passage — which is the older, coarser answer
    /// and still a correct one.
    func refine(_ needle: String, within target: CitationTarget, in document: PDFDocument)
        -> PDFSelection?
    {
        guard let start = ordinals.firstIndex(where: { $0.target == target })
        else { return nil }
        let from = ordinals[start].candidate
        let until = start + 1 < ordinals.count ? ordinals[start + 1].candidate : nil

        return search(needle, in: document)
            .first { hit in
                hit.candidate >= from && (until.map { hit.candidate < $0 } ?? true)
            }?
            .selection
    }
}
