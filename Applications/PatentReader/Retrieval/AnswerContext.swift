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

    /// SHA-256 of the question and the retrieved text. What the answer cache keys on:
    /// the same question over a different retrieved set is a different answer, and
    /// serving the old one would attach citations to passages the model was not shown.
    var digest: String {
        var hasher = SHA256()
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

        return AnswerContext(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            entries: entries,
            passages: passages,
            retrieved: Set(passages.map(\.target)),
            isCrossPatent: crossPatent,
            isLexicalOnly: isLexicalOnly)
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
