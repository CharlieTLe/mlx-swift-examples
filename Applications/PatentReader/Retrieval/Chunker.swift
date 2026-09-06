// Copyright © 2026 Apple Inc.

import Foundation

/// One unit of text with one address: what gets embedded, and what a citation to it
/// would say.
struct Chunk: Sendable, Hashable {
    /// What this chunk cites as. Several chunks may share one target — see
    /// `Chunker.windows` — and retrieval collapses them before anything is shown.
    let target: CitationTarget
    /// Which window of an over-long paragraph this is. `0` for everything else.
    let window: Int
    /// The text as the model will see it, which is the paragraph or the claim verbatim.
    let text: String
    /// The text as the *embedder* sees it, which is not always the same thing — a
    /// dependent claim is embedded with its parents' text in front of it. Kept separate
    /// rather than embedding `text` and hoping, because the difference is the whole
    /// reason claim retrieval works, and because a prompt that showed the reader the
    /// enriched form would be citing `claim 7` and printing claims 1, 6 and 7.
    let embeddingText: String

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// Turning a patent into the units that get indexed.
///
/// **The unit is the paragraph, because that is the citable unit.** If retrieval worked
/// over half-paragraphs or over three-paragraph spans, then a chunk that scored well
/// would have no single citation, and the whole three-verdict check downstream — which
/// asks "was this paragraph in the retrieved set" — would have nothing exact to ask
/// about. Two corrections to that rule earn their place, and both preserve it.
enum Chunker {

    /// Bump when a change here alters the chunks a given patent produces. Recorded in
    /// the index file and checked on load, so a bump reindexes rather than mixing chunks
    /// from two chunkers in one search.
    static let version = 1

    /// Above this, a paragraph is windowed. 250 words is roughly 330 tokens, which is
    /// well inside the embedder's 512 and comfortably below the point where one vector
    /// stops being about any one thing.
    ///
    /// The failure this avoids is not truncation — it is dilution. A 900-word
    /// enablement paragraph averaged into one 768-dimensional vector is about
    /// everything and therefore about nothing, and it loses to a 40-word paragraph that
    /// happens to mention the query's noun once.
    static let windowWords = 250

    /// How much of the previous window each window repeats.
    ///
    /// Overlap exists so a sentence that straddles a boundary is whole in one of them.
    /// 50 words is two or three sentences of patent prose, which is the span over which
    /// a patent sentence's referent stays resolvable.
    static let overlapWords = 50

    /// Below this a paragraph is embedded with its section heading in front of it.
    ///
    /// `[0001] This application claims priority to U.S. 61/676,592.` is a real paragraph
    /// a reader may cite and a useless thing to embed: it is about nothing. Prefixing
    /// the heading gives the vector somewhere to sit without changing what the chunk
    /// *is* — `text` stays the paragraph, so the prompt and the citation are untouched.
    static let shortWords = 25

    /// Every chunk of one patent, in document order.
    static func chunks(for patent: Patent) -> [Chunk] {
        var chunks: [Chunk] = []

        // The title and the abstract, as one chunk each. "What is this patent about" is
        // the most common question anyone asks of a library, and without these it has to
        // be answered from whichever detailed-description paragraph happens to be most
        // general.
        //
        // Both are addressed as paragraph 0, which is a number no patent office issues,
        // so a citation can never collide with a real paragraph. The reader never sees
        // that number: `AnswerContext` renders these two as "the abstract" and "the
        // title", and the model is told to cite them that way.
        let front = ParagraphKey(patent: patent.key, number: 0)
        if !patent.abstract.isEmpty {
            let text = "\(patent.title). \(patent.abstract)"
            chunks.append(
                Chunk(
                    target: .paragraph(front), window: 0, text: text, embeddingText: text))
        }

        for section in patent.sections where section.isIndexable {
            for paragraph in section.paragraphs {
                let key = ParagraphKey(patent: patent.key, number: paragraph.number)
                let words = paragraph.text.split(whereSeparator: \.isWhitespace)

                if words.count < shortWords, !section.heading.isEmpty {
                    let enriched = "\(section.heading). \(paragraph.text)"
                    chunks.append(
                        Chunk(
                            target: .paragraph(key), window: 0, text: paragraph.text,
                            embeddingText: enriched))
                    continue
                }

                for (window, text) in windows(paragraph.text).enumerated() {
                    chunks.append(
                        Chunk(
                            target: .paragraph(key), window: window, text: paragraph.text,
                            embeddingText: text))
                }
            }
        }

        for claim in patent.claims {
            let key = ClaimKey(patent: patent.key, number: claim.number)
            chunks.append(
                Chunk(
                    target: .claim(key), window: 0, text: claim.fullText,
                    embeddingText: resolvedText(of: claim, in: patent)))
        }

        return chunks
    }

