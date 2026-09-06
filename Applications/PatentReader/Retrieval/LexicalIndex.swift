// Copyright © 2026 Apple Inc.

import Foundation

/// BM25 over the same chunks the dense index holds.
///
/// **Why a lexical leg is not optional here.** Dense retrieval alone fumbles exactly the
/// queries a patent library attracts, and it fumbles them in a way that looks like
/// working:
///
/// - **Reference numerals.** "What is 214?" A 768-dimensional embedding trained on web
///   text puts `214` and `216` at almost the same point, because in web text they are
///   both just small numbers. BM25 treats them as distinct rare terms with high inverse
///   document frequency and lands on the paragraph that introduces the part. The
///   fixtures carry 104 and 140 distinct numerals; this is the *normal* query here, not
///   an exotic one.
/// - **Terms of art with legal force.** `comprising`, `consisting essentially of` and
///   `consisting of` are three different claim scopes. An embedding calls them
///   synonyms. In a patent that difference is the entire question.
/// - **Coined vocabulary.** Every patent invents its own nouns — "the internal matrix",
///   "hour-glass shaped pins" — which is precisely the out-of-distribution case dense
///   retrieval is worst at and lexical retrieval is best at.
///
/// It is a *mitigation* and not a fix for the deeper problem, which is that
/// nomic-embed-text-v1.5 was trained on general prose and claim language is deliberately
/// unnatural. If retrieval is visibly poor, the next lever is a domain embedder, not
/// more weight on this leg.
struct LexicalIndex: Sendable {

    /// One indexed chunk's term counts.
    private struct Entry: Sendable {
        let chunk: Int
        let counts: [String: Int]
        let length: Int
    }

    private var entries: [Entry] = []
    private var documentFrequency: [String: Int] = [:]
    private var averageLength: Double = 0

    /// Standard BM25 parameters. `k1` controls how fast term frequency saturates and
    /// `b` how much document length is normalized away; 1.2 and 0.75 are the values the
    /// method was published with and there is nothing about patents that argues for
    /// moving them. Named rather than inlined so that if somebody does tune them, they
    /// tune them once.
    private static let k1 = 1.2
    private static let b = 0.75

    init(chunks: [Chunk]) {
        for (index, chunk) in chunks.enumerated() {
            let tokens = Self.tokenize(chunk.embeddingText)
            guard !tokens.isEmpty else { continue }
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            for term in counts.keys { documentFrequency[term, default: 0] += 1 }
            entries.append(Entry(chunk: index, counts: counts, length: tokens.count))
        }
        averageLength =
            entries.isEmpty
            ? 0 : Double(entries.reduce(0) { $0 + $1.length }) / Double(entries.count)
    }

    /// BM25 scores for every chunk that matches at least one query term, chunk index to
    /// score, highest first.
    func scores(for query: String) -> [(chunk: Int, score: Double)] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty, !entries.isEmpty else { return [] }

        let total = Double(entries.count)
        var idf: [String: Double] = [:]
        for term in Set(terms) {
            let frequency = Double(documentFrequency[term] ?? 0)
            guard frequency > 0 else { continue }
            // Robertson-Sparck Jones IDF with the usual +0.5 smoothing, floored at zero:
            // a term in more than half the documents otherwise scores negative and
            // *penalises* the documents containing it, which for a one-patent library —
            // where "heat" really is in half the paragraphs — would rank the relevant
            // ones last.
            idf[term] = max(0, log((total - frequency + 0.5) / (frequency + 0.5) + 1))
        }
        guard !idf.isEmpty else { return [] }

        var scored: [(Int, Double)] = []
        for entry in entries {
            var score = 0.0
            let normalization =
                Self.k1
                * (1 - Self.b + Self.b * Double(entry.length) / max(1, averageLength))
            for (term, weight) in idf {
                guard let count = entry.counts[term] else { continue }
                let frequency = Double(count)
                score += weight * (frequency * (Self.k1 + 1)) / (frequency + normalization)
            }
            if score > 0 { scored.append((entry.chunk, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map { (chunk: $0.0, score: $0.1) }
    }

    /// Lowercased alphanumeric runs, with run-ins kept whole.
    ///
    /// Three departures from the obvious, each for a shape patents are full of:
    ///
    /// - **Alphanumeric run-ins are one token.** `US10123456B2`, `H05K7`, `2A` and
    ///   `FIG` survive as themselves. Splitting them would turn a patent number into the
    ///   two useless tokens `us` and `10123456`.
    /// - **A bare number is indexed twice**, as itself and as `#214`. A reference
    ///   numeral and a quantity look identical, and the sentinel form lets a query that
    ///   is *only* a number — "what is 214" — match the numeral without being diluted by
    ///   every "214" that is a temperature. Both forms are emitted at index time and at
    ///   query time, so the effect is a doubled weight on numerals rather than a
    ///   separate field.
    /// - **No stemming.** Patentese stems badly and the losses are exactly the
    ///   distinctions that matter: `coupled` and `coupling` are not the same claim term,
    ///   and `comprising` and `comprises` carry different grammatical roles in a claim.
    ///   A stemmer here would erase the vocabulary this leg exists to protect.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            let token = current.lowercased()
            tokens.append(token)
            if token.allSatisfy(\.isNumber) { tokens.append("#" + token) }
            current = ""
        }

        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
