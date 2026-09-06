// Copyright © 2026 Apple Inc.

import Foundation

/// One run of a streamed answer: prose, or a citation.
enum AnswerRun: Equatable, Sendable, Identifiable {
    case text(String)
    case citation(Citation)

    /// A citation that has been located in the text, checked, and given a label.
    struct Citation: Equatable, Sendable, Hashable {
        let target: CitationTarget
        /// Exactly the characters the model wrote, so a chip never silently reformats
        /// what it is standing in for.
        let literal: String
        let verdict: CitationCheck.Verdict
    }

    /// Stable across appends, because the view's `ForEach` must not re-identify a run
    /// that has only grown. Committed runs are never rewritten (see `CitationScanner`),
    /// so an index is a stable identity — and it is the only one available, since two
    /// citations to `[0042]` in one answer are genuinely two runs.
    var id: String {
        switch self {
        case .text(let text): "t\(text.hashValue)"
        case .citation(let citation): "c\(citation.literal)\(citation.hashValue)"
        }
    }
}

/// Splits a streamed answer into prose and citations, as it arrives.
///
/// ## The problem, which is entirely about partials
///
/// Generation arrives token by token, so `[0042]` can reach this as `[00`, then `42`,
/// then `]`. Two obvious approaches both fail:
///
/// - Render eagerly and a half-emitted `[00` becomes a chip that then turns into a
///   different chip. Chips flickering into existence half-formed is the whole difference
///   between "polished" and "a demo", and it is the kind of thing nobody can unsee.
/// - Render nothing until the answer finishes and streaming buys nothing.
///
/// So the scanner holds back a **tail**: the suffix that might still become a citation,
/// and nothing more. Everything before the tail is *committed* and is never rewritten,
/// which is what lets the view's `ForEach` keep stable identities and stops SwiftUI
/// re-laying out the whole answer once per decoded token — the same concern
/// `AnnotationPaneView.follow` documents about scrolling.
///
/// A partial in the tail renders as plain text for the thirty milliseconds until the
/// rest arrives. That is the right failure: literal characters briefly, never a wrong
/// chip.
struct CitationScanner {

    /// Committed runs, in order. Append-only apart from coalescing consecutive text.
    private(set) var runs: [AnswerRun] = []

    /// The unresolved suffix. Rendered as plain text by the view, never as a chip.
    private(set) var tail: String = ""

    private let context: AnswerContext
    private let library: [PatentKey: Patent]

    init(context: AnswerContext, library: [Patent]) {
        self.context = context
        self.library = Dictionary(uniqueKeysWithValues: library.map { ($0.key, $0) })
    }

    /// The longest a candidate may be before it is given up on and committed as text.
    ///
    /// Long enough for the longest form the grammar accepts — `claim 12 of US
    /// 10,123,456 B2` is 27 characters — and short enough that a stray `[` in a
    /// paragraph of prose does not swallow a sentence. Patents do use brackets, so
    /// giving up has to be a normal outcome rather than an error.
    private static let maximumCandidate = 40

    mutating func consume(_ chunk: String) {
        scan(tail + chunk, isFinal: false)
    }

    /// Flushes the tail. Called when generation ends.
    ///
    /// Not simply "commit the tail as text": the tail routinely holds a **complete**
    /// citation that was being held only because something might still follow it. `as set
    /// out in [0022]` ends with a whole citation whose qualifier could have been the next
    /// character, so mid-stream it is correctly withheld — and flushing it as prose would
    /// mean the last citation of every answer rendered as plain text. So the tail is
    /// re-scanned once with "nothing more is coming", and only what is still incomplete
    /// after that becomes text.
    mutating func finish() {
        guard !tail.isEmpty else { return }
        let remaining = tail
        tail = ""
        scan(remaining, isFinal: true)
        if !tail.isEmpty {
            commit(text: tail)
            tail = ""
        }
    }

