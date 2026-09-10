// Copyright © 2026 Apple Inc.

import CryptoKit
import Foundation

/// Everything the model is told about a question.
///
/// The counterpart of `PassageContext` next door, and the differences between them are
/// the differences between the two products. That one is assembled deterministically
/// from a play's own structure, because the reader had already pointed at the passage.
/// This one is assembled from a *search*, because the reader has not — see `Retriever`,
/// which carries the argument.
///
/// The consequence for this type is that it has to carry the retrieved set as data, not
/// just as text: `retrieved` is what `CitationCheck` tests a citation against, and the
/// distinction between "this paragraph exists" and "this paragraph was shown to the
/// model" is only knowable here.
struct AnswerContext: Sendable {

    /// Why this context was assembled, which is what decides whether the independent
    /// claims ride along and what the model is asked to do with the passages.
    ///
    /// Two purposes because there are two ways a reader points at a passage in this app,
    /// and `PassageContext` next door is the reminder that they are not the same act. A
    /// question is answered from a *search*, so the model needs the patent's scope beside
    /// the hits. A summary is written from a selection, so the reader has already said
    /// what the subject is and anything else in the prompt is the app talking over them.
    ///
    /// `String`-backed because the raw value is hashed into `digest` and a case's ordinal
    /// is not a stable thing to key a cache on.
    enum Purpose: String, Sendable, Hashable {
        case question
        case summary
    }

    /// One passage as the prompt will render it.
    struct Passage: Sendable, Hashable {
        let target: CitationTarget
        /// The exact string the model is told to cite this as, and the exact string it
        /// is shown. One value rather than two so the two cannot drift: the id the model
        /// must echo is the id it was given.
        let label: String
        let text: String
    }

    /// One patent in view, for the scope block.
    struct Entry: Sendable, Hashable {
        let key: PatentKey
        let title: String
        let numbering: Numbering
        /// The independent claims, which are the patent's actual scope. Handed over
        /// unconditionally rather than left to retrieval, because a question about an
        /// invention answered only from the description is answering about the
        /// disclosure while the reader is asking about what is claimed — and those come
        /// apart routinely.
        let independentClaims: [Claim]
    }

    var purpose: Purpose
    var question: String
    var entries: [Entry]
    var passages: [Passage]
    /// Every target the model was shown, which is what `.unretrieved` is decided
    /// against.
    var retrieved: Set<CitationTarget>
    /// Whether citations have to name their patent. One patent in view means a bare
    /// `[0042]` is unambiguous and the prompt says so; several means it is not.
    var isCrossPatent: Bool
    /// Whether the dense leg ran. `false` means the answer was written from keyword
    /// matches alone — on the Simulator, or before an import finished — and the pane
    /// says so rather than letting a thinner search look like a normal one.
    var isLexicalOnly: Bool

