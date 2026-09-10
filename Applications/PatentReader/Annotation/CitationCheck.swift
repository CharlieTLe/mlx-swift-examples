// Copyright © 2026 Apple Inc.

import Foundation

/// Checks the model's citations against two sets the app already has.
///
/// The direct descendant of `QuoteCheck`, and it keeps that file's doctrine word for
/// word: **it reports and it does not strip.** A bad citation is evidence about a prompt,
/// and deleting it before anyone sees it spends the signal to tidy the symptom.
///
/// What it adds is a third state, and the distinction is the point. `QuoteCheck` asks one
/// question — is this quotation in the passage — and there are two answers. A citation
/// has two different ways of being wrong, they mean different things, and collapsing
/// them would throw away the more interesting one.
///
/// Model-free, network-free, and microseconds: a set membership and a dictionary lookup.
/// It runs at commit time inside `CitationScanner`, so a citation is never rendered in an
/// unknown state.
enum CitationCheck {

    enum Verdict: Sendable, Equatable, Hashable {
        /// The target exists **and** was in the retrieved set. It becomes a numbered
        /// footnote marker, and the office's own marker is not printed — see
        /// `AnswerDisplay`.
        case supported

        /// The target exists, and the model was never shown it.
        ///
        /// Rendered as **plain text, not a link**, and that is the considered middle
        /// position rather than a hedge. The paragraph is real, so striking it through
        /// would be the app calling the model a liar about something true. But the model
        /// did not read it — it produced the number from somewhere else — so the
        /// *connection* between the claim and the paragraph is invented, and making it
        /// clickable would launder that: a reader who clicks and lands on a real
        /// paragraph has been shown a citation the app just endorsed by making it work.
        ///
        /// This is also the most diagnostically interesting verdict, because it is the
        /// one that says the model is reaching outside what it was given rather than
        /// hallucinating freely.
        case unretrieved

        /// No such paragraph or claim in the library. Struck through, still legible.
        case nonexistent

        var isClickable: Bool { self == .supported }
    }

    /// The verdict for one citation.
    ///
    /// The two lookups are asymmetric on purpose. Membership of the retrieved set is
    /// exact — it is the very set that was rendered into the prompt. Existence is
    /// checked against the *library*, not against the open document, because a
    /// cross-patent citation to a patent the reader has imported is a real paragraph
    /// even though it is not on screen.
    static func verdict(
        for target: CitationTarget,
        retrieved: Set<CitationTarget>,
        library: [PatentKey: Patent]
    ) -> Verdict {
        if retrieved.contains(target) { return .supported }
        return exists(target, in: library) ? .unretrieved : .nonexistent
    }

    static func exists(_ target: CitationTarget, in library: [PatentKey: Patent]) -> Bool {
        guard let patent = library[target.patent] else { return false }
        switch target {
        case .paragraph(let key):
            // Paragraph 0 is the abstract's synthetic address — see `Chunker`. It is not
            // a paragraph of the document, so a citation to `[0000]` that was not
            // retrieved is a number the model made up, not the abstract.
            return key.number > 0 && patent.paragraph(numbered: key.number) != nil
        case .claim(let key):
            return patent.claim(numbered: key.number) != nil
        }
    }

    /// A count per verdict, for the diagnostics strip.
    ///
    /// The counters belong in the same strip as `QuoteCheck`'s unsupported quotations
    /// and are as loud, because between them they are this app's primary signal about
    /// prompt quality — and the residue they *cannot* see is worth stating in the same
    /// breath. A real, retrieved paragraph cited for a claim it does not make comes back
    /// `.supported` and always will. No string comparison reaches that, and the UI
    /// should not imply otherwise: a footnote is a promise that the model was shown
    /// this paragraph, never that the paragraph says what the sentence claims.
    static func tally(_ runs: [AnswerRun]) -> [Verdict: [String]] {
        var out: [Verdict: [String]] = [:]
        for case .citation(let citation) in runs {
            out[citation.verdict, default: []].append(citation.literal)
        }
        return out
    }
}
