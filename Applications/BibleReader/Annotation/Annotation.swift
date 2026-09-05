// Copyright © 2026 Apple Inc.

import Foundation

/// The model's turn-1 output, split into its four sections.
///
/// **Parsed rather than trusted.** The prompt asks for four labelled sections in a fixed
/// order and the model mostly complies, but "mostly" is the whole problem: a run that
/// drops `SEE ALSO` looks identical to a passage with no cross-references, and a run
/// that reorders them looks like nothing at all if the parser assumes order. So this
/// tolerates every failure it can and reports the rest.
///
/// Every field is optional and every one is **omittable in the pane**. That is
/// `Prompts.wordBudget`'s lesson applied to structure: a floor buys padding, and the
/// padding is wrong. An absent section renders as absent.
struct Annotation: Equatable, Sendable {
    var plainSense: String?
    var context: String?
    var seeAlso: String?
    var tradition: String?

    /// Anything before the first label.
    ///
    /// Normally empty, and load-bearing when it is not: a run that ignores the format
    /// entirely lands here whole rather than being thrown away. An unparseable annotation
    /// the reader can still read beats a blank pane, and it is also the evidence that
    /// says the format is slipping.
    var preamble: String?

    var isEmpty: Bool {
        plainSense == nil && context == nil && seeAlso == nil && tradition == nil
            && preamble == nil
    }

    /// Which of the four the model actually produced, in the app's own order.
    var present: [Prompts.Section] {
        Prompts.Section.allCases.filter { self[$0] != nil }
    }

    subscript(section: Prompts.Section) -> String? {
        switch section {
        case .plainSense: plainSense
        case .context: context
        case .seeAlso: seeAlso
        case .tradition: tradition
        }
    }

    /// Splits raw model output on the four markers.
    ///
    /// **Safe on a partial string**, which is what makes the sections stream. The pane
    /// re-parses on every chunk, so a half-written `THE TRADITION` renders as a
    /// half-written tradition section rather than as nothing — and the sections appear
    /// one by one as the model reaches them. That is why there is no `.section` event on
    /// the service: the accumulated text is the state, and parsing is a pure function of
    /// it, so nothing has to be kept in step.
    ///
    /// Order-independent by construction: the markers are located wherever they are and
    /// each section runs to the next one found, not to the next one expected.
    static func parseSections(_ raw: String) -> Annotation {
        // **Every** occurrence of every label, not one per section. A section's body has
        // to end at the next label of *any* kind, including a repeat of its own — a model
        // that restarts `PLAIN SENSE` would otherwise leave its second label sitting
        // inside the first section's text.
        var hits = Prompts.Section.allCases.flatMap { section in
            markers(section, in: raw).map { (section: section, range: $0) }
        }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }

        var annotation = Annotation()

        let firstMarker = hits.first?.range.lowerBound ?? raw.endIndex
        annotation.preamble = tidy(String(raw[raw.startIndex ..< firstMarker]))

        for (offset, hit) in hits.enumerated() {
            let end = offset + 1 < hits.count ? hits[offset + 1].range.lowerBound : raw.endIndex
            let body = tidy(String(raw[hit.range.upperBound ..< end]))
            switch hit.section {
            // First writer wins if the model emits a label twice, which it does
            // occasionally when it restarts a section. The first one is the one it was
            // asked for.
            case .plainSense: annotation.plainSense = annotation.plainSense ?? body
            case .context: annotation.context = annotation.context ?? body
            case .seeAlso: annotation.seeAlso = annotation.seeAlso ?? body
            case .tradition: annotation.tradition = annotation.tradition ?? body
            }
        }
        return annotation
    }

    /// Every range in `raw` where a section's label opens a line, including the colon and
    /// any markdown around it.
    ///
    /// Tolerant of three things the model does unbidden: bolding the label
    /// (`**PLAIN SENSE:**`), putting it in a heading (`## PLAIN SENSE:`), and dropping the
    /// colon. Not tolerant of case, because the labels are given in capitals and a
    /// lower-case `context` is a word that appears in ordinary prose.
    ///
    /// `THE TRADITION` is searched before `CONTEXT` would be a problem only if one
    /// contained the other; none does, so the search order in `parseSections` is the enum
    /// order and the results are sorted by position afterwards.
    private static func markers(_ section: Prompts.Section, in raw: String)
        -> [Range<String.Index>]
    {
        // First spelling that appears at all wins, and `Section.spellings` puts the
        // longest first so `THE TRADITION` is tried before `TRADITION`.
        for spelling in section.spellings {
            let hits = markers(spelling, in: raw)
            if !hits.isEmpty { return hits }
        }
        return []
    }

    /// Every range in `raw` where one spelling of a label opens a line.
    private static func markers(_ spelling: String, in raw: String)
        -> [Range<String.Index>]
    {
        var found: [Range<String.Index>] = []
        var searchFrom = raw.startIndex

        while let hit = raw.range(of: spelling, range: searchFrom ..< raw.endIndex) {
            searchFrom = hit.upperBound

            // The label has to open a line, or the word "CONTEXT" inside a sentence would
            // split the annotation in half — and, worse, the real `CONTEXT:` label after
            // it would never be looked for. That second failure is why this scans past a
            // rejected occurrence rather than giving up on the first.
            let before = raw[raw.startIndex ..< hit.lowerBound]
            let tail = before.reversed().prefix { $0 == "*" || $0 == "#" || $0 == " " }
            guard before.count == tail.count || before.dropLast(tail.count).last == "\n"
            else { continue }

            var end = hit.upperBound
            while end < raw.endIndex, raw[end] == "*" || raw[end] == ":" || raw[end] == " " {
                end = raw.index(after: end)
            }
            found.append(raw.index(hit.lowerBound, offsetBy: -tail.count) ..< end)
        }
        return found
    }

    private static func tidy(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
