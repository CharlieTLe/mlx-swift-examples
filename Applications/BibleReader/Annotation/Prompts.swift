// Copyright © 2026 Apple Inc.

import Foundation
import MLXLMCommon

/// Every string sent to the model.
///
/// One file so a prompt change is one diff and one `version` bump, and so the reasoning
/// behind a rule sits next to the rule.
enum Prompts {

    /// Bump on any change to a string that reaches turn 1, which invalidates the
    /// annotation cache (`AnnotationCache.passage(for:digest:)` compares it).
    ///
    /// **Version 1, and starting at 1 rather than inheriting ShakespeareReader's 20 is
    /// the point.** These prompts share that file's machinery and almost none of its
    /// text, because the requirement changed.
    ///
    /// The one decision most likely to be second-guessed, recorded here so it is not
    /// re-litigated from scratch: **the four-section output deliberately breaks
    /// ShakespeareReader's house style.**
    ///
    /// That app forbids headings and produces one flowing paragraph, and it is right to.
    /// A gloss on a line of verse is one thought. But this app owes the reader four
    /// distinct kinds of thing — the plain sense, the historical and literary context,
    /// cross-references, and the Catholic interpretive tradition — and that is a
    /// different product, not the same product with more in it.
    ///
    /// The graded history in ShakespeareReader's own `Prompts.swift` is the argument. It
    /// establishes, repeatedly and by measurement, that a 4B model drops rules that sit
    /// far from the end of the prompt: the paragraph count was violated on four
    /// consecutive graded items while it lived in the instructions and obeyed as soon as
    /// it moved to the closing line. A single paragraph asked to cover four bases has
    /// four rules competing for that one position, and it will silently lose one or two.
    /// **Silently** is the operative word — a missing cross-reference section reads
    /// exactly like a passage with no cross-references.
    ///
    /// Four fixed markers make the omission visible instead. `Annotation.parseSections`
    /// splits on them, tolerating missing and reordered sections, and the pane renders an
    /// absent section as absent rather than padding it. That last part is
    /// `wordBudget`'s own lesson restated: a floor buys padding, and the padding is
    /// wrong.
    ///
    /// **2** — the `SEE ALSO` instruction was rewritten. Version 1 described the shape as
    /// `each "Reference — why it connects"`, and over the thirteen benchmark passages the
    /// model twice echoed that phrase back literally: Genesis 3:14-15 produced
    /// `Genesis 3:14-15 — why it connects.` A template a model can copy verbatim is a
    /// template it will copy verbatim, so the shape is now described rather than
    /// exhibited. The same edit says explicitly what to do when no references were
    /// supplied, because four of the thirteen printed the label with nothing under it.
    static let version = 2

    // MARK: - Annotation

    /// The four sections, as the model must spell them.
    ///
    /// Upper case and colon-terminated, which is the shape the model is most reliable at
    /// reproducing, and the same shape as the block labels above them in the request —
    /// so the format is demonstrated by the prompt rather than only described by it.
    enum Section: String, CaseIterable, Sendable {
        case plainSense = "PLAIN SENSE"
        case context = "CONTEXT"
        case seeAlso = "SEE ALSO"
        case tradition = "THE TRADITION"

        var title: String {
            switch self {
            case .plainSense: "Plain sense"
            case .context: "Context"
            case .seeAlso: "See also"
            case .tradition: "The tradition"
            }
        }

        /// Other spellings of the label the parser will accept, longest first.
        ///
        /// Measured, not guessed: over the thirteen benchmark passages the model wrote
        /// `THE TRADITION` twelve times and `TRADITION` once. One in thirteen is not a
        /// prompt problem worth a rule — the label is already restated in the closing
        /// block, which is the position that binds — it is a parser problem, and the
        /// cheap fix is to accept both. The other three labels were reproduced exactly
        /// 13/13 and need none.
        ///
        /// Longest first matters: `THE TRADITION` has to be tried before `TRADITION`, or
        /// the marker range would start after the `THE ` and leave it dangling at the end
        /// of the previous section.
        var spellings: [String] {
            switch self {
            case .tradition: ["THE TRADITION", "TRADITION"]
            default: [rawValue]
            }
        }
    }

