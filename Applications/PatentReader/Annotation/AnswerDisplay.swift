// Copyright © 2026 Apple Inc.

import Foundation

/// One span of a rendered answer: text, and the citation it belongs to.
struct AnswerSpan: Equatable, Sendable {
    let text: String
    /// The citation this span belongs to, or `nil` for prose that cites nothing.
    ///
    /// A span with a `.supported` citation is the **footnote marker** — its text is exactly
    /// `"[3]"` and it is the thing the reader clicks. A span with any other verdict is the
    /// model's own literal, printed unchanged and not a link.
    let citation: AnswerRun.Citation?
}

/// Turns the scanner's runs into what the reader actually sees: **a numbered footnote marker
/// where the citation was, and the office's own marker not printed**.
///
/// ## Why not the office's marker
///
/// An answer used to read *"…including stress and smooth extensions. ¶279 of US 11,028,179
/// B2"*, with only those last characters clickable. Where a patent arrived with no printed
/// paragraph numbers the importer counts from 1, so `¶279` is **this app's own count** — the
/// office's PDF prints nothing of the sort. The reader was handed an address that exists
/// nowhere but in this process, as the sole handle on the passage. A footnote number claims
/// no authority it does not have: `[1]` is plainly this document's own count, and nobody
/// copies it into a brief believing the grant prints it.
///
/// ## Why a marker and not an underline
///
/// The link lived on the prose for a while — the cited clause underlined, the marker not
/// printed at all. An underline can show one thing a marker cannot: the **extent** of what a
/// citation covers, which is a real property and the one the reader is owed. In practice it
/// showed it worst exactly where it mattered. With a citation per clause an answer becomes
/// adjacent underlines end to end, and a run of underlines is indistinguishable from one long
/// one, so the *boundary* — where this citation's reach stops and the next begins — is the
/// part that disappeared. A bracket is a boundary and nothing else, and that is what was
/// actually being read for.
///
/// ## Why this is a separate, pure function
///
/// Nothing here touches `CitationScanner`, and that is what buys the streaming behaviour for
/// free: prose still commits and renders the instant it arrives, and the marker appears when
/// the citation that anchors it commits a few tokens later. Nothing is withheld and no
/// committed run is rewritten. Being a `[AnswerRun] -> [AnswerSpan]` transform and nothing
/// else also makes the rule testable in `--selftest`, which is model-free and PDFKit-free —
/// and this is neither.
///
/// ## What is *not* renumbered
///
/// Only `.supported` gives up its literal. `.unretrieved` and `.nonexistent` keep theirs
/// exactly as written, because those are the two verdicts `CitationCheck`'s doctrine reports
/// rather than hides, and a verdict that is not a link has nothing else to be. The two
/// notations stay apart on sight: an office marker is four digits and zero-padded and grey,
/// a footnote counts from 1 and is the only tinted, clickable thing in the answer.
enum AnswerDisplay {

    /// How a footnote marker is spelled. One function, so a superscript `¹` or `[fn 1]` is a
    /// one-line change rather than a hunt through the passes and the tests.
    static func marker(_ number: Int) -> String { "[\(number)]" }

    /// The runs and the unresolved tail, as spans, in order.
    static func spans(_ runs: [AnswerRun], tail: String) -> [AnswerSpan] {
        var spans = assemble(runs, tail: tail)
        removeEmptyPairs(&spans)
        spaceMarkers(&spans)
        return tidy(spans)
    }

    /// A `.supported` span: the marker itself, and the only clickable thing in an answer.
    private static func isMarker(_ span: AnswerSpan) -> Bool {
        span.citation?.verdict == .supported
    }

    // MARK: - The passes
    //
    // Ordered, and the order is the whole content: an `"([0019])"` whose brackets are removed
    // leaves `"…one piece "` with a trailing space, and that space is what the spacing pass
    // then has to collapse to one. Doing either earlier would miss the case the other creates.

