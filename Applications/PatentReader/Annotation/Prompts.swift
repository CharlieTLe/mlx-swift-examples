// Copyright © 2026 Apple Inc.

import Foundation
import MLXLMCommon

/// Every prompt string the app sends, and the sampling presets that go with them.
///
/// `version` is bumped whenever any string here changes. Cached output records the
/// version it was generated under, so a bump invalidates rather than silently mixing
/// yesterday's text with today's prompts. `SelfTest.goldenPromptRender` compares one
/// assembled prompt against a checked-in string, so a change that was not deliberate
/// shows up as a diff before it ships — and a change that *was* deliberate means
/// regenerating that string alongside the bump.
///
/// The discipline is `ShakespeareReader/Annotation/Prompts.swift`'s, carried over
/// wholesale, and it is worth saying why it survives a change of subject. That file's
/// version history is twenty entries of "this rule was added, this rule was measured
/// inert and taken back out" — a record of what a 4B model does and does not attend to,
/// most of which is about instruction-following rather than about Shakespeare. Three of
/// its findings are load-bearing here from version 1 rather than being rediscovered:
///
/// - **Rules at the end bind; rules in the instructions do not.** Measured there by
///   accident, twice: the same rule stated in the system instructions was ignored and
///   the same rule stated as the request's last line was obeyed. So the citation
///   contract is the last thing in the request, not part of the system block.
/// - **A prohibition is cheap to satisfy without changing behaviour.** Three
///   enumerated bans there each produced compliance with the letter and a fresh
///   expression of the same defect. So the citation rule is stated positively — cite
///   from this list — with one prohibition, rather than as a list of things not to do.
/// - **A floor makes the model leave the passage to meet it.** "Gloss one to three
///   words" made it go shopping outside the selection. So nothing here requires a
///   citation count, and "the passages do not answer this" is an explicitly permitted
///   answer.
enum Prompts {

    /// Bump on any change to a string in this file.
    ///
    /// 1: initial. Blocks ordered patent-invariant first (`PATENTS IN SCOPE`, the
    /// independent claims) then the question and the retrieved passages, so a per-library
    /// prefix cache becomes possible later without rewriting anything. The citation
    /// contract is the closing line.
    static let version = 1

    // MARK: - Answering

    static let answererInstructions = """
        You answer questions about patents for a reader who is looking at the documents \
        with you. Plain modern English, concrete, no hedging and no lecturing. You are \
        not a lawyer and you are not giving advice; you are reading the text closely and \
        saying what it says.

        You get the question and a set of passages retrieved from the patents. Those \
        passages are all you know. They were found by a search, so they may be \
        incomplete and they may include something irrelevant — say so when that is what \
        you see, rather than answering around it.

        Rules:
        - No headings, no bullets, no preamble. The length is set at the end.
        - Answer the question that was asked, first sentence.
        - Distinguish what the patent *describes* from what it *claims*. The description \
        is what the inventors wrote down; the claims are what they own. A question about \
        what a patent covers is a question about the claims.
        - Quote at most a dozen words at a time, and put nothing in quotation marks that \
        is not printed in the passages you were given.
        - Where a passage uses a term of art — comprising, consisting of, means for, \
        said — read it as the patent uses it rather than as ordinary English, and say so \
        in a clause if it matters to the answer.
        - Reference numerals belong to the figures. If a passage says "the heat sink \
        100", write "the heat sink (100)" the first time and just the name afterwards.
        - Hold one reading to the end. Before each sentence, check it against what you \
        have already written: if two claims cannot both be true, keep the one the \
        passages support and cut the other.
        - Present tense. No summary of what you were given, and no closing moral.
        """

    /// The assembled request.
    ///
    /// Ordered **patent-invariant sections first**, then the question, then the
    /// passages, then the contract. Two reasons for that order, and they point the same
    /// way: the scope and the claims are the same for every question about a library, so
    /// putting them first is what would make a prefix cache possible later
    /// (`ChatSession(cache:state:)`); and the contract is last because the last thing
    /// read before writing is the thing that binds.
    static func answerRequest(_ context: AnswerContext) -> String {
        var blocks: [String] = []

        blocks.append(
            (["PATENTS IN SCOPE:"]
                + context.entries.map { "- \($0.key.display) — \($0.title)" })
                .joined(separator: "\n"))

        for entry in context.entries where !entry.independentClaims.isEmpty {
            let claims = entry.independentClaims.map { claim in
                "claim \(claim.number): \(claim.fullText)"
            }
            let heading =
                context.isCrossPatent
                ? "INDEPENDENT CLAIMS of \(entry.key.display):" : "INDEPENDENT CLAIMS:"
            blocks.append(([heading] + claims).joined(separator: "\n"))
        }

        blocks.append("QUESTION: \(context.question)")

        // Each passage headed by the exact string the model must echo. Handing it the
        // citation in the form the citation takes is what makes a mis-cite visibly a
        // mis-copy rather than a translation error, and it is the same move
        // `Prompts.render` makes next door with speaker headings.
        let passages = context.passages.map { "\($0.label)\n\($0.text)" }
        blocks.append(
            (["RETRIEVED PASSAGES — these are the only things you may cite:"] + passages)
                .joined(separator: "\n\n"))

        blocks.append(closing(context))
        return blocks.joined(separator: "\n\n")
    }