    static let annotatorInstructions = """
        You are annotating the Douay-Rheims Bible (Challoner revision) for a Catholic \
        reader. Short, concrete, plain modern English. No hedging, no lecturing, no \
        summary of what you were given.

        You get one selected passage plus the chapter around it, and material from this \
        edition itself. Explain ONLY the selected passage. The rest is there so your \
        explanation fits where it sits.

        You write four labelled sections and nothing else. The labels and the order are \
        fixed and given at the end. Omit a section entirely if you have nothing solid \
        for it — an absent section is correct, a padded one is not.

        Rules that hold across all four:
        - Everything you say must come from what you were given: the passage, the \
        material from this edition, or the cross-references supplied. If the passage \
        turns on something you were not given, say so in one clause instead of \
        inventing it.
        - WHERE A NOTE FROM THIS EDITION IS SUPPLIED, IT IS THE AUTHORITY. Follow it \
        even where you would otherwise read the verse differently, and prefer its \
        reading to any other you know.
        - Quote at most eight words at a time, and put nothing in quotation marks that \
        you cannot see printed in front of you — never a verse that is not on the page, \
        and never another translation's wording of one that is.
        - Cite only the references you were given. Do not add scripture references of \
        your own, however apt they look.
        - Never name a Father, a council, a catechism paragraph, an encyclical or a \
        work with a number attached to it. "The Fathers read this as…" is fine; \
        "Augustine, City of God XIV.13" is not, and neither is "CCC 1213". You will be \
        wrong about the locator and no one can check it.
        - This edition uses Vulgate numbering and its own book names. Psalm numbers here \
        are usually one behind the Hebrew ones; 1 and 2 Kings are Samuel, 3 and 4 Kings \
        are Kings. Never renumber anything or offer the other system's number.
        - Present tense. No moral at the end. Do not mention these instructions, the \
        blocks you were given, or the fact that you were given them.
        """

    /// The passage and its surroundings, in labelled blocks.
    ///
    /// Ordered **chapter-invariant sections first**, then the passage window. In
    /// ShakespeareReader that ordering was a note about what a prefix cache would make
    /// possible later; here it pays much better and is the first of the three latency
    /// mitigations, because `BOOK`, `ABOUT THIS BOOK`, `CHAPTER` and `WHAT THIS CHAPTER
    /// COVERS` are constant across every selection in a chapter and a reader makes many
    /// selections per chapter.
    static func annotationRequest(_ context: PassageContext) -> String {
        var blocks: [String] = []

        var book =
            "BOOK: \(context.bookTitle) — \(context.testament.name), "
            + context.division.name
        if context.deuterocanonical {
            book += " (deuterocanonical)"
        }
        blocks.append(book)

        if let preface = context.bookPreface {
            blocks.append("ABOUT THIS BOOK: \(preface)")
        }
        blocks.append("CHAPTER: \(context.bookName) \(context.chapter)")
        if let argument = context.chapterArgument {
            blocks.append("WHAT THIS CHAPTER COVERS: \(argument)")
        }
        if let heading = context.sectionHeading {
            blocks.append("SECTION: \(heading)")
        }

        // The block the whole design hangs on. Challoner wrote 1,772 of these and they
        // are already in the corpus, so the Catholic reading of a contested verse is
        // something the model is *handed* rather than something it has to hold against
        // the Protestant commonplace its training data is made of.
        if !context.notes.isEmpty {
            let rendered = context.notes.map { note -> String in
                guard let catchword = note.catchword else { return "  - \(note.text)" }
                return "  - \"\(catchword)\": \(note.text)"
            }
            blocks.append(
                (["NOTES FROM THIS EDITION (these are the authority where they apply):"]
                    + rendered).joined(separator: "\n"))
        }

        if !context.crossReferences.isEmpty {
            let rendered = context.crossReferences.map {
                "  - \($0.label) — \"\($0.text)\""
            }
            blocks.append(
                ([
                    "CROSS-REFERENCES (already verified against this Bible — explain "
                        + "these and no others):"
                ] + rendered).joined(separator: "\n"))
        }

        blocks.append(fourSenses)

        if !context.preceding.isEmpty {
            blocks.append(
                "BEFORE\(span(context.preceding)):\n\(render(context.preceding))")
        }
        blocks.append(
            "SELECTED PASSAGE\(span(context.selected)):\n\(render(context.selected))")
        if !context.following.isEmpty {
            blocks.append("AFTER\(span(context.following)):\n\(render(context.following))")
        }

        if let moment = moment(context) {
            blocks.append(moment)
        }
        blocks.append(closing(context))
        return blocks.joined(separator: "\n\n")
    }

