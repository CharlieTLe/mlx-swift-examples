// Copyright © 2026 Apple Inc.

import Foundation

/// The document, flattened into the rows the reader draws and the selection addresses.
///
/// One list rather than a nested render, for `SceneReaderView`'s reason: the reader is a
/// `LazyVStack` over an index range, drag selection maps a point to a row through
/// `RowFrames`, and the scroll target of a citation jump is a row index. A tree would
/// have to be flattened at each of those three places, and they would disagree.
///
/// A claim is **one row including its elements**, not one row per element. The unit a
/// reader selects and the unit a citation names have to be the same thing — `claim 7` is
/// one citation — and splitting a claim into rows would make ⌘C on "claim 7" produce
/// half of it. `ClaimRowView` draws the hanging indent inside the row instead.
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

    /// The row's text with nothing of the reader's chrome in it — no gutter number, no
    /// claim badge — which is what ⌘C copies and what the retrieval index embeds.
    var plainText: String {
        switch kind {
        case .heading(let text), .claimsHeading(let text): text
        case .paragraph(let paragraph): paragraph.text
        case .claim(let claim): claim.fullText
        }
    }

    var isHeading: Bool {
        switch kind {
        case .heading, .claimsHeading: true
        case .paragraph, .claim: false
        }
    }

    /// How deep the claim tree indents this row. Zero for everything that is not a
    /// dependent claim, and computed once when the rows are built rather than during
    /// layout — `DocumentRowView`'s size-neutrality contract means layout may not walk a
    /// graph, and the depth of claim 12 is a walk up its parents.
    var claimDepth: Int = 0

    static func == (lhs: DocumentRow, rhs: DocumentRow) -> Bool {
        lhs.index == rhs.index && lhs.kind == rhs.kind && lhs.claimDepth == rhs.claimDepth
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(kind)
        hasher.combine(claimDepth)
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
    /// Claims last, which is the reverse of how a granted patent is printed — the claims
    /// come first in the official document — and deliberate. A reader arriving at a
    /// patent through a question wants the passage the answer cited, and the answer
    /// cites specification paragraphs far more often than claims; putting twenty claims
    /// above `[0001]` would make every such landing a scroll. The navigator's Claims
    /// section is one tap either way.
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

        let depths = claimDepths()
        for claim in claims {
            rows.append(
                DocumentRow(
                    index: rows.count, kind: .claim(claim),
                    claimDepth: depths[claim.number] ?? 0))
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
