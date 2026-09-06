// Copyright © 2026 Apple Inc.

import Foundation

/// The spans the reader draws inside a row of patent text: reference numerals, figure
/// references, and cross-references to claims.
///
/// `GutenbergMarkup` next door had to *remove* markup the transcription left in the
/// text, so it ran at the decode boundary and its spans were a byproduct. This runs the
/// other way. The text stored in a `Patent` is already clean — the parser took the tags
/// off — so nothing here is needed to make the document readable, and everything here is
/// needed to make it navigable.
///
/// **Spans are computed at render time rather than stored.** They could have been kept
/// as the parser found them, and that was the first design; it is not worth it. A stored
/// span is a UTF-16 range that has to stay aligned to text through every future change
/// to how text is normalized, it doubles the size of the library JSON, and it is the
/// exact class of thing that goes subtly wrong and shows as an underline half a word to
/// the left. Recomputing costs one pass over a paragraph and is done once per document
/// by `DocumentSpansBox`, the way `SceneItalicsBox` caches the italics next door.
///
/// The trade that buys is that a numeral is matched by *text* rather than by the tag it
/// carried. That is why `calloutNumerals` exists: the set of numbers that are part
/// numbers comes from the source's own `figure-callout` elements, so this file never
/// decides that a three-digit number is a part — it only decides where an already-known
/// part number appears. A patent whose source carried no callouts gets no numerals
/// styled, which is the right degradation.
enum PatentMarkup {

    /// One styled run of a row's text, as a UTF-16 range.
    ///
    /// UTF-16 for `LineRow`'s reason: it is what crosses the gap to `AttributedString`
    /// and to CoreText, and a `String.Index` cannot outlive the string instance it was
    /// made from.
    enum Span: Sendable, Hashable {
        /// A reference numeral the source tagged, with the term it labels.
        case referenceNumeral(Range<Int>, numeral: Int, label: String)
        /// `FIG. 1`, `FIGS. 2A-C`.
        case figureReference(Range<Int>)
        /// `claim 1` inside another claim's text, pointing at a claim that exists.
        case claimReference(Range<Int>, claim: Int)

        var range: Range<Int> {
            switch self {
            case .referenceNumeral(let range, _, _): range
            case .figureReference(let range): range
            case .claimReference(let range, _): range
            }
        }
    }

    /// Every span of one row, ordered and non-overlapping.
    ///
    /// The three kinds cannot overlap in practice — a numeral is digits, a figure
    /// reference starts with letters, a claim reference is `claim` and a number — but
    /// they are sorted and filtered anyway, because `DocumentRowView` applies them in
    /// order onto one `AttributedString` and an overlap there is a crash rather than a
    /// cosmetic problem.
    static func spans(
        in row: DocumentRow, patent: Patent
    ) -> [Span] {
        let text = row.plainText
        guard !text.isEmpty else { return [] }

        var found: [Span] = []
        found += referenceNumerals(in: text, known: patent.calloutNumerals)
        found += figureReferences(in: text)
        if case .claim(let claim) = row.kind {
            found += claimReferences(
                in: text, valid: Set(patent.claims.map(\.number)), excluding: claim.number)
        }

        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var cursor = 0
        return found.filter { span in
            guard span.range.lowerBound >= cursor, !span.range.isEmpty else { return false }
            cursor = span.range.upperBound
            return true
        }
    }