    /// The request's last line: the last thing the model reads before it writes.
    ///
    /// Everything above it is a thousand tokens of patent prose, and the instructions
    /// are further back than that. The citation contract lives here for the reason
    /// version 18 of the Shakespeare prompt records: the same rule in the instructions
    /// was violated on four consecutive graded items and the same rule at the end was
    /// obeyed.
    ///
    /// Stated positively — cite from this list — with exactly one prohibition, because
    /// enumerated bans have three times produced compliance with the letter and the same
    /// defect in a new costume. And "the passages do not answer this" is named as a
    /// permitted answer, because otherwise the only way to satisfy a citation
    /// requirement on a question the corpus cannot answer is to invent a citation.
    private static func closing(_ context: AnswerContext) -> String {
        let form =
            context.isCrossPatent
            ? "Write a citation exactly as it is headed above, including the patent: "
                + "[0042] of US 10,123,456 B2, or claim 7 of US 10,123,456 B2."
            : "Write a citation exactly as it is headed above: [0042], or claim 7."

        return """
            Answer in 60-140 words. Every claim you make carries a citation, placed \
            immediately after the clause it supports rather than at the end. \(form) \
            Cite only from the passages above — a paragraph that is not in that list \
            does not exist for this answer. If those passages do not answer the \
            question, say so in one sentence and cite nothing; that is a better answer \
            than a cited guess.
            """
    }

    /// A follow-up the reader tapped, on the same session.
    static func followUpRequest(_ question: String) -> String {
        """
        \(question)

        Same rules: 60-140 words, a citation on every claim, only from the passages you \
        were given. Do not repeat the earlier answer or reuse its phrases. If this asks \
        for something the passages do not cover, say which part and stop.
        """
    }

    /// Turn 2: the numbered list of questions to offer next.
    ///
    /// Kept from ShakespeareReader because "People also ask" is as good an idea here as
    /// there, and because a reader who has just been told what a patent claims has an
    /// obvious next question they will not have phrased yet. The out-of-scope rule is
    /// carried over verbatim in substance: that turn is where the worst single output of
    /// the Shakespeare run appeared, because the annotator's rules do not reach a
    /// separate turn and nothing there forbade invention.
    static let questionSuggestionRequest = """
        Now propose up to four questions a reader would ask next about these same \
        patents.

        Rules:
        - Each one must be answerable from the passages above. Before you write a \
        question, check that the thing it asks about is in one of them.
        - Never invent. No claim number you have not seen, no paragraph you were not \
        given, no other patent.
        - Four to twelve words each. Do not ask anything you just answered.
        - Vary them: what a claim covers, how a part works, what a term means here, what \
        the description says that the claims do not.
        - Output three or four numbered lines and nothing else. Three the passages can \
        answer are better than four where the fourth reaches outside them.
        """

    static let questionRetry =
        "Try again: output exactly four numbered lines and nothing else."

    // MARK: - Follow-up parsing

    /// Turns the model's numbered list into tappable questions.
    ///
    /// Ported from ShakespeareReader essentially unchanged, and it should be: every
    /// allowance in it exists for a way a Qwen3 model has been *seen* to break "output
    /// exactly four numbered lines and nothing else", and none of those ways is about
    /// the subject matter. The one edit is the interrogative whitelist, which gains
    /// `does`/`do` weight nowhere and loses nothing — patents attract "what", "which"
    /// and "does" questions exactly as verse does.
    enum FollowUps {
        static func parse(_ raw: String, asked: Set<String> = [], limit: Int = 4)
            -> [String]
        {
            // Built per call rather than held in a `static let`: `Regex` is not
            // `Sendable`, and a numbered list is at most a handful of lines. Tolerates a
            // bullet before the number, and `.`, `)`, `]`, `:` or `-` after it.
            let line = /^\s*(?:[-*•]\s*)?(\d{1,2})\s*[.)\]:‑-]\s*(.+?)\s*$/

            var questions: [String] = []
            var seen = asked