    /// The four senses, **defined in the prompt** rather than left to recall.
    ///
    /// This is the difference between a task a 4B model can do and one it cannot. Asked
    /// to "read the passage according to the four senses", it produces a plausible
    /// paraphrase of half-remembered definitions; handed the definitions, it applies
    /// them. The same principle as `NOTES FROM THIS EDITION` one block up, and as the
    /// cross-references carrying their target text: supply the material, ask for the
    /// reading.
    static let fourSenses = """
        THE FOUR SENSES: literal (what happened, or what the words say); allegorical \
        (what it shows about Christ and the Church); moral (how it bears on how a \
        person should live); anagogical (what it shows about the last things).
        """

    /// Where the passage sits, stated once, in facts, at the end.
    ///
    /// ShakespeareReader's `THE MOMENT` exists because a fact near the end of the prompt
    /// beats a right fact anywhere else, and it earned that place by fixing four
    /// different failures across two graded passages. The block is kept for the same
    /// reason and filled differently.
    ///
    /// **What it deliberately does not carry is a speaker.** Biblical speech is inline
    /// narrative — `And the Lord said to Abram:` — not a speech-heading grammar, so
    /// there is no `Cast` to resolve and no `OnStageTracker` to run. A heuristic tracker
    /// over 35,805 verses would be a fabrication engine, and its output would land here,
    /// in the block that exists precisely because whatever sits here wins. Its slot is
    /// taken by material that is authored and in the text: the preface, the argument and
    /// the notes, all of them further up.
    private static func moment(_ context: PassageContext) -> String? {
        var sentences: [String] = []

        let numbers = context.selected.compactMap(\.number)
        if let first = numbers.first, let last = numbers.last, context.chapterVerseCount > 0 {
            let span = first == last ? "verse \(first)" : "verses \(first) to \(last)"
            sentences.append(
                "This is \(span) of \(context.bookName) \(context.chapter), which has "
                    + "\(context.chapterVerseCount) verses.")
        }

        if !context.notes.isEmpty {
            let count = context.notes.count
            sentences.append(
                "This edition prints \(count) note\(count == 1 ? "" : "s") on "
                    + "\(count == 1 ? "it" : "these verses"), given above; "
                    + "\(count == 1 ? "it is" : "they are") the authority.")
        }

        if context.crossReferences.isEmpty {
            // Said out loud, because "no cross-references" is the state a model is most
            // likely to fill in from memory — and the deuterocanonical books, which are
            // exactly the ones a Protestant-trained model knows least, are where this
            // block will most often be empty.
            sentences.append(
                "No cross-references were supplied for this passage, so SEE ALSO has "
                    + "nothing to list and must be omitted.")
        }

        if let last = numbers.last {
            sentences.append(
                "Nothing after verse \(last) has happened yet, so do not write as if it "
                    + "had.")
        }

        guard !sentences.isEmpty else { return nil }
        return "THE MOMENT: " + sentences.joined(separator: " ")
    }

    /// How many words each section gets.
    ///
    /// `PLAIN SENSE` scales with the selection and the other two do not, which is not an
    /// oversight. The plain sense of ten verses is more to say than the plain sense of
    /// one; the book's author, audience and date are the same amount of information
    /// either way, and so is a reading of it according to the four senses.
    ///
    /// The scaling itself is ShakespeareReader's `wordBudget`, retuned. Its lesson
    /// transfers whole and is the reason the floor moves: a one-verse selection forced to
    /// reach ninety words fills the gap with invention, so the floor buys padding and the
    /// padding is wrong.
    struct Budget: Sendable, Equatable {
        var plainSense: ClosedRange<Int>
        var context: ClosedRange<Int>
        var tradition: ClosedRange<Int>
        var seeAlso: Int
    }

    static func wordBudget(verses: Int) -> Budget {
        let plainSense: ClosedRange<Int> =
            switch verses {
            case ..<3: 35 ... 70
            case ..<10: 60 ... 110
            default: 90 ... 150
            }
        return Budget(
            plainSense: plainSense, context: 30 ... 60, tradition: 30 ... 60, seeAlso: 3)
    }

