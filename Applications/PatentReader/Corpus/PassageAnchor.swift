// Copyright © 2026 Apple Inc.

import Foundation

/// A passage, and the words that find it in the office's own PDF.
///
/// **This type is the answer to the objection the app used to make about itself.** Two
/// places in this codebase argued at length that a paragraph number is a fact about the
/// parsed text and that the PDF, paginated by the office's typesetting, carries no index
/// `[0042]` can be resolved against. The first half is true and the conclusion does not
/// follow: a paragraph's own opening words are an index into the document, they are already
/// in the parse, and `PDFDocument.findString` resolves one in about two milliseconds.
///
/// So this is `[0042]` → *"An electronics enclosure includes a"* → a `PDFSelection`, and it
/// is what lets a citation chip land on the passage in the document the office published
/// rather than in this app's reading of it.
struct PassageAnchor: Equatable, Sendable {
    /// What the anchor addresses — the thing a citation names.
    let target: CitationTarget

    /// The words to look for, single-spaced. Not case-folded: `findString` is asked for
    /// `.caseInsensitive` and folding here as well would only make the needle differ from
    /// the document for no gain.
    let needle: String

    /// A second thing to look for when `needle` finds nothing, or `nil` where there is
    /// nothing weaker worth trying.
    ///
    /// Only claims have one, and only because their `needle` opens with the printed number.
    /// That number is what makes a claim anchor nearly unique — see `anchors(in:)` — and it
    /// is also the one part of the needle the *document* might spell differently: a grant
    /// that sets its claim numbers in a separate text run, or glues `7.` to the first word,
    /// defeats the primary and would otherwise cost the claim its placement outright. The
    /// fallback is the same opening words with the number taken off the front.
    let fallback: String?
}

/// Turning a parsed patent into anchors, and a selected string back into a passage.
///
/// Pure, model-free and PDFKit-free, which is what lets `--selftest` assert every rule here
/// against the checked-in HTML fixtures without a PDF in the repository. The PDFKit half —
/// running these against a document and ordering what comes back — is `PatentPDFMap`.
///
/// ## Why the needles are this short
///
/// Measured, against three real patent PDFs in a library (a 163-page PCT publication, a
/// 131-page two-column US grant, a 57-page PCT application as filed). Anchoring on the
/// first **six** words of a paragraph located 97%, 97% and 98% of them. Twelve words fell to
/// about half: a long match is broken by the line wrap and the hyphenation the office's
/// typesetter put in, and `findString` matches across neither. Six is the sweet spot, and it
/// is short enough that most anchors are ambiguous — which is not a problem to be solved
/// here but the ordinary case `PassagePlacement.monotonic` exists to resolve.
enum PassageAnchors {

    /// How many opening words a paragraph is anchored on. See the type's note: measured, not
    /// chosen.
    static let paragraphWords = 6

    /// At most how many opening words a claim is anchored on, *after* its printed number.
    ///
    /// Four rather than six because the number is doing most of the work: `"7. "` occurs
    /// once or twice in a document where the six words after it occur wherever claim 7's
    /// subject is discussed. Located 113/120, 20/20 and 21/21 across the three probes.
    ///
    /// **At most**, and that is the one place a claim's rule is looser than a paragraph's.
    /// Claim 1 of the canonical fixture reads, in full, `A method comprising:` — three
    /// words, because everything after the colon is `Claim.elements`. Requiring four would
    /// cost this app the commonest independent-claim shape there is, and it would cost it
    /// for a reason that does not apply: the rule exists so that a needle cannot match
    /// everywhere, and `1. A method comprising:` matches once.
    static let claimWords = 4