    /// Prose into pending, citations into spans. Whitespace and empty pairs are left alone.
    ///
    /// The numbers count **distinct passages**, not citations: the table is keyed by
    /// `CitationTarget` and filled in first-seen order, so ¶19 cited three times is `[1]` all
    /// three times. That is what makes the numbers worth reading — two `[1]`s in an answer say
    /// the two clauses rest on the same passage, which is a fact about the answer.
    private static func assemble(_ runs: [AnswerRun], tail: String) -> [AnswerSpan] {
        var spans: [AnswerSpan] = []
        var pending = ""
        var numbers: [CitationTarget: Int] = [:]

        func flush() {
            guard !pending.isEmpty else { return }
            spans.append(AnswerSpan(text: pending, citation: nil))
            pending = ""
        }

        for run in runs {
            switch run {
            case .text(let text):
                pending += text
            case .citation(let citation):
                flush()
                guard citation.verdict == .supported else {
                    // Reported, never hidden, and never a link.
                    spans.append(AnswerSpan(text: citation.literal, citation: citation))
                    continue
                }
                let number = numbers[citation.target] ?? (numbers.count + 1)
                numbers[citation.target] = number
                spans.append(AnswerSpan(text: marker(number), citation: citation))
            }
        }

        flush()
        // The tail is always plain. See `CitationScanner`: it is the suffix that might still
        // become a citation, and rendering it as anything else is how a half-emitted `[00`
        // becomes a link that then changes into a different one.
        if !tail.isEmpty {
            spans.append(AnswerSpan(text: tail, citation: nil))
        }
        return spans
    }

    /// `"…one piece ([0019])."` is a spelling the model writes often enough that the `"()"`
    /// left behind by dropping the office's marker would be a visible artefact. Matched across
    /// the seam that marker left — the pair now straddles the footnote — and nowhere else: a
    /// `"()"` inside one run is the model's own and stays.
    ///
    /// A marker can never be mistaken for one half of the pair. Its text starts `"["` and ends
    /// `"]"`, so it is never an opener on the left nor a closer on the right, and neither is a
    /// suspect literal for the same reason.
    private static func removeEmptyPairs(_ spans: inout [AnswerSpan]) {
        for index in spans.indices where isMarker(spans[index]) {
            guard index > 0, index + 1 < spans.count else { continue }
            let left = spans[index - 1]
            let right = spans[index + 1]
            guard let opener = left.text.last, let closer = right.text.first,
                (opener == "(" && closer == ")") || (opener == "[" && closer == "]")
            else { continue }
            spans[index - 1] = AnswerSpan(
                text: String(left.text.dropLast()), citation: left.citation)
            spans[index + 1] = AnswerSpan(
                text: String(right.text.dropFirst()), citation: right.citation)
        }
    }

    /// **Exactly one space before every marker, and whatever the model wrote after it.**
    ///
    /// `"…extensions. "` + `"[1]"` becomes `"…extensions. [1]"`, and `"…one piece ("` +
    /// `"[1]"` + `")."`, once the pair is gone, becomes `"…one piece [1]."` — the marker sits
    /// against the prose it closes rather than floating a space away from it. Three cases take
    /// no space: nothing precedes the marker, the prose before it ends in a **newline** — the
    /// model put the citation on its own line, and eating the break would move it — and a
    /// preceding citation, which gets a prose `" "` of its own rather than having its own text
    /// rewritten.
    private static func spaceMarkers(_ spans: inout [AnswerSpan]) {
        var out: [AnswerSpan] = []
        for span in spans {
            guard isMarker(span), let previous = out.last else {
                out.append(span)
                continue
            }
            guard previous.citation == nil else {
                // `"[0019][0022]"`, or a suspect literal butted against a supported one.
                out.append(AnswerSpan(text: " ", citation: nil))
                out.append(span)
                continue
            }
            var body = Substring(previous.text)
            while let last = body.last, last.isWhitespace, !last.isNewline {
                body = body.dropLast()
            }
            // Only whitespace ahead of it, and nothing before that: the answer opens with the
            // marker, so it opens flush left. `tidy` drops what is left of the prose.
            let opensTheAnswer = body.isEmpty && out.count == 1
            let separator = body.last?.isNewline == true || opensTheAnswer ? "" : " "
            out[out.count - 1] = AnswerSpan(text: String(body) + separator, citation: nil)
            out.append(span)
        }
        spans = out
    }

    /// Drops what the passes emptied and coalesces neighbouring prose, so the view walks one
    /// span per thing the reader can see.
    private static func tidy(_ spans: [AnswerSpan]) -> [AnswerSpan] {
        var out: [AnswerSpan] = []
        for span in spans where !span.text.isEmpty {
            if span.citation == nil, let last = out.last, last.citation == nil {
                out[out.count - 1] = AnswerSpan(text: last.text + span.text, citation: nil)
            } else {
                out.append(span)
            }
        }
        return out
    }
}