    /// Where a selection stops being one the word budget was tuned on.
    ///
    /// Twenty verses rather than ShakespeareReader's thirty lines, because a
    /// Douay-Rheims verse is about three times a line of verse: twenty verses is roughly
    /// six hundred words of scripture, which is where a whole-chapter selection stops
    /// being a passage and starts being a chapter. The Decalogue at Exodus 20:1-17 sits
    /// just under it and needs nothing; Psalm 118 selected whole is far over.
    static let longSelection = 20

    /// The request's last line: the last thing the model reads before it writes.
    ///
    /// The instructions are a thousand tokens back by then and everything between them
    /// and here is scripture, so the rules the model is most likely to drop sit here
    /// rather than there. That is measured behaviour from ShakespeareReader and it is why
    /// the **section format itself** is restated in full at this position rather than
    /// only in the instructions: it is the rule whose failure is least visible.
    private static func closing(_ context: PassageContext) -> String {
        let verses = context.selected.filter { $0.kind == .verse }.count
        let budget = wordBudget(verses: verses)

        var text = """
            Write exactly these four sections, in this order, each opening with its \
            label in capitals followed by a colon. Nothing before the first label and \
            nothing after the last section.

            PLAIN SENSE: \(budget.plainSense.lowerBound)-\(budget.plainSense.upperBound) \
            words. What the selected passage says, in modern English. Put the archaic or \
            hard wording into words a reader today uses.

            CONTEXT: \(budget.context.lowerBound)-\(budget.context.upperBound) words. Who \
            wrote it and for whom, roughly when, what kind of writing it is, and where \
            this passage sits in the book.

            SEE ALSO: up to \(budget.seeAlso) lines. Each line is one of the \
            cross-references you were given, then an em dash, then what it has to do with \
            this passage in a few words of your own. Only those references — not this \
            passage's own, and none you thought of yourself. **If you were given none, \
            leave this label out altogether rather than writing it with nothing under \
            it.**

            THE TRADITION: \(budget.tradition.lowerBound)-\(budget.tradition.upperBound) \
            words. How the Church has read this passage: the four senses where they \
            apply, and what this edition's own notes say. No named works, no numbers, no \
            citations.

            Stop when you have said what the passage means — do not pad any section to \
            its upper figure, and leave a section out rather than filling it.
            """

        if verses >= longSelection {
            text += """


                The passage runs to \(verses) verses, and still gets one annotation of \
                that length: what the whole passage does, and where it turns. Do not \
                walk it verse by verse, and do not let one vivid image from the middle \
                stand in for the rest.
                """
        }
        return text
    }

    /// The verses, with their printed numbers.
    ///
    /// The number is in the render even though it is not in `Row.text` — the gutter keeps
    /// it out of the string the reader copies and the tokenizer sees, and this is the one
    /// place it has to go back in. Without it the model cannot say which verse a claim is
    /// about, and `SEE ALSO` cannot be checked against anything.
    ///
    /// A note is bracketed and labelled, so the model can tell Challoner's commentary
    /// from scripture inside the same block. That distinction costs four tokens a note
    /// and is the difference between quoting the Bible and quoting a footnote about it.
    static func render(_ verses: [PassageContext.Verse]) -> String {
        verses.map { verse in
            switch verse.kind {
            case .verse:
                guard let number = verse.number else { return "  \(verse.text)" }
                return "  \(number). \(verse.text)"
            case .sectionHeading:
                return "  [heading: \(verse.text)]"
            case .note:
                return "  [note from this edition: \(verse.text)]"
            }
        }
        .joined(separator: "\n")
    }

    private static func span(_ verses: [PassageContext.Verse]) -> String {
        let numbers = verses.compactMap(\.number)
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? " (\(first))" : " (\(first)-\(last))"
    }

    // MARK: - Follow-ups