    /// Every anchorable passage of one patent, in `Patent.rows` order.
    ///
    /// Rows order and not any other, because that is document order, and document order is
    /// what `PassagePlacement.monotonic` requires of its input: it walks the targets
    /// ascending and takes the earliest candidate after the previous choice. Handed the same
    /// anchors shuffled it would place almost nothing.
    ///
    /// Three rules, each of which had a plausible wrong answer:
    ///
    /// - **A claim's anchor is its printed number and its preamble, never `Claim.fullText`.**
    ///   The full text scored 3/20 on the grant probe against 20/20 for this: a claim is one
    ///   sentence with a five-level hanging indent under it, so its elements are separated in
    ///   the printed document by line breaks and indentation that no `findString` crosses.
    ///   The number has to be put *back* — `Claim.text` has it stripped because the reader's
    ///   margin used to draw it, and the office's typesetter prints it.
    ///
    /// - **Too short means no anchor**, not a shortened one. A paragraph of four words
    ///   anchored on four words matches in a dozen places, and a wrong placement is worse
    ///   than a missing one: it puts a highlight on a passage the reader did not ask for and
    ///   drags the monotonic cursor past everything that should have followed. What is not
    ///   anchorable is *reported* — `PatentPDFMap`'s diagnostics line and the band under a
    ///   failed jump — which is this app's standing answer to anything it cannot do. A claim
    ///   is the documented exception, and `claimWords` says why.
    ///
    /// - **`ParagraphKey(number: 0)` is never emitted.** That is `Chunker`'s synthetic front
    ///   matter, whose text is `"\(title). \(abstract)"` — a string this app assembled, which
    ///   appears in no document and could only ever be looked for in vain. It is excluded
    ///   here rather than filtered later so that no caller has to know it exists; the fact
    ///   that `Patent.rows` never contains it is a second reason and not the one to rely on.
    static func anchors(in patent: Patent) -> [PassageAnchor] {
        var out: [PassageAnchor] = []

        for section in patent.sections {
            for paragraph in section.paragraphs {
                // The front-matter address, defensively. A parser that ever numbered a real
                // paragraph zero would otherwise hand the map a needle that cannot be found
                // and a citation that can never be checked.
                guard paragraph.number > 0 else { continue }
                let key = ParagraphKey(patent: patent.key, number: paragraph.number)
                let opening = self.opening(paragraph.text, words: paragraphWords)
                // Where the office printed a marker, that marker *is* the index, and
                // guessing from the prose instead was this app declining to read the one
                // exact thing on the page. Measured on WO 2020247738 A9, whose 437 markers
                // are each unique in the document: the opening-words needle placed 428 and
                // 60 of those were on the wrong passage, because a patent writes "In some
                // embodiments, the ..." for pages at a stretch and each needle matched its
                // neighbour. The placements ascended, so `monotonic` had no complaint and
                // the whole run slid one paragraph — up to two pages by the end of it. The
                // marker does not have that failure available to it.
                //
                // Still a fallback and not a certainty: a scanned grant whose brackets the
                // OCR dropped prints `[0001]` as `0001.`, and `Numbering` records what the
                // *parse* found rather than what the PDF renders, so the two can disagree.
                // The prose needle stays underneath for exactly that.
                if patent.numbering == .printed {
                    out.append(
                        PassageAnchor(
                            target: .paragraph(key),
                            needle: Citation.printedMarker(key), fallback: opening))
                } else if let opening {
                    out.append(
                        PassageAnchor(
                            target: .paragraph(key), needle: opening, fallback: nil))
                }
            }
        }

        for claim in patent.claims {
            guard let opening = opening(claim.text, atMost: claimWords) else { continue }
            out.append(
                PassageAnchor(
                    target: .claim(ClaimKey(patent: patent.key, number: claim.number)),
                    needle: "\(claim.number). " + opening,
                    fallback: self.opening(claim.text, words: paragraphWords)))
        }

        return out
    }

    /// The first `words` whitespace-separated words, single-spaced, or `nil` if there are
    /// fewer than that many.
    ///
    /// Single-spaced because the parse's own whitespace is not the document's: a paragraph
    /// recovered from a PDF has been through `PatentPDFImporter.tidy`, one fetched from
    /// Google Patents carries whatever the markup had, and `findString` compares runs of
    /// text where a double space is two characters. Splitting and rejoining makes the needle
    /// independent of both.
    private static func opening(_ text: String, words: Int) -> String? {
        let split = text.split(whereSeparator: \.isWhitespace)
        guard split.count >= words else { return nil }
        return split.prefix(words).joined(separator: " ")
    }

    /// The same, but taking what is there when there is less. `nil` only for no words at
    /// all. Claims only — see `claimWords`.
    private static func opening(_ text: String, atMost words: Int) -> String? {
        let split = text.split(whereSeparator: \.isWhitespace)
        guard !split.isEmpty else { return nil }
        return split.prefix(words).joined(separator: " ")
    }

    // MARK: - The reverse leg

    /// Which passage a string of the document's own text came out of.
    ///
    /// The textual half of "what did the reader just select". `PatentPDFMap` answers this
    /// far better when it can — it binary-searches the ordinals it already computed, which
    /// never compares a character and so cannot be defeated by hyphenation or by OCR — and
    /// this is the fallback for a selection that falls outside every bracket the map placed.
    ///
    /// **Deliberately not `PatentPDFImporter.tidy`, whose rules these are.** That function's
    /// output feeds `Source.contentSHA256`, so a subtle change to it silently reindexes every
    /// PDF-imported patent in the library and invalidates their answer caches. Two functions
    /// with the same two rules is the cheaper mistake, and this comment is the join.
    ///
    /// Case- and diacritic-insensitive, matching `findString` and `DocumentFind` before it,
    /// because the alternative is a selection that fails to resolve for having crossed a
    /// small-caps run.
    static func target(containing selected: String, in patent: Patent) -> CitationTarget? {
        let needle = normalized(selected)
        guard !needle.isEmpty else { return nil }

        for section in patent.sections {
            for paragraph in section.paragraphs where paragraph.number > 0 {
                if contains(needle, in: normalized(paragraph.text)) {
                    return .paragraph(
                        ParagraphKey(patent: patent.key, number: paragraph.number))
                }
            }
        }
        // Claims after paragraphs, in the order `Patent.rows` prints them. A claim is as
        // citable as a paragraph, and a reader who drags across claim 7 has selected
        // claim 7.
        for claim in patent.claims {
            if contains(needle, in: normalized(claim.fullText)) {
                return .claim(ClaimKey(patent: patent.key, number: claim.number))
            }
        }
        return nil
    }

    /// Whitespace collapsed and a line-break hyphen rejoined — the two ways a string pulled
    /// out of a PDF differs from the same string in the parse.
    ///
    /// Only across a lowercase-to-lowercase break, so `thermally-conductive` split across
    /// lines stays hyphenated and `manufactur- ing` is rejoined. `PatentPDFImporter.tidy`
    /// makes the same asymmetry and explains it at greater length.
    static func normalized(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.replacing(/([a-z])- ([a-z])/) { "\($0.1)\($0.2)" }
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