    /// SHA-256 of the purpose, the question and the retrieved text. What the answer cache
    /// keys on: the same question over a different retrieved set is a different answer,
    /// and serving the old one would attach citations to passages the model was not shown.
    ///
    /// The purpose is in here because it changes the prompt rather than the passages, and
    /// nothing else in the digest would notice. A reader who summarizes `[0042]` and then
    /// types the summary instruction as a question about the same paragraph would
    /// otherwise be served one as the other — a small hole, and free to close.
    var digest: String {
        var hasher = SHA256()
        hasher.update(data: Data(purpose.rawValue.utf8))
        hasher.update(data: Data(question.utf8))
        for passage in passages {
            hasher.update(data: Data(passage.label.utf8))
            hasher.update(data: Data(passage.text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the context from a set of retrieved chunks.
    ///
    /// - Parameter limitPatents: at most this many distinct patents. Past three the
    ///   model starts conflating them and the answer stops being about anything;
    ///   dropping the lowest-ranked patent's chunks entirely is better than an answer
    ///   that blends four inventions.
    static func build(
        question: String,
        retrieved chunks: [RetrievedChunk],
        library: [Patent],
        isLexicalOnly: Bool,
        limitPatents: Int = 3
    ) -> AnswerContext? {
        guard !chunks.isEmpty else { return nil }

        var ranked: [PatentKey] = []
        for chunk in chunks where !ranked.contains(chunk.chunk.target.patent) {
            ranked.append(chunk.chunk.target.patent)
        }
        let scope = Set(ranked.prefix(limitPatents))
        let kept = chunks.filter { scope.contains($0.chunk.target.patent) }
        guard !kept.isEmpty else { return nil }

        let byKey = Dictionary(uniqueKeysWithValues: library.map { ($0.key, $0) })
        let entries = ranked.prefix(limitPatents).compactMap { key -> Entry? in
            guard let patent = byKey[key] else { return nil }
            return Entry(
                key: key, title: patent.title, numbering: patent.numbering,
                independentClaims: patent.claims.filter(\.isIndependent))
        }
        guard !entries.isEmpty else { return nil }

        let crossPatent = entries.count > 1
        let passages = kept.map { chunk -> Passage in
            let numbering = byKey[chunk.chunk.target.patent]?.numbering ?? .printed
            return Passage(
                target: chunk.chunk.target,
                label: label(chunk.chunk.target, numbering: numbering, qualified: crossPatent),
                text: chunk.chunk.text)
        }

        // The independent claims belong in here as much as the passages do, and leaving
        // them out was this type contradicting the comment on its own field. `retrieved` is
        // "every target the model was shown", `Prompts` renders an INDEPENDENT CLAIMS block
        // carrying each one's `fullText`, and `Entry.independentClaims` exists precisely so
        // that a question about scope is answered against what is claimed rather than only
        // against what was retrieved. A model that then cites `claim 1` is citing something
        // it read, in the block this app chose to hand it — so verdicting that `.unretrieved`
        // told the reader "the model was never shown this" about a passage the app put in
        // front of it, and took the chip away. The failure lands hardest on exactly the
        // question the claims block was added for: ask what a patent covers and every
        // citation in the answer is a dead one.
        let shownClaims = entries.flatMap { entry in
            entry.independentClaims.map {
                CitationTarget.claim(ClaimKey(patent: entry.key, number: $0.number))
            }
        }

        return AnswerContext(
            purpose: .question,
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            entries: entries,
            passages: passages,
            retrieved: Set(passages.map(\.target)).union(shownClaims),
            isCrossPatent: crossPatent,
            isLexicalOnly: isLexicalOnly)
    }

    // MARK: - A selection

    /// How many passages a summary carries, at most.
    ///
    /// Twelve because of the measured budget rather than by feel: eight retrieved chunks
    /// mean 1,723 prompt tokens on average, so twelve passages sits in the same band the
    /// answer path has already been profiled in. The cap exists because a selection has no
    /// natural size — a drag with the scrollbar can cover four hundred paragraphs, and that
    /// prompt is one nothing can prefill in a time a reader will wait for.
    static let maximumPassages = 12

    /// The `question` a summary carries.
    ///
    /// Never shown to the model — `Prompts.summaryRequest` renders no `QUESTION:` line,
    /// because the reader asked by pointing rather than by typing, and a question invented
    /// on their behalf would be the app putting words in their mouth. It is here because
    /// `question` is part of `digest`.
    static let summaryQuestion = "Summarize the selected passages."

    /// The passages the reader pointed at, as the prompt will carry them.
    ///
    /// **What is summarized is the passages the selection covers, not the characters
    /// dragged**, and that is deliberately the opposite of `Citation.quotation`'s rule.
    /// The two actions are different: a quotation must be exactly what was selected or it
    /// is not a quotation, while a summary must be *citable* or this app cannot check a
    /// word of it. `Passage` pairs each text with the label the model is told to cite it
    /// as, and `CitationCheck` verdicts a citation by testing its target against
    /// `retrieved` — so a model handed raw PDFKit characters has been shown text that
    /// addresses nothing, and every citation in the summary comes back `.unretrieved`,
    /// unclickable and unmarked. That is the machinery correctly reporting that it cannot
    /// verify the summary, which is a strange thing to build on purpose.
    ///
    /// The parse is also the only version of the document that is reliably *in order*. A
    /// drag down one column of a two-column grant picks up the other in text-stream order,
    /// which the README accepts for a paste — the reader can see the scramble — and must
    /// not accept here, because a summary of scrambled prose is confidently wrong and
    /// reads perfectly.
    ///
    /// What it costs is that a half-sentence selection is rounded up to whole passages, so
    /// the caller names the range it actually summarized rather than letting the reader
    /// assume otherwise.
    ///
    /// Three rules fall out of walking `patent.rows`, which is why it is walked rather than
    /// `targets` being mapped: the passages come out in **document order** whatever order
    /// the selection's ends arrived in, a target appears once so a long drag that crossed
    /// one paragraph twice cannot carry it twice, and a target this patent does not contain
    /// is dropped rather than fabricated.
    static func selection(
        _ targets: [CitationTarget], in patent: Patent, maximum: Int = maximumPassages
    ) -> AnswerContext? {
        let wanted = Set(targets)
        guard !wanted.isEmpty else { return nil }

        var passages: [Passage] = []
        for row in patent.rows {
            guard let target = row.target(in: patent.key), wanted.contains(target) else {
                continue
            }
            passages.append(
                Passage(
                    target: target,
                    label: label(target, numbering: patent.numbering, qualified: false),
                    // `copyText` rather than `plainText`, for the reason it exists: a claim
                    // keeps its printed number and its elements keep their own lines, which
                    // is how the office sets a claim and how a reader reads one.
                    text: row.copyText))
            if passages.count == maximum { break }
        }
        guard !passages.isEmpty else { return nil }

        return AnswerContext(
            purpose: .summary,
            question: summaryQuestion,
            // One entry, with **no independent claims**. The block they feed exists so that
            // a question about scope is answered against what is claimed, and `retrieved`
            // unions them in so a model that cites `claim 1` from it keeps its link. Neither
            // applies to a summary: the reader named the subject, so a summary that reached
            // into the claims would be answering a question nobody asked, and painting a
            // solid mark on a claim they did not select would be this app endorsing that in
            // the most authoritative place it has. It also saves the ~500 tokens the block
            // costs on every summary.
            entries: [
                Entry(
                    key: patent.key, title: patent.title, numbering: patent.numbering,
                    independentClaims: [])
            ],
            passages: passages,
            retrieved: Set(passages.map(\.target)),
            isCrossPatent: false,
            // No search ran, so no search was degraded. The pane must not say "keyword
            // search only" about a summary — it would be describing a search that never
            // happened, and a summary needs no embedder on any platform.
            isLexicalOnly: false)
    }

    /// The citation label a passage is shown under, which is also the one the model is
    /// told to write.
    ///
    /// The abstract is `paragraph 0`, a number no office issues — see `Chunker` — and it
    /// is labelled "the abstract" rather than `[0000]`, because a model shown `[0000]`
    /// will cite `[0000]` and a reader will look for it.
    static func label(
        _ target: CitationTarget, numbering: Numbering, qualified: Bool
    ) -> String {
        let base: String
        switch target {
        case .paragraph(let key) where key.number == 0:
            base = "the abstract"
        case .paragraph, .claim:
            base = Citation.chipLabel(target, numbering: numbering)
        }
        return qualified ? "\(base) of \(target.patent.display)" : base
    }
}