    /// The follow-up turn carries its own copy of the no-invention rules.
    ///
    /// A separate turn does not inherit the annotator's instructions, and in
    /// ShakespeareReader this is exactly where the worst single output of its whole
    /// evaluation appeared — a question quoting verse that is in none of the 36 plays.
    /// The same surface here would be offering a reader invented scripture, which is
    /// worse, so the reference rule is restated as explicitly as the quotation one.
    static let followUpRequest = """
        Now propose up to four follow-up questions a curious reader would tap next about \
        this same passage.

        Rules:
        - Each one must be specific to this passage: name the person, image, or word it \
        is about. Before you write a question, check that every word you put in \
        quotation marks is printed in the selected passage. If it is only in the verses \
        around it, drop the question and write a different one.
        - Never invent. No verse you cannot see, no scripture reference you were not \
        given, no Father, no council, no document, no date.
        - Four to nine words each. Do not ask anything you just answered.
        - Vary them: what the words mean, what happens, how the Church has read it, how \
        it connects to what you were given.
        - Output three or four numbered lines and nothing else. Three the passage can \
        answer are better than four where the fourth is about something it does not \
        contain.
        """

    /// Sent once when the first attempt yielded fewer than two usable questions.
    /// Phrased as something a person could plausibly say, because it stays in the
    /// transcript the model sees on every later turn.
    static let followUpRetry =
        "Try again: output exactly four numbered lines and nothing else."

    /// A tapped question, plus how to answer it.
    ///
    /// One flowing answer and **not** four sections. The section format exists because
    /// four required kinds of thing compete for one position; a reader's question is one
    /// thing, and labelling a sixty-word answer would be ceremony.
    static func answerRequest(_ question: String) -> String {
        """
        \(question)

        Answer in 60-110 words, plain modern English, same voice as before. No section \
        labels — this is one answer, not the four-part annotation.

        If the question asks whether something is so, do not open with Yes or No. Say \
        what the verses actually mean first, in your own words, and only then say \
        whether that is what the question described.

        Hold one reading to the end. Before each sentence, check it against what you \
        have already written: if two claims cannot both be true, the worked-out reading \
        is the one to keep and the verdict or the closing line is what changes. Never \
        ship both.

        Where a note from this edition bears on the question, it is the authority. Quote \
        nothing you cannot see in the passage, and cite no scripture reference you were \
        not given. Name no Father, council, catechism paragraph or work — "the Fathers \
        read this as…" is fine, a work with a number attached to it is not.

        Answer every part of what was asked, and where you are not sure, say which part. \
        If the passage honestly bears more than one reading, say so, and then give the \
        one the Church has held. If the question assumes something and you are confident \
        of only half of it, give that half and say so rather than filling the shape. Do \
        not repeat your earlier annotation or reuse its phrases.
        """
    }

    /// Sent after the answer draft, on the same session, so the draft is in view.
    ///
    /// The one turn in the app that supplies an **edit channel**. A single forward pass
    /// cannot go back and fix its own second sentence; it can only continue, which is why
    /// a model told to hold one reading will sometimes quote and negate its own earlier
    /// claim instead. This gives that instruction somewhere to land. Note the first
    /// bullet: appending a correction is exactly what the model does unaided, and it is
    /// not what a revision is for.
    ///
    /// Answers only. Both turns are now withheld until they are whole, but the wait is
    /// not the same wait: a reader who has just selected a verse has an empty pane and
    /// nothing to read while the longer of the two generations runs, where a reader who
    /// has tapped a question has the annotation in front of them. A second pass on turn
    /// 1 would be paid against the one wait that is already worst.
    static let answerRevision = """
        Now revise that answer. It is above; this is your one chance to change it.

        - If two sentences contradict each other, delete the wrong one. Do not add a \
        sentence correcting yourself — take the wrong sentence out.
        - If any sentence names a Father, a council, a document, a catechism paragraph \
        or a work with a number, delete the name and the number. Keep the claim only if \
        it stands as "the Fathers read this as…".
        - If any sentence cites a scripture reference you were not given, delete the \
        reference.
        - Your earlier annotation of this passage is above too. If the answer \
        contradicts it, one of them is wrong: fix the answer to agree with whichever the \
        verses support.
        - Keep what was right, keep the length, and add no new claims.
        - Output the revised answer and nothing else. No preamble, no notes on what you \
        changed.
        """

    /// Asks for up to five so four can survive the dedupe against questions already
    /// asked.
    ///
    /// Restates the rules rather than saying "in the same style", which by this point in
    /// a transcript is gesturing at instructions eight or ten turns back.
    static let moreFollowUpsRequest = """
        Suggest up to five more questions about this same passage. Same rules: only words \
        the selected passage itself prints, and nothing invented — no verse you cannot \
        see, no reference you were not given, no Father, no council, no document. Two the \
        passage can answer are better than five that reach outside it. Do not repeat any \
        question already asked. Output only the numbered lines and nothing else.
        """

