// Copyright © 2026 Apple Inc.

import Foundation

/// The document, flattened into one addressable list.
///
/// **This used to be what the reader drew**, a `LazyVStack` over an index range with drag
/// selection hit-testing into it. That reader is gone and this is not, because the
/// flattening is useful on its own: it is document order with a citation attached to each
/// entry, which is exactly what `PassageAnchors` walks and what `Headless`'s
/// `--patent --paragraph` resolves against.
///
/// A claim is **one row including its elements**, not one row per element, which is the one
/// shaping decision worth keeping stated: `claim 7` is one citation, so the unit that has a
/// target has to be the whole claim.
struct DocumentRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A `<heading>` from the specification.
        case heading(String)
        case paragraph(Paragraph)
        /// The source's own claim preamble — "What is claimed is:".
        case claimsHeading(String)
        case claim(Claim)
    }

    let index: Int
    let kind: Kind

    var id: Int { index }

    /// What this row cites as, or `nil` for a heading, which cites as nothing: a
    /// selection of headings alone has no citation, exactly as a selection of stage
    /// directions had none next door.
    func target(in patent: PatentKey) -> CitationTarget? {
        switch kind {
        case .heading, .claimsHeading: nil
        case .paragraph(let paragraph):
            .paragraph(ParagraphKey(patent: patent, number: paragraph.number))
        case .claim(let claim): .claim(ClaimKey(patent: patent, number: claim.number))
        }
    }

    /// The row's text with nothing of a reader's chrome in it — no gutter number, no
    /// claim badge.
    var plainText: String {
        switch kind {
        case .heading(let text), .claimsHeading(let text): text
        case .paragraph(let paragraph): paragraph.text
        case .claim(let claim): claim.fullText
        }
    }

}

extension DocumentRow {
    /// The row as it should appear in a quotation, which is not quite `plainText`: a
    /// claim keeps its number, because "The method of claim 1, further comprising…"
    /// pasted with no number in front of it is unattributable, and its elements keep
    /// their own lines, because that is how a claim is read.
    var copyText: String {
        switch kind {
        case .claim(let claim):
            ([("\(claim.number). " + claim.text)]
                + claim.elements.map {
                    String(repeating: "    ", count: $0.depth) + $0.text
                })
                .joined(separator: "\n")
        default: plainText
        }
    }
}

extension Patent {
    /// The whole document as rows, in reading order: the specification section by
    /// section, then the claims.
    ///
    /// Claims last, which is the reverse of how a granted patent is printed. It no longer
    /// decides what anybody scrolls past — the original is paginated by the office and this
    /// list draws nothing — but it still decides the order `PassageAnchors` emits, and that
    /// order has to match the document's or `PassagePlacement.monotonic` places almost
    /// nothing. **A US grant prints its claims at the end**, after the description, which is
    /// what this matches.
    var rows: [DocumentRow] {
        var rows: [DocumentRow] = []

        for section in sections {
            if !section.heading.isEmpty {
                rows.append(DocumentRow(index: rows.count, kind: .heading(section.heading)))
            }
            for paragraph in section.paragraphs {
                rows.append(DocumentRow(index: rows.count, kind: .paragraph(paragraph)))
            }
        }

        guard !claims.isEmpty else { return rows }
        rows.append(DocumentRow(index: rows.count, kind: .claimsHeading("Claims")))
        for claim in claims {
            rows.append(DocumentRow(index: rows.count, kind: .claim(claim)))
        }
        return rows
    }

    /// How far each claim sits from an independent one.
    ///
    /// Memoized breadth from the independents rather than recursion from each claim,
    /// because a malformed import can contain a cycle — a text-recovered `dependsOn` is
    /// a reading of prose and "the method of claim 3" inside claim 3 is a thing a badly
    /// OCR'd patent can say. A traversal that only ever moves outward from the
    /// independents terminates whatever the data says, and anything a cycle strands
    /// keeps depth 0 and draws flush left, which is wrong but finite. `SelfTest`'s
    /// `claimTree` suite is what turns that into a loud failure at import time.
    func claimDepths() -> [Int: Int] {
        var depth: [Int: Int] = [:]
        var frontier = claims.filter(\.isIndependent).map(\.number)
        for number in frontier { depth[number] = 0 }

        let dependents = claims.filter { !$0.isIndependent }
        while !frontier.isEmpty {
            let parents = Set(frontier)
            var next: [Int] = []
            for claim in dependents where depth[claim.number] == nil {
                let resolved = claim.dependsOn.compactMap { depth[$0] }
                guard !resolved.isEmpty, claim.dependsOn.contains(where: parents.contains)
                else { continue }
                // The deepest parent, so a multiply-dependent claim sits below all of
                // them rather than beside its shallowest.
                depth[claim.number] = (resolved.max() ?? 0) + 1
                next.append(claim.number)
            }
            frontier = next
        }
        return depth
    }
}
