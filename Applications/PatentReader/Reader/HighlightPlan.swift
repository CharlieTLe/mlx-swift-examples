// Copyright © 2026 Apple Inc.

import Foundation

/// How a passage is marked on the document, and why.
///
/// Three roles rather than one, because "the model was shown this", "the model cited this"
/// and "you just clicked this" are three different facts a reader needs at once. An answer
/// that paints all three the same colour says only that *something* happened here.
///
/// `Comparable` by strength, which is what makes `HighlightPlan`'s precedence a `max` rather
/// than a chain of `if`s.
enum HighlightRole: Int, Comparable, Hashable, Sendable {
    /// One of the eight or so passages retrieval put in the prompt. The palest mark:
    /// deliberately quieter than a find hit, because "the model was shown this" is weaker
    /// evidence than "you searched for this".
    case retrieved = 0
    /// The model cited it, and the citation checked out. Solid.
    case cited = 1
    /// The chip the reader just clicked, or the paragraph they just asked for by number.
    /// The accent colour, echoing what `FlashHighlight` used to do to a row.
    case focused = 2

    static func < (lhs: HighlightRole, rhs: HighlightRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The passage the reader was last sent to, and a reason that is different every time.
///
/// The `UUID` is `FlashHighlight`'s trick, kept for `FlashHighlight`'s reason: clicking the
/// same chip twice has to move the reader twice. A bare `CitationTarget` would be "no change"
/// the second time, and the reader would click and watch nothing happen.
struct PassageFocus: Equatable, Sendable {
    let target: CitationTarget

    /// Something to land on *inside* the passage, or `nil` to land on the passage.
    ///
    /// One caller: a reference numeral. Clicking `130` in an answer means "show me where the
    /// internal matrix is introduced", and the app's answer to that is the first paragraph
    /// mentioning it — but a paragraph is a dozen lines, and putting the reader on the
    /// paragraph leaves them to find the numeral by eye. Narrowing inside the passage's own
    /// bracket, rather than searching the document for `130` and taking the first hit, is
    /// what keeps the pure "first paragraph that mentions it" rule as the thing being
    /// answered.
    let refinement: String?

    let id: UUID

    init(_ target: CitationTarget, refining refinement: String? = nil) {
        self.target = target
        self.refinement = refinement
        self.id = UUID()
    }
}

/// What to paint on the open document: every passage that has a role, and where the reader
/// is being sent.
///
/// Pure — no PDFKit, no view — so `--selftest` asserts the precedence and, more importantly,
/// the three exclusions, which are the part that would otherwise be a judgement call written
/// once inside a view body and never checked again. `PatentPDFMarks` turns this into
/// annotations; `Equatable` is what lets it diff one plan against the last and touch only
/// what changed.
struct HighlightPlan: Equatable, Sendable {

    /// Every passage to mark, and how. Never contains a target outside the open patent.
    var roles: [CitationTarget: HighlightRole] = [:]

    /// Where to scroll, and the reason. `nil` means leave the reader where they are.
    var focus: PassageFocus?

    static let empty = HighlightPlan()

    var isEmpty: Bool { roles.isEmpty && focus == nil }

    /// The plan for one open patent, given what retrieval found, what the answer said, and
    /// where the reader was last sent.
    ///
    /// ## The three exclusions, each of which is a claim about honesty
    ///
    /// - **Front matter is dropped.** `ParagraphKey(number: 0)` is `Chunker`'s address for
    ///   the title and abstract joined, which is a string this app assembled and which
    ///   appears in no document. Retrieval hits it constantly — "what is this patent about"
    ///   is the commonest question anyone asks — so this is the ordinary case rather than a
    ///   guard against a bug.
    ///
    /// - **Another patent's passages are dropped.** Retrieval is library-wide and an answer
    ///   routinely cites three patents; only one is on screen. Marking is per document.
    ///
    /// - **A citation whose verdict is not `.supported` gets no mark.** This is the same
    ///   argument `CitationCheck.unretrieved` already makes about not being clickable, one
    ///   step further on: the paragraph is real, but the model was never shown it, so the
    ///   *connection* is invented — and painting it on the office's own document would be
    ///   the app endorsing that connection in the most authoritative place it has. A
    ///   `.nonexistent` citation has nothing to paint on at all.
    ///
    /// Retrieved passages come in as `[CitationTarget]` rather than `[RetrievedChunk]`
    /// because several chunks share one target — see `Chunker.windows` — and what is marked
    /// is the passage, once.
    static func make(
        for patent: PatentKey,
        retrieved: [CitationTarget],
        runs: [AnswerRun],
        focus: PassageFocus?
    ) -> HighlightPlan {
        var plan = HighlightPlan()

        func note(_ target: CitationTarget, _ role: HighlightRole) {
            guard target.patent == patent, !isFrontMatter(target) else { return }
            plan.roles[target] = max(plan.roles[target] ?? role, role)
        }

        for target in retrieved { note(target, .retrieved) }
        for case .citation(let citation) in runs where citation.verdict == .supported {
            note(citation.target, .cited)
        }
        if let focus {
            note(focus.target, .focused)
            // Kept even when the target was excluded above, so the caller can still report
            // that a jump was asked for. Nothing scrolls to a passage in another patent —
            // `ContentView` switches documents first — and nothing scrolls to front matter,
            // which the map has no anchor for.
            plan.focus = focus
        }
        return plan
    }

    /// `Chunker`'s synthetic title-and-abstract address.
    ///
    /// Not private: the diagnostics that report on what could not be located have to make
    /// the same exclusion, and "the abstract could not be found in the PDF" would be a
    /// failure the app invented for itself.
    static func isFrontMatter(_ target: CitationTarget) -> Bool {
        if case .paragraph(let key) = target { return key.number == 0 }
        return false
    }
}
