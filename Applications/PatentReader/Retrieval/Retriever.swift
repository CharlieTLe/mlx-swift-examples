// Copyright © 2026 Apple Inc.

import Foundation

/// One chunk that came back from a search, and why.
struct RetrievedChunk: Sendable, Identifiable {
    let chunk: Chunk
    /// Cosine similarity against the query, or `nil` where the dense leg was not run —
    /// on the Simulator, or before the embedder has loaded.
    let denseScore: Float?
    let denseRank: Int?
    let lexicalScore: Double?
    let lexicalRank: Int?
    /// The reciprocal-rank-fusion score the ordering is by.
    let fusedScore: Double

    var id: String { "\(chunk.target.slug)#\(chunk.window)" }
}

/// Finding the paragraphs a question is about.
///
/// ## Why this file exists at all, when the one it replaces argued the opposite
///
/// `PassageContext.swift` in ShakespeareReader opens: *"No embeddings: the act / scene /
/// speaker hierarchy is a better index than a vector store here, and it is exact."* That
/// is right, and it stays right — but it is right for a reason that does not survive the
/// move, and the reason is worth stating because it is easy to read the inversion as a
/// reversal.
///
/// **There, the reader selects the passage.** The app is never asked to find anything;
/// it is handed a range of lines and asked to explain them. The hierarchy is the better
/// index because the index's whole job is to *describe* what was already pointed at, and
/// exactness is free when nothing is being searched for.
///
/// **Here, the reader asks a question and does not know where the answer is.** That is
/// the product. A patent's hierarchy is just as real and just as exact — patent →
/// section → paragraph — and completely useless for it: "Detailed Description, paragraph
/// 47" says nothing about whether paragraph 47 is about the thing that was asked.
/// Sections are conventional boilerplate, paragraph numbers are ordinal, and unlike a
/// play there is no speaker, no scene and no setting — nothing in the structure
/// co-varies with meaning. So the index has to be over content, and over content there
/// is no exact index, only a good one.
///
/// The exact index still exists. It is what citations resolve against, and it is what
/// `CitationCheck` is able to be certain with. It simply is not what finds the passage.
///
/// And the inexactness is labelled all the way through to the prompt, which is the
/// discipline `onStage` follows in the file this replaces: `[0042]` in an answer is not
/// a claim that paragraph 42 is the best paragraph, only that the model was shown it and
/// said this about it.
@MainActor
enum Retriever {

    /// How many chunks the model is handed.
    ///
    /// Eight, which after collapsing windows is usually six or seven distinct
    /// paragraphs. Patent paragraphs run long, so eight of them plus the independent
    /// claims lands the prompt around 2,000-3,000 tokens — two to three times
    /// ShakespeareReader's measured 526-1,023, and the first thing to shed if time to
    /// first token disappoints.
    static let defaultLimit = 8

    /// A hard ceiling on retrieved text, in words, whichever binds first.
    ///
    /// A count alone is not a budget: eight windowed paragraphs of 250 words is 2,000
    /// words and eight abstracts is 900. A chunk that would overflow is *dropped* rather
    /// than truncated, because a truncated paragraph the model then quotes from produces
    /// a quotation the check cannot verdict honestly.
    static let wordBudget = 1_800

    /// The constant in reciprocal rank fusion, `1 / (k + rank)`.
    ///
    /// 60 is the value the method was published with, and the reason to fuse ranks
    /// rather than blend scores is that the two legs' scores are not commensurable —
    /// cosine similarity lives in `[-1, 1]` and BM25 is unbounded and corpus-dependent,
    /// so any weighted sum needs a tuning constant per library. Ranks need none.
    private static let fusionConstant = 60.0

    /// Ranks the library's chunks against `question`.
    ///
    /// - Parameter queryVector: the embedded question, or `nil` to run the lexical leg
    ///   alone. `nil` is a real mode and not a degradation to apologise for: it is what
    ///   the Simulator gets, where MLX has no Metal device, and it is what a question
    ///   asked during a first import gets. BM25 answers reference-numeral and
    ///   term-of-art questions well on its own, so the app stays useful rather than
    ///   refusing.
    static func retrieve(
        question: String,
        queryVector: [Float]?,
        index: PatentIndex,
        scope: Set<PatentKey>? = nil,
        limit: Int = defaultLimit
    ) -> [RetrievedChunk] {
        let candidates = index.chunks.enumerated().filter { _, chunk in
            scope.map { $0.contains(chunk.target.patent) } ?? true
        }
        guard !candidates.isEmpty else { return [] }

        var denseRank: [Int: Int] = [:]
        var denseScore: [Int: Float] = [:]
        if let queryVector, !queryVector.isEmpty {
            let scored =
                candidates
                .map { ($0.offset, VectorOperations.dotProduct(queryVector, $0.element.vector)) }
                .sorted { $0.1 > $1.1 }
            for (rank, entry) in scored.enumerated() {
                denseRank[entry.0] = rank
                denseScore[entry.0] = entry.1
            }
        }

        var lexicalRank: [Int: Int] = [:]
        var lexicalScore: [Int: Double] = [:]
        let allowed = Set(candidates.map(\.offset))
        for (rank, entry) in index.lexical.scores(for: question)
            .filter({ allowed.contains($0.chunk) }).enumerated()
        {
            lexicalRank[entry.chunk] = rank
            lexicalScore[entry.chunk] = entry.score
        }

        var fused: [RetrievedChunk] = []
        for (offset, chunk) in candidates {
            var score = 0.0
            if let rank = denseRank[offset] { score += 1 / (fusionConstant + Double(rank)) }
            if let rank = lexicalRank[offset] { score += 1 / (fusionConstant + Double(rank)) }
            guard score > 0 else { continue }
            fused.append(
                RetrievedChunk(
                    chunk: chunk.chunk,
                    denseScore: denseScore[offset], denseRank: denseRank[offset],
                    lexicalScore: lexicalScore[offset], lexicalRank: lexicalRank[offset],
                    fusedScore: score))
        }

        fused.sort { $0.fusedScore > $1.fusedScore }
        return trim(collapseWindows(fused), limit: limit)
    }

    /// One entry per citable target, keeping its best-scoring window.
    ///
    /// This is where the windowing of long paragraphs is undone. Retrieval needed the
    /// granularity; the model must not see it, because two windows of `[0042]` in the
    /// prompt would be one paragraph shown twice under one citation, and the reader
    /// would click a chip that lands on a paragraph they have already read half of.
    private static func collapseWindows(_ chunks: [RetrievedChunk]) -> [RetrievedChunk] {
        var seen: Set<CitationTarget> = []
        return chunks.filter { seen.insert($0.chunk.target).inserted }
    }

    private static func trim(_ chunks: [RetrievedChunk], limit: Int) -> [RetrievedChunk] {
        var out: [RetrievedChunk] = []
        var words = 0
        for chunk in chunks {
            guard out.count < limit else { break }
            let length = chunk.chunk.wordCount
            guard words + length <= wordBudget else { continue }
            out.append(chunk)
            words += length
        }
        return out
    }
}