    private mutating func scan(_ input: String, isFinal: Bool) {
        var buffer = input
        tail = ""

        while !buffer.isEmpty {
            guard
                let start = buffer.firstIndex(where: {
                    $0 == "[" || $0 == "¶" || $0 == "c" || $0 == "C"
                })
            else {
                commit(text: buffer)
                return
            }

            let prefix = String(buffer[buffer.startIndex ..< start])
            let candidate = String(buffer[start...])

            switch match(candidate, isFinal: isFinal) {
            case .matched(let literal, let target):
                commit(text: prefix)
                commit(target: target, literal: literal)
                buffer = String(candidate.dropFirst(literal.count))
            case .partial:
                // Might still become a citation. Hold everything from here.
                commit(text: prefix)
                tail = candidate
                return
            case .no:
                // Not a citation and never will be. Commit the opening character as text
                // and carry on from the next one, so a `[` in prose costs one iteration
                // rather than the rest of the buffer.
                commit(text: prefix + String(candidate.prefix(1)))
                buffer = String(candidate.dropFirst())
            }
        }
    }

    private mutating func commit(text: String) {
        guard !text.isEmpty else { return }
        // Coalesced, so a stream of single characters does not become a thousand runs.
        if case .text(let existing) = runs.last {
            runs[runs.count - 1] = .text(existing + text)
        } else {
            runs.append(.text(text))
        }
    }

    private mutating func commit(target: CitationTarget, literal: String) {
        // The verdict is decided here, at commit time, rather than at the end. It can
        // be: the retrieved set is known before generation starts, and the library is
        // known before that. So a chip is never rendered in an unknown state and then
        // corrected, which would be the flicker this whole file exists to avoid, one
        // level up.
        let verdict = CitationCheck.verdict(
            for: target, retrieved: context.retrieved, library: library)
        runs.append(
            .citation(AnswerRun.Citation(target: target, literal: literal, verdict: verdict)))
    }

    // MARK: - The grammar

    private enum Match {
        /// A whole citation: the literal text it occupies, and what it points at.
        case matched(literal: String, target: CitationTarget)
        /// Could still become one if more characters arrive.
        case partial
        case no
    }

    /// Whether `candidate` starts with a citation.
    ///
    /// Four accepted forms, and no more, because every additional form is another way
    /// for the scanner and the prompt to disagree about what a citation looks like:
    ///
    /// - `[0042]` — the printed paragraph form the prompt shows and asks for.
    /// - `¶42` — the synthesized form, for a patent whose source carried no printed
    ///   numbers. Shown in the prompt for those patents, so it has to be readable back.
    /// - `claim 7`
    /// - either of the above followed by ` of US 10,123,456 B2`, which is the form the
    ///   prompt asks for when more than one patent is in scope.
    ///
    /// **A match that reaches the end of the buffer is not a match yet**, unless nothing
    /// more is coming. This is the rule the whole streaming design turns on and it is
    /// easy to miss, because the failure it prevents looks nothing like a parsing bug:
    /// fed one character at a time, `[0019] of US 10,123,456 B2` passes through the state
    /// `[0019] of US 10,123`, in which the qualifier is a perfectly valid match against a
    /// *six-digit* serial. Committing there produces a chip pointing at patent 10,123,
    /// which does not exist, and leaves `,456 B2` as prose. So a complete match whose end
    /// is the buffer's end is reported `.partial` and reconsidered when more arrives.
    ///
    /// An unqualified citation resolves against the **primary** patent, which is the one
    /// that contributed the most retrieved passages. That is a guess, and it is a guess
    /// the check downstream can catch: a bare `[0042]` meant for the other patent
    /// resolves to a paragraph that exists but was not retrieved, and comes out
    /// `.unretrieved` rather than as a link to the wrong document.
    private func match(_ candidate: String, isFinal: Bool) -> Match {
        guard let (literal, target) = matchLocator(candidate) else {
            return isPartialLocator(candidate) && !isFinal ? .partial : .no
        }

        let rest = String(candidate.dropFirst(literal.count))
        if rest.isEmpty, !isFinal {
            // `claim 7` may still be `claim 71`, and anything may still be qualified.
            return .partial
        }

        switch matchQualifier(rest, isFinal: isFinal) {
        case .matched(let suffix, let patent):
            return .matched(literal: literal + suffix, target: retarget(target, to: patent))
        case .partial:
            return candidate.count > Self.maximumCandidate
                ? .matched(literal: literal, target: target) : .partial
        case .no:
            return .matched(literal: literal, target: target)
        }
    }