    /// Numerals that appear in `known`, as whole tokens.
    ///
    /// Whole tokens matters twice over: `100` must not match inside `1004`, and it must
    /// not match inside a decimal or a date. Bounded by "not a digit, not a letter" on
    /// both sides, which also keeps `H05K7/20336` from being taken apart.
    private static func referenceNumerals(
        in text: String, known: [Int: String]
    ) -> [Span] {
        guard !known.isEmpty else { return [] }

        var found: [Span] = []
        let units = Array(text.utf16)

        var index = 0
        while index < units.count {
            guard let scalar = Unicode.Scalar(units[index]),
                CharacterSet.decimalDigits.contains(scalar)
            else {
                index += 1
                continue
            }
            let start = index
            while index < units.count, let scalar = Unicode.Scalar(units[index]),
                CharacterSet.decimalDigits.contains(scalar)
            {
                index += 1
            }

            // A digit run touching a letter either side is part of a code (`H05K`,
            // `20336A`), not a numeral on its own.
            let before = start > 0 ? Unicode.Scalar(units[start - 1]) : nil
            let after = index < units.count ? Unicode.Scalar(units[index]) : nil
            let touching =
                before.map { CharacterSet.letters.contains($0) || $0 == "." || $0 == "/" }
                ?? false
                || after.map { CharacterSet.letters.contains($0) || $0 == "/" } ?? false
            guard !touching else { continue }

            let digits = String(decoding: units[start ..< index], as: UTF16.self)
            guard let numeral = Int(digits), let label = known[numeral] else { continue }
            found.append(
                .referenceNumeral(start ..< index, numeral: numeral, label: label))
        }
        return found
    }

    /// `FIG. 1`, `FIG. 2A`, `FIGS. 3A-D`, `FIGURE 4`.
    ///
    /// A regex rather than the source's `<figref>` tags, and that is a deliberate step
    /// down in exactness for a step up in coverage: the tags exist only on the HTML path,
    /// and a PDF import would otherwise have no figure links at all. The pattern is
    /// narrow enough that a false positive would have to be prose that says "FIG." and
    /// mean something else, which patents do not do.
    private static func figureReferences(in text: String) -> [Span] {
        let pattern = /\bFIGS?\.?\s?\d{1,3}[A-Z]?(?:\s*[-–]\s*[A-Z0-9]{1,3})?/
        return text.matches(of: pattern).compactMap { match in
            guard let range = utf16Range(match.range, in: text) else { return nil }
            return .figureReference(range)
        }
    }

    /// `claim 1` inside another claim, validated against the claims that exist.
    ///
    /// **Validated is the whole point.** The dependency data this app draws its tree
    /// from is exact — `<claim-ref idref>` where the source has it — and this is the
    /// *inline* link, which is a different job: it has to find the words "claim 1" in
    /// running text so a reader can tap them. A regex is the only way to locate words,
    /// and checking the number against the real claim list is what stops it from ever
    /// producing a link to a claim that does not exist. So the tree is exact and the link
    /// is exact; only *finding* the phrase is a pattern match.
    private static func claimReferences(
        in text: String, valid: Set<Int>, excluding own: Int
    ) -> [Span] {
        let pattern = /\bclaim\s+(\d{1,3})\b/.ignoresCase()
        return text.matches(of: pattern).compactMap { match in
            guard let number = Int(match.1), number != own, valid.contains(number),
                let range = utf16Range(match.range, in: text)
            else { return nil }
            return .claimReference(range, claim: number)
        }
    }

    private static func utf16Range(
        _ range: Range<String.Index>, in text: String
    ) -> Range<Int>? {
        let lower = range.lowerBound.utf16Offset(in: text)
        let upper = range.upperBound.utf16Offset(in: text)
        return lower < upper ? lower ..< upper : nil
    }
}

/// One document's spans, held by reference so that reading them is not a view update and
/// computing them is not a per-row cost.
///
/// `SceneItalicsBox`, transposed. `DocumentReaderView.body` re-evaluates on every
/// selection change and at frame rate through a drag, and a patent runs to a few hundred
/// rows; the scan runs once per document instead. Keyed on the `PatentKey` because the
/// reader moves between documents far less often than the selection changes, and
/// synchronous rather than a `.task` because the first frame of a document should not
/// render unstyled and then restyle under the reader.
@MainActor
final class DocumentSpansBox {
    private var cached: (key: PatentKey, spans: [[PatentMarkup.Span]])?

    func spans(for patent: Patent, rows: [DocumentRow]) -> [[PatentMarkup.Span]] {
        if let cached, cached.key == patent.key { return cached.spans }
        let computed = rows.map { PatentMarkup.spans(in: $0, patent: patent) }
        cached = (patent.key, computed)
        return computed
    }
}