    /// A word right-clicked in the text, as a question.
    ///
    /// Phrased as a reader's own question and nothing more, because that is what it is:
    /// it goes through `ask(_:)` and `answerRequest(_:)`, which already set the length
    /// and the voice, and it is shown verbatim in the transcript as the thing that was
    /// asked.
    ///
    /// The one string in this file that owes **no `version` bump**. The rule above is
    /// about strings that change cached output, and nothing is cached from this one:
    /// `AnnotationCache` keys on turn 1, which a word question does not touch.
    static func wordQuestion(_ term: String) -> String {
        "What does “\(term)” mean here?"
    }

    /// Turns the model's numbered list into tappable questions.
    ///
    /// Ported verbatim from ShakespeareReader. It lives beside the prompt that asks for
    /// the list, because the two are one contract: every allowance here exists for a way
    /// the model has been seen to break "output exactly four numbered lines and nothing
    /// else."
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
                    // declarative sentence produces a row that lies about being one, so
                    // the shape is required rather than costumed.
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
        /// Trimming each end independently cannot tell packaging from content: on
        /// `"quintessence of dust" – what does it mean?` it removes the opening quote and
        /// leaves the closing one stranded mid-row. A quote at one end only is part of
        /// the question — and a question that opens by quoting the passage is exactly
        /// what the follow-up prompt asks for.
        private static func unwrapped(_ text: String) -> String {
            let pairs: [(Character, Character)] = [
                ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"),
            ]
            guard text.count >= 2, let first = text.first, let last = text.last,
                pairs.contains(where: { $0.0 == first && $0.1 == last })
            else { return text }
            return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        }

        /// Dedupe key: case and punctuation are not a difference worth showing the reader
        /// two rows for.
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

    /// The presets, carried as a value rather than as mutable globals so `--greedy` is a
    /// different `SamplingPresets` and not a process-wide mutation that Swift 6 would
    /// rightly complain about.
    struct SamplingPresets: Sendable {
        var commentary: GenerateParameters
        var followUp: GenerateParameters
        var answer: GenerateParameters

        /// Qwen3's own recommendation for non-thinking mode.
        ///
        /// Not cooled, and ShakespeareReader's measurement is why. Cutting the
        /// temperature to 0.5 there to suppress corrupted tokens was tried and reverted:
        /// the artifacts reproduce at `--greedy`, so they are the argmax of the 4-bit
        /// weights rather than something sampling reaches, and the colder output was more
        /// fluent and more confidently wrong. Hedging tokens are low-probability, so a
        /// colder distribution suppresses exactly the uncertainty a wrong claim ought to
        /// show — which matters more here than there, since a confidently wrong sentence
        /// about what the Church teaches is worse than a confidently wrong gloss.
        ///
        /// `commentary` gets 420 rather than ShakespeareReader's 320: four sections at
        /// their budgets come to roughly 200 words of prose plus three reference lines
        /// and four labels, and a ceiling that truncates `THE TRADITION` mid-sentence
        /// every time would look exactly like the model omitting it.
        ///
        /// `maxTokens` is the only field that differs between turns, which matters:
        /// mutating `kvCache`, `maxKVSize`, or `kvBits` on a live session throws
        /// `kvCacheConfigurationChanged`.
        static let recommended = SamplingPresets(
            commentary: GenerateParameters(
                maxTokens: 420, temperature: 0.7, topP: 0.8, topK: 20),
            followUp: GenerateParameters(
                maxTokens: 140, temperature: 0.7, topP: 0.8, topK: 20),
            answer: GenerateParameters(
                maxTokens: 260, temperature: 0.7, topP: 0.8, topK: 20))

        /// `--greedy`, for prompt A/B work: two runs of the same prompt are
        /// byte-identical, so a wording change is the only variable. The seed is inert at
        /// `temperature: 0` (argmax has no RNG) and set only so the intent is legible.
        static let greedy: SamplingPresets = {
            var presets = recommended
            for keyPath in [
                \SamplingPresets.commentary, \SamplingPresets.followUp,
                \SamplingPresets.answer,
            ] {
                presets[keyPath: keyPath].temperature = 0
                presets[keyPath: keyPath].seed = 0
            }
            return presets
        }()
    }
}
