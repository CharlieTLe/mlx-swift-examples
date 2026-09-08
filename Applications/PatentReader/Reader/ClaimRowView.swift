// Copyright © 2026 Apple Inc.

import SwiftUI

/// One claim, set as a printed patent sets it: a preamble, its elements hanging under it,
/// and the whole thing indented under the claim it depends on.
///
/// **This is the single biggest legibility win the app has, and it costs nothing**,
/// because the dependency data is exact — `<claim-ref idref>` in the source for a modern
/// patent, and read from the claim's own opening clause for an older one. A claim set is
/// a tree that every patent prints as a flat numbered list, and a reader's first job on
/// opening one is to reconstruct that tree by hand: read claim 12, find "the method of
/// claim 6", scroll up, read claim 6, find "the method of claim 1", scroll up again.
/// Drawing it removes that job entirely.
///
/// Three things carry the structure, and the redundancy is deliberate:
///
/// - **The indent**, one level per step from an independent claim, so the shape of the
///   set is visible from across the room.
/// - **The parent badge** in front of the text, which says *which* claim this hangs
///   from — the indent alone cannot, since two claims at the same depth may have
///   different parents.
/// - **The inline cross-reference**, the words "claim 1" in the claim's own text, which
///   is a link to the same place. Redundant with the badge on purpose: the badge is for
///   scanning and the words are for reading, and a reader following the sentence should
///   not have to look away to act on it.
@MainActor
struct ClaimRowView: View {
    let claim: Claim
    let patent: Patent
    let spans: [PatentMarkup.Span]
    /// The find hits in this claim, as offsets into the row's whole text — which for a claim
    /// is `fullText`, so they have to be cut to the piece being drawn. See `elementSlices`.
    let highlights: DocumentFind.Highlights
    let depth: Int
    let onOpen: (CitationTarget) -> Void

    @Environment(\.readerTypeface) private var typeface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !claim.dependsOn.isEmpty {
                    parentBadge
                }
                MarkedText(
                    text: claim.text, spans: preambleSpans, marked: nil,
                    highlights: highlights.clipped(to: preambleSlice), typeface: typeface
                )
                .selectableProse()
                .font(typeface.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The claim's own sub-paragraphs, each hanging one level further in. A claim
            // is drafted as a list and reads as one; run together as a single wrapped
            // block — which is how every patent site renders it — a ten-limitation claim
            // is a 300-word sentence with nine semicolons in it.
            ForEach(Array(claim.elements.enumerated()), id: \.offset) { index, element in
                MarkedText(
                    text: element.text, spans: [], marked: nil,
                    highlights: highlights.clipped(to: elementSlices[index]),
                    typeface: typeface
                )
                .selectableProse()
                .font(typeface.claimElement)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, typeface.claimIndent * CGFloat(element.depth + 1))
            }
        }
        // One level per step from an independent claim. Applied to the whole row rather
        // than to the text, so the badge indents with it — a badge left flush would read
        // as a margin marker rather than as part of the claim.
        .padding(.leading, typeface.claimIndent * CGFloat(depth))
        .overlay(alignment: .leading) {
            // A hairline rule above an independent claim, which is where the set
            // restarts. The one visual cue that says "a new invention begins here"
            // rather than "this is a further limitation".
            if claim.isIndependent, claim.number > 1 {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: -typeface.blockGap / 2)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// `⌐1`, or `⌐1, 10` for a multiply-dependent claim.
    ///
    /// A button rather than a link because it sits outside the text, so `Text`'s
    /// restriction — the reason the inline references are links — does not apply, and a
    /// real button gets a real hit target and a real accessibility label.
    ///
    /// The tooltip carries `dependencySource`, which is the one place a reader can find
    /// out that a tree was read from prose rather than from markup. That distinction is
    /// invisible in the drawing and worth being able to check: an older grant's edges are
    /// recovered from "The method of claim 1", and while that is reliable it is not the
    /// same kind of fact as an attribute in the source.
    @ViewBuilder
    private var parentBadge: some View {
        Button {
            guard let first = claim.dependsOn.first else { return }
            onOpen(.claim(ClaimKey(patent: patent.key, number: first)))
        } label: {
            Text("⌐\(claim.dependsOn.map(String.init).joined(separator: ","))")
                .font(typeface.gutterFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(dependencyDescription)
        .accessibilityLabel(dependencyDescription)
    }

    private var dependencyDescription: String {
        let parents = claim.dependsOn.map(String.init).joined(separator: " and ")
        let base = "Depends on claim \(parents)"
        switch claim.dependencySource {
        case .markup: return base
        case .text: return base + " — read from this claim's own wording"
        case .none: return base
        }
    }

    /// The spans that fall inside the preamble.
    ///
    /// `PatentMarkup` computes spans against the row's whole text — preamble plus
    /// elements joined — because that is what the index and ⌘C use. The preamble is
    /// rendered on its own, so a span past its end would be applied to the wrong
    /// characters, and one straddling the boundary would be applied to half a word.
    /// Filtering to the ones wholly inside it is what keeps the two in step; the
    /// elements are drawn unstyled, which is a small loss and much better than a numeral
    /// highlighted three words to the left of itself.
    private var preambleSpans: [PatentMarkup.Span] {
        let limit = claim.text.utf16.count
        return spans.filter { $0.range.upperBound <= limit }
    }

    /// Where the preamble sits in `fullText`, which is at the front of it.
    private var preambleSlice: Range<Int> { 0 ..< claim.text.utf16.count }

    /// Where each element sits in `fullText`.
    ///
    /// `Claim.fullText` is the preamble and the elements joined by a **single space**, and
    /// this is the one place that fact is depended on outside the model. It is depended on
    /// rather than worked around because the alternative is worse: searching each element's
    /// text separately would give the find field a second set of coordinates for the same
    /// row, and the row is what a citation names and what ⌘C copies.
    ///
    /// Spans get none of this and are simply dropped past the preamble — `preambleSpans`
    /// above — which is a real if small loss the header explains. A *highlight* cannot be
    /// dropped the same way, because it is what the reader is looking for.
    private var elementSlices: [Range<Int>] {
        var slices: [Range<Int>] = []
        var start = claim.text.utf16.count
        for element in claim.elements {
            start += 1  // the separator `fullText` joins with
            let length = element.text.utf16.count
            slices.append(start ..< start + length)
            start += length
        }
        return slices
    }
}