    /// A paragraph's overlapping windows, split at sentence boundaries.
    ///
    /// Sentence boundaries and not word boundaries, because a window that begins
    /// mid-clause embeds as a fragment — and patent sentences are long enough that the
    /// mid-clause case is the common one under a word split. One window for anything
    /// short enough, on the identical code path, so the ordinary paragraph costs nothing.
    static func windows(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > windowWords else { return [text] }

        let sentences = self.sentences(in: text)
        var out: [String] = []
        var current: [String] = []
        var count = 0

        for sentence in sentences {
            let length = sentence.split(whereSeparator: \.isWhitespace).count
            if count + length > windowWords, !current.isEmpty {
                out.append(current.joined(separator: " "))
                // Carry back whole sentences until the overlap budget is met, so the
                // next window opens on a sentence rather than in the middle of one.
                var carried: [String] = []
                var carriedWords = 0
                for previous in current.reversed() {
                    let size = previous.split(whereSeparator: \.isWhitespace).count
                    if carriedWords >= overlapWords { break }
                    carried.insert(previous, at: 0)
                    carriedWords += size
                }
                current = carried
                count = carriedWords
            }
            current.append(sentence)
            count += length
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out.isEmpty ? [text] : out
    }

    /// Sentences, by `NSString.enumerateSubstrings(options: .bySentences)`.
    ///
    /// The system tokenizer rather than a split on `. `, which patent prose defeats
    /// immediately: `FIG. 1`, `U.S. Pat. No. 6,285,999`, `approx. 0.5 mm` and `Ser. No.`
    /// all appear in the fixtures, and each one would open a spurious sentence.
    private static func sentences(in text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex, options: [.bySentences]
        ) { substring, _, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out.isEmpty ? [text] : out
    }

    /// A claim as it must be *embedded*: its parents' text, then its own.
    ///
    /// A dependent claim read alone is close to meaningless. "The method of claim 6,
    /// wherein the seal plugs comprise expansion plugs" embeds as a vector about seal
    /// plugs and nothing else — not about the method, not about additive manufacturing,
    /// not about anything the reader is likely to ask. Prepending the chain is what makes
    /// claim 7's vector be about what claim 7 actually covers.
    ///
    /// **For embedding only.** `Chunk.text` stays the claim's own words, so the prompt
    /// shows claim 7 and the citation says `claim 7`. Handing the model the resolved
    /// form would produce answers that cite claim 7 for a limitation that is in claim 1.
    ///
    /// The walk is bounded by `visited` rather than trusted to terminate: for a source
    /// with no `claim-ref`, `dependsOn` is read from prose, and prose can say
    /// "the method of claim 3" inside claim 3.
    static func resolvedText(of claim: Claim, in patent: Patent) -> String {
        var chain: [String] = []
        var visited: Set<Int> = [claim.number]
        var frontier = claim.dependsOn

        while let number = frontier.first {
            frontier.removeFirst()
            guard visited.insert(number).inserted,
                let parent = patent.claim(numbered: number)
            else { continue }
            chain.insert(parent.fullText, at: 0)
            frontier += parent.dependsOn
        }

        return (chain + [claim.fullText]).joined(separator: " ")
    }
}