    private func matchLocator(_ candidate: String) -> (String, CitationTarget)? {
        let primary = self.primary
        if let match = try? /^\[(\d{1,5})\]/.prefixMatch(in: candidate),
            let number = Int(match.1)
        {
            return (
                String(match.0),
                .paragraph(ParagraphKey(patent: primary, number: number))
            )
        }
        if let match = try? /^¶\s?(\d{1,5})/.prefixMatch(in: candidate),
            let number = Int(match.1)
        {
            return (
                String(match.0),
                .paragraph(ParagraphKey(patent: primary, number: number))
            )
        }
        if let match = try? /^[Cc]laim\s+(\d{1,3})/.prefixMatch(in: candidate),
            let number = Int(match.1)
        {
            return (String(match.0), .claim(ClaimKey(patent: primary, number: number)))
        }
        return nil
    }

    /// Whether `candidate` is a prefix of something `matchLocator` would accept.
    ///
    /// Written out rather than derived, because "is this a prefix of a regex" is not a
    /// question a `Regex` answers. The cost of getting it wrong in one direction is a
    /// chip that flickers, and in the other a tail that never flushes — so the list is
    /// explicit and `SelfTest.citationScanner` feeds the scanner one character at a time
    /// to prove every intermediate state is in it.
    private func isPartialLocator(_ candidate: String) -> Bool {
        if candidate.count > Self.maximumCandidate { return false }
        if candidate.first == "[" {
            return candidate.dropFirst().allSatisfy(\.isNumber)
        }
        if candidate.first == "¶" {
            return candidate.dropFirst().allSatisfy { $0.isNumber || $0 == " " }
        }
        let lowered = candidate.lowercased()
        if "claim".hasPrefix(lowered) { return true }
        if lowered.hasPrefix("claim") {
            return lowered.dropFirst(5).allSatisfy { $0.isNumber || $0 == " " }
        }
        return false
    }

    private enum QualifierMatch {
        case matched(String, PatentKey)
        case partial
        case no
    }

    /// ` of US 10,123,456 B2`.
    private func matchQualifier(_ rest: String, isFinal: Bool) -> QualifierMatch {
        guard !rest.isEmpty else { return isFinal ? .no : .partial }
        let pattern = /^\s+of\s+([A-Z]{2})\s?([\d,]{6,13})\s?([A-Z]\d?)?/
        if let match = try? pattern.prefixMatch(in: rest) {
            // The same end-of-buffer rule as `match(_:isFinal:)`: a serial that runs to
            // the end of what has arrived may have more digits behind it.
            if !isFinal, match.0.count == rest.count { return .partial }
            let serial = String(match.2).filter(\.isNumber)
            let key = PatentKey(
                country: String(match.1), serial: serial,
                kind: match.3.map(String.init))
            // Resolve against the library so `US 10,123,456` with no kind code finds
            // `US10123456B2`: a reader's citation rarely carries the kind code and the
            // model's copies it inconsistently.
            let resolved =
                library.keys.first {
                    $0.country == key.country && $0.serial == key.serial
                } ?? key
            return .matched(String(match.0), resolved)
        }
        guard !isFinal else { return .no }
        // Could it still grow into one? Only if what is there is a prefix of " of US…".
        let template = " of "
        if rest.count < template.count, template.hasPrefix(rest) { return .partial }
        if rest.hasPrefix(template) || rest.hasPrefix(" of") {
            return rest.count < 24 ? .partial : .no
        }
        return .no
    }

    private func retarget(_ target: CitationTarget, to patent: PatentKey) -> CitationTarget {
        switch target {
        case .paragraph(let key):
            .paragraph(ParagraphKey(patent: patent, number: key.number))
        case .claim(let key):
            .claim(ClaimKey(patent: patent, number: key.number))
        }
    }

    /// Which patent an unqualified citation belongs to: the one that contributed the
    /// most retrieved passages, ties broken by the highest-ranked passage.
    private var primary: PatentKey {
        var counts: [PatentKey: Int] = [:]
        for passage in context.passages { counts[passage.target.patent, default: 0] += 1 }
        let best = counts.max { lhs, rhs in
            lhs.value == rhs.value
                ? position(of: lhs.key) > position(of: rhs.key) : lhs.value < rhs.value
        }
        return best?.key ?? context.entries.first?.key
            ?? PatentKey(country: "US", serial: "0", kind: nil)
    }

    private func position(of key: PatentKey) -> Int {
        context.passages.firstIndex { $0.target.patent == key } ?? Int.max
    }
}