            for text in raw.split(whereSeparator: \.isNewline) {
                guard let match = try? line.wholeMatch(in: text) else { continue }

                var question = unwrapped(
                    String(match.2)
                        .replacingOccurrences(of: "**", with: "")
                        .trimmingCharacters(in: .whitespaces))

                // A stray preamble line ("Here are four questions:") never matches the
                // number pattern; these bounds catch the other end, a numbered line that
                // is actually a paragraph.
                guard question.count >= 3, question.count <= 120 else { continue }

                if !question.hasSuffix("?") {
                    // Not every numbered line is a question. Appending a bare "?" to a
                    // declarative sentence produced rows like "It uses a phase change
                    // material.?" — so the shape of a question is required rather than
                    // costumed on.
                    guard looksInterrogative(question) else { continue }
                    while let last = question.last, ".!,;:".contains(last) {
                        question.removeLast()
                    }
                    question += "?"
                }

                let key = normalized(question)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                questions.append(question)
                if questions.count == limit { break }
            }
            return questions
        }

        /// Strips one pair of wrapping quotes, and only a matching pair.
        ///
        /// Trimming quote characters from each end independently cannot tell packaging
        /// from content: on `"internal matrix" — what is it made of?` it removes the
        /// opening quote and strands the closing one mid-row. A quote at one end only is
        /// part of the question — and a question that opens by quoting a claim term is
        /// exactly what the prompt asks for, so the naive version was aimed at the rows
        /// most likely to be good ones.
        private static func unwrapped(_ text: String) -> String {
            let pairs: [(Character, Character)] = [
                ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"),
            ]
            guard text.count >= 2, let first = text.first, let last = text.last,
                pairs.contains(where: { $0.0 == first && $0.1 == last })
            else { return text }
            return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        }

        /// Dedupe key: case and punctuation are not a difference worth showing the
        /// reader two rows for.
        static func normalized(_ question: String) -> String {
            question.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }

        /// Whether an item with no question mark still reads as a question.
        ///
        /// Deliberately a whitelist of openings rather than anything cleverer: the cost
        /// of rejecting a real question is one fewer row, and the cost of accepting a
        /// statement is a row that lies about being a question.
        private static let interrogatives: Set<String> = [
            "what", "why", "how", "who", "whom", "whose", "when", "where", "which",
            "is", "are", "was", "were", "does", "do", "did", "can", "could", "should",
            "would", "will", "has", "have", "had", "in", "at",
        ]

        static func looksInterrogative(_ question: String) -> Bool {
            guard
                let first = question.lowercased()
                    .split(whereSeparator: { !$0.isLetter }).first
            else { return false }
            return interrogatives.contains(String(first))
        }
    }

    // MARK: - Sampling

    /// Carried as a value rather than as mutable globals so `--greedy` is a different
    /// `SamplingPresets` and not a process-wide mutation that Swift 6 would rightly
    /// complain about.
    struct SamplingPresets: Sendable {
        var answer: GenerateParameters
        var followUp: GenerateParameters

        /// Qwen3's own recommendation for non-thinking mode.
        ///
        /// Not cooled, and that is a decision with evidence behind it rather than a
        /// default left alone. ShakespeareReader cut these to 0.5 for one version to
        /// suppress corrupted tokens, and reverted: the artifact reproduced at
        /// temperature 0, so it was quantization and not sampling, while the colder
        /// distribution made *wrong* output read more confidently. Hedging tokens are
        /// low-probability, so cooling suppresses exactly the uncertainty a wrong answer
        /// ought to show — which matters more here than there, because a confident wrong
        /// answer about a claim's scope is the failure this whole app is built to make
        /// checkable.
        ///
        /// `maxTokens` is the only field that differs between turns, which matters:
        /// mutating `kvCache`, `maxKVSize` or `kvBits` on a live session throws
        /// `kvCacheConfigurationChanged`.
        static let recommended = SamplingPresets(
            answer: GenerateParameters(
                maxTokens: 400, temperature: 0.7, topP: 0.8, topK: 20),
            followUp: GenerateParameters(
                maxTokens: 140, temperature: 0.7, topP: 0.8, topK: 20))

        /// `--greedy`, for prompt A/B work: two runs of the same prompt are
        /// byte-identical, so a wording change is the only variable. The seed is inert at
        /// `temperature: 0` (argmax has no RNG) and set only so the intent is legible.
        static let greedy: SamplingPresets = {
            var presets = recommended
            for keyPath in [\SamplingPresets.answer, \SamplingPresets.followUp] {
                presets[keyPath: keyPath].temperature = 0
                presets[keyPath: keyPath].seed = 0
            }
            return presets
        }()
    }
}
