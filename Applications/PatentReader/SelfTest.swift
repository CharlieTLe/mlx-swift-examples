// Copyright © 2026 Apple Inc.

import Foundation
import MLXLLM
import MLXLMCommon
import SwiftUI

/// Model-free assertions, run by `--selftest`. No download, no network, no GPU.
///
/// They live in the executable because there is only one target: a test target would need
/// the fixtures and the app's types duplicated or exported. What they are for is the
/// things that break silently — markup drift that still parses, a citation that resolves
/// to the wrong row, an index whose entries name paragraphs that no longer exist, and
/// prompt drift.
enum SelfTest {

    /// Collects failures rather than trapping, so one run reports everything that is
    /// wrong instead of only the first thing. A local object rather than static state:
    /// mutable global state would need concurrency annotations it has no business
    /// needing.
    final class Log {
        private(set) var failures: [String] = []

        func fail(_ message: String) { failures.append(message) }

        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { fail(message()) }
        }

        func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: @autoclosure () -> String) {
            if lhs != rhs { fail("\(label()): expected \(rhs), got \(lhs)") }
        }
    }

    static func run() -> Bool {
        let log = Log()

        googlePatentsParse(log)
        claimTree(log)
        patentNumbers(log)
        citations(log)
        citationScanner(log)
        citationCheck(log)
        chunking(log)
        lexicalRetrieval(log)
        indexIntegrity(log)
        pdfParagraphRecovery(log)
        librarySearch(log)
        quoteCheck(log)
        selection(log)
        followUpParsing(log)
        goldenPromptRender(log)
        readerFonts(log)
        readerTextSizes(log)
        readingProgress(log)
        wordTokenizer(log)

        if log.failures.isEmpty {
            print("selftest: all checks passed")
            return true
        }
        for failure in log.failures {
            print("selftest FAIL: \(failure)")
        }
        print("selftest: \(log.failures.count) failure(s)")
        return false
    }

    // MARK: - Fixtures

    /// The checked-in Google Patents pages, and what each one is *for*.
    ///
    /// Four rather than one, because one patent is one sample and the assumption going in
    /// — that the markup is uniform — was wrong in four separate ways. Each fixture here
    /// broke a version of the parser:
    ///
    /// - `US10123456B2` is the canonical modern grant: `num` carries the printed
    ///   paragraph number, `claim-ref` carries the dependency graph, `figure-callout`
    ///   carries the reference numerals.
    /// - `US20140030575A1` is a published application, which spells the paragraph class
    ///   `description-line` instead of `description-paragraph`, sets claim numbers in
    ///   `<b>`, and has no issue date.
    /// - `US7654321B2` is a 2010 grant whose `num` holds `p-0002` — the *id*, not the
    ///   number. This is the fixture that killed "post-2001 means numbered".
    /// - `US5000000A` is a 1991 grant with no paragraph numbers and **no `claim-ref` at
    ///   all**, so its claim tree has to come from the claims' own wording.
    private struct Fixture {
        let name: String
        let paragraphs: Int
        let claims: Int
        let independentClaims: Int
        let sections: Int
        let numbering: Numbering
        let dependencySource: Claim.DependencySource
        let assignee: String
        var numerals: Int
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "US10123456B2", paragraphs: 41, claims: 21, independentClaims: 3,
            sections: 5, numbering: .printed, dependencySource: .markup,
            assignee: "Raytheon Co", numerals: 12),
        Fixture(
            name: "US20140030575A1", paragraphs: 97, claims: 20, independentClaims: 2,
            sections: 15, numbering: .printed, dependencySource: .markup,
            assignee: "Individual", numerals: 27),
        Fixture(
            name: "US7654321B2", paragraphs: 93, claims: 26, independentClaims: 6,
            sections: 4, numbering: .synthesized, dependencySource: .markup,
            assignee: "Schlumberger Technology Corp", numerals: 104),
        Fixture(
            name: "US5000000A", paragraphs: 89, claims: 7, independentClaims: 2,
            sections: 34, numbering: .synthesized, dependencySource: .text,
            assignee: "University of Florida", numerals: 1),
    ]

    /// The fixtures directory, copied whole as an explicit folder — see the project's
    /// `explicitFolders`, which is what stops Xcode flattening it into the resource root.
    private static func fixtureHTML(_ name: String) -> String? {
        guard
            let directory = Bundle.main.url(forResource: "Fixtures", withExtension: nil)
        else { return nil }
        return try? String(
            contentsOf: directory.appendingPathComponent("\(name).html"), encoding: .utf8)
    }

    private static func parsed(_ name: String) -> Patent? {
        guard let html = fixtureHTML(name) else { return nil }
        return try? GooglePatentsParser.parse(
            html, requested: PatentNumberParser.parse(name), url: nil,
            retrieved: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Parsing

    /// The markup-drift alarm.
    ///
    /// Counts rather than a byte-compared golden JSON, and the choice is worth stating: a
    /// golden document would catch every change, including the hundred cosmetic ones a
    /// whitespace fix makes, and a test that fails for cosmetic reasons gets regenerated
    /// without being read. These counts are the things that cannot change without the
    /// parse being wrong — and each one was *measured* against the real page, so they are
    /// regression targets rather than estimates.
    private static func googlePatentsParse(_ log: Log) {
        for fixture in fixtures {
            guard let html = fixtureHTML(fixture.name) else {
                log.fail("the \(fixture.name) fixture is missing from the bundle")
                continue
            }
            guard
                let patent = try? GooglePatentsParser.parse(
                    html, requested: PatentNumberParser.parse(fixture.name), url: nil)
            else {
                log.fail("\(fixture.name) did not parse")
                continue
            }

            log.equal(patent.key.slug, fixture.name, "\(fixture.name) number")
            log.equal(patent.paragraphs.count, fixture.paragraphs, "\(fixture.name) paragraphs")
            log.equal(patent.claims.count, fixture.claims, "\(fixture.name) claims")
            log.equal(
                patent.claims.filter(\.isIndependent).count, fixture.independentClaims,
                "\(fixture.name) independent claims")
            log.equal(patent.sections.count, fixture.sections, "\(fixture.name) sections")
            log.equal(patent.numbering, fixture.numbering, "\(fixture.name) numbering")
            log.equal(patent.assignee, fixture.assignee, "\(fixture.name) assignee")
            log.equal(
                patent.calloutNumerals.count, fixture.numerals,
                "\(fixture.name) reference numerals")
            log.check(!patent.title.isEmpty, "\(fixture.name) has no title")
            log.check(!patent.abstract.isEmpty, "\(fixture.name) has no abstract")
            log.check(!patent.inventors.isEmpty, "\(fixture.name) has no inventors")
            log.check(
                !patent.classifications.isEmpty, "\(fixture.name) has no classifications")

            // Where the dependency edges came from. The whole reason `US5000000A` is a
            // fixture: it has `claim-dependent` wrappers and zero `claim-ref` elements,
            // so if the text fallback regresses its tree silently goes flat.
            let sources = Set(
                patent.claims.filter { !$0.isIndependent }.map(\.dependencySource))
            log.equal(
                sources, [fixture.dependencySource],
                "\(fixture.name) dependency sources")

            // Every paragraph carries its own numbering story, and they must agree with
            // the patent's: a document that is half numbered is the shape the parser
            // refuses, and this is what would catch it agreeing to it.
            let printed = patent.paragraphs.filter(\.hasPrintedNumber).count
            log.equal(
                printed, fixture.numbering == .printed ? fixture.paragraphs : 0,
                "\(fixture.name) paragraphs carrying a printed number")

            // Numbers ascend and indices are contiguous from zero. A parse that dropped a
            // paragraph in the middle would still produce plausible counts.
            for (offset, paragraph) in patent.paragraphs.enumerated() {
                log.equal(paragraph.index, offset, "\(fixture.name) paragraph index")
                log.check(
                    !paragraph.text.isEmpty,
                    "\(fixture.name) paragraph \(paragraph.number) is empty")
            }
            for (previous, next) in zip(patent.paragraphs, patent.paragraphs.dropFirst()) {
                log.check(
                    next.number > previous.number,
                    "\(fixture.name) paragraph numbers stop ascending at \(next.number)")
            }

            // The claim's own printed number is stripped, because the margin draws it.
            // Getting this wrong prints "1. 1. A method comprising:".
            for claim in patent.claims {
                log.check(
                    !claim.text.hasPrefix("\(claim.number)."),
                    "\(fixture.name) claim \(claim.number) kept its printed number")
                log.check(
                    !claim.text.isEmpty || !claim.elements.isEmpty,
                    "\(fixture.name) claim \(claim.number) is empty")
            }

            // Inline markup survives in the text. This is the regression that deleted
            // `<claim-ref>claim 1</claim-ref>` and left "The method of , further
            // comprising", which also silently flattened US6285999B1's whole claim tree.
            if fixture.dependencySource == .text || fixture.dependencySource == .markup,
                let dependent = patent.claims.first(where: { !$0.isIndependent })
            {
                log.check(
                    dependent.text.lowercased().contains("claim"),
                    "\(fixture.name) claim \(dependent.number) lost its cross-reference "
                        + "text: \"\(dependent.text.prefix(60))\"")
            }
        }

        // A page for the wrong patent is refused rather than imported. Google Patents
        // answers an unknown number with a family member instead of a 404, so without
        // this an import silently produces a different document.
        if let html = fixtureHTML("US10123456B2") {
            let wrong = PatentKey(country: "US", serial: "9999999", kind: "B2")
            do {
                _ = try GooglePatentsParser.parse(html, requested: wrong, url: nil)
                log.fail("a page for a different patent was accepted")
            } catch let failure as GooglePatentsParser.Failure {
                guard case .wrongPatent = failure else {
                    log.fail("the wrong-patent check reported \(failure)")
                    return
                }
            } catch {
                log.fail("the wrong-patent check threw \(error)")
            }
        }

        // A page with no specification is a failure and not an empty document. The
        // silently-empty reader pane is the failure mode this whole discipline exists
        // for.
        do {
            _ = try GooglePatentsParser.parse(
                "<html><body><p>nothing here</p></body></html>", requested: nil, url: nil)
            log.fail("a page with no description was accepted")
        } catch {
            // Expected.
        }
    }

    /// Every dependency resolves, nothing cycles, and every dependent claim reaches an
    /// independent one.
    ///
    /// The third is the one worth having. A claim whose chain does not terminate at an
    /// independent claim is unreachable in the tree the reader is shown — it draws flush
    /// left as though it were independent, which is a false statement about the patent's
    /// scope, and it is invisible unless something asks.
    private static func claimTree(_ log: Log) {
        for fixture in fixtures {
            guard let patent = parsed(fixture.name) else { continue }
            let numbers = Set(patent.claims.map(\.number))
            let depths = patent.claimDepths()

            for claim in patent.claims {
                for parent in claim.dependsOn {
                    log.check(
                        numbers.contains(parent),
                        "\(fixture.name) claim \(claim.number) depends on \(parent), "
                            + "which does not exist")
                    log.check(
                        parent != claim.number,
                        "\(fixture.name) claim \(claim.number) depends on itself")
                    log.check(
                        parent < claim.number,
                        "\(fixture.name) claim \(claim.number) depends forward on \(parent)")
                }

                log.equal(
                    claim.isIndependent, claim.dependsOn.isEmpty,
                    "\(fixture.name) claim \(claim.number) independence")

                // Every claim has a depth, which is only true if the walk from the
                // independents reached it — so this is the reachability check.
                guard let depth = depths[claim.number] else {
                    log.fail(
                        "\(fixture.name) claim \(claim.number) is not reachable from any "
                            + "independent claim")
                    continue
                }
                log.equal(
                    depth == 0, claim.isIndependent,
                    "\(fixture.name) claim \(claim.number) depth against independence")
                for parent in claim.dependsOn {
                    guard let parentDepth = depths[parent] else { continue }
                    log.check(
                        depth > parentDepth,
                        "\(fixture.name) claim \(claim.number) is not below claim \(parent)")
                }
            }
        }
    }

    // MARK: - Numbers and citations

    /// Every spelling of one number reaches the same patent.
    ///
    /// A reader pastes whichever form was in front of them, and all of these are forms
    /// that appear in the wild — in a citation list, in a search result, in a filename.
    private static func patentNumbers(_ log: Log) {
        let expected = PatentKey(country: "US", serial: "10123456", kind: "B2")
        for spelling in [
            "US10123456B2", "us10123456b2", "US 10123456 B2", "US 10,123,456 B2",
            "US10,123,456B2", "US-10123456-B2", "  US10123456B2  ",
        ] {
            log.equal(PatentNumberParser.parse(spelling), expected, "parsing \"\(spelling)\"")
        }

        // Without a kind code, which is how a reader usually remembers it.
        log.equal(
            PatentNumberParser.parse("10123456"),
            PatentKey(country: "US", serial: "10123456", kind: nil),
            "a bare serial defaults to US")
        log.equal(
            PatentNumberParser.parse("10,123,456"),
            PatentKey(country: "US", serial: "10123456", kind: nil),
            "a grouped bare serial")

        // A published application: eleven digits, never grouped.
        log.equal(
            PatentNumberParser.parse("US20140030575A1"),
            PatentKey(country: "US", serial: "20140030575", kind: "A1"),
            "an application publication number")
        log.equal(
            PatentKey(country: "US", serial: "20140030575", kind: "A1").display,
            "US 20140030575 A1", "an application number is not grouped")
        log.equal(
            PatentKey(country: "US", serial: "10123456", kind: "B2").display,
            "US 10,123,456 B2", "a grant number is grouped")
        log.equal(
            PatentKey(country: "EP", serial: "0732743", kind: "A2").display,
            "EP 0732743 A2", "a non-US number is not grouped")

        // Another office.
        log.equal(
            PatentNumberParser.parse("EP0732743A2"),
            PatentKey(country: "EP", serial: "0732743", kind: "A2"), "an EP number")

        // Junk.
        for junk in ["", "heat sink", "12345", "the method of claim 1", "US", "----"] {
            log.check(
                PatentNumberParser.parse(junk) == nil,
                "\"\(junk)\" should not parse as a patent number")
        }

        // `looksLikeNumber` is the gate that stops a title from triggering a fetch, so it
        // has to be stricter than `parse`.
        log.check(
            PatentNumberParser.looksLikeNumber("US10123456B2"), "a number looks like one")
        log.check(
            !PatentNumberParser.looksLikeNumber("heat sink 100"),
            "a title with a number in it does not look like a number")
    }

    /// How a citation reads, in both numbering states.
    ///
    /// The synthesized case is the one that matters. A reader who copies `[0042]` into a
    /// brief and then opens the printed grant will not find it, so the long form has to
    /// say where the number came from and the chip has to look different at a glance.
    private static func citations(_ log: Log) {
        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        let paragraph = CitationTarget.paragraph(ParagraphKey(patent: key, number: 42))
        let claim = CitationTarget.claim(ClaimKey(patent: key, number: 7))

        log.equal(
            Citation.string(paragraph, numbering: .printed),
            "US 10,123,456 B2 · [0042]", "a printed paragraph citation")
        log.equal(
            Citation.string(paragraph, numbering: .synthesized),
            "US 10,123,456 B2 · ¶42 (numbered by this reader)",
            "a synthesized paragraph citation")
        log.equal(
            Citation.string(claim, numbering: .printed), "US 10,123,456 B2 · claim 7",
            "a claim citation")

        log.equal(
            Citation.chipLabel(paragraph, numbering: .printed), "[0042]", "a printed chip")
        log.equal(
            Citation.chipLabel(paragraph, numbering: .synthesized), "¶42",
            "a synthesized chip")
        log.check(
            Citation.chipLabel(paragraph, numbering: .printed)
                != Citation.chipLabel(paragraph, numbering: .synthesized),
            "the two numbering states must not render alike even at chip size")

        // The URL a chip carries has to survive the round trip, or clicking it does
        // nothing and there is no error anywhere.
        for target in [paragraph, claim] {
            guard let url = CitationLink(target).url else {
                log.fail("a citation produced no URL")
                continue
            }
            log.equal(
                CitationLink.target(from: url), target, "a citation URL round trip")
        }
        log.check(
            CitationLink.target(from: URL(string: "https://example.com")!) == nil,
            "a foreign URL should not resolve to a citation")
    }

    // MARK: - Streaming

    /// The streaming state machine, fed one character at a time.
    ///
    /// **One character at a time is the point.** A citation arrives split at an arbitrary
    /// byte boundary — `[00` then `42]` — and the failure this prevents is a chip
    /// flickering into existence half-formed. Feeding the whole string would exercise
    /// none of that; feeding it a character at a time exercises *every* intermediate
    /// state, which is the only way to know the tail is held back at each one.
    private static func citationScanner(_ log: Log) {
        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        let other = PatentKey(country: "US", serial: "8534348", kind: "B2")
        let library = [
            fakePatent(key, paragraphs: [19, 22, 41], claims: [1, 7]),
            fakePatent(other, paragraphs: [12], claims: [1]),
        ]
        let context = fakeContext(
            question: "how is the matrix formed?",
            retrieved: [
                .paragraph(ParagraphKey(patent: key, number: 19)),
                .paragraph(ParagraphKey(patent: key, number: 22)),
                .claim(ClaimKey(patent: key, number: 7)),
            ],
            patents: [key])

        /// Runs the scanner over `text`, one character at a time, and returns what it
        /// committed.
        func scan(_ text: String, context: AnswerContext = context) -> [AnswerRun] {
            var scanner = CitationScanner(context: context, library: library)
            for character in text { scanner.consume(String(character)) }
            scanner.finish()
            return scanner.runs
        }

        /// The same, in one call, which is the cache-hit path.
        func scanWhole(_ text: String, context: AnswerContext = context) -> [AnswerRun] {
            var scanner = CitationScanner(context: context, library: library)
            scanner.consume(text)
            scanner.finish()
            return scanner.runs
        }

        func citations(_ runs: [AnswerRun]) -> [String] {
            runs.compactMap { if case .citation(let c) = $0 { c.literal } else { nil } }
        }

        func text(_ runs: [AnswerRun]) -> String {
            runs.map {
                switch $0 {
                case .text(let value): value
                case .citation(let value): value.literal
                }
            }.joined()
        }

        // Streaming and whole must agree. If they do not, a cache hit renders differently
        // from the generation that produced it.
        let sentence =
            "The matrix is formed in one piece [0019] with the shells, and "
            + "claim 7 limits that to expansion plugs."
        log.equal(
            text(scan(sentence)), sentence, "the streamed text reassembles exactly")
        log.equal(
            citations(scan(sentence)), ["[0019]", "claim 7"],
            "citations found while streaming")
        log.equal(
            citations(scanWhole(sentence)), citations(scan(sentence)),
            "streaming and whole disagree about the citations")

        // Verdicts.
        let verdicts = scan(
            "Real and shown [0019]. Real and unshown [0041]. Invented [0099]. "
                + "Unshown claim 1, shown claim 7.")
        let byLiteral = Dictionary(
            uniqueKeysWithValues: verdicts.compactMap {
                if case .citation(let c) = $0 { (c.literal, c.verdict) } else { nil }
            })
        log.equal(byLiteral["[0019]"], .supported, "a retrieved paragraph")
        log.equal(byLiteral["[0041]"], .unretrieved, "a real but unretrieved paragraph")
        log.equal(byLiteral["[0099]"], .nonexistent, "a paragraph that does not exist")
        log.equal(byLiteral["claim 7"], .supported, "a retrieved claim")
        log.equal(byLiteral["claim 1"], .unretrieved, "a real but unretrieved claim")

        // A bracket that is not a citation stays text. Patents use brackets, so giving up
        // has to be a normal outcome.
        for prose in [
            "the range [0.5, 2.0] millimetres", "a bracket [ that never closes",
            "see [Smith] for details", "an empty [] pair",
        ] {
            log.equal(citations(scan(prose)), [], "\"\(prose)\" should carry no citation")
            log.equal(text(scan(prose)), prose, "\"\(prose)\" should survive as text")
        }

        // The word "claim" as a noun, not a citation.
        log.equal(
            citations(scan("the claim is broad, and claims are what matter")), [],
            "\"claim\" without a number is not a citation")

        // A citation at the very end of a stream, which is the case `finish()` exists
        // for: the scanner is holding a tail when the stream stops.
        log.equal(citations(scan("as set out in [0022]")), ["[0022]"], "a trailing citation")
        // And a truncated one, which must render as text rather than as an invented chip.
        log.equal(citations(scan("as set out in [00")), [], "a truncated citation")
        log.equal(text(scan("as set out in [00")), "as set out in [00", "its text survives")

        // The synthesized form, which a patent with no printed numbers is cited by.
        log.equal(citations(scan("see ¶42 above")), ["¶42"], "a synthesized citation")

        // Cross-patent. The qualifier has to be taken as part of the citation, or `[0012]`
        // commits against the wrong patent and " of US 8,534,348 B2" is left as prose.
        let cross = fakeContext(
            question: "how do these seal the port?",
            retrieved: [
                .paragraph(ParagraphKey(patent: key, number: 19)),
                .paragraph(ParagraphKey(patent: other, number: 12)),
            ],
            patents: [key, other])
        let crossRuns = scan(
            "Both use a plug [0019] of US 10,123,456 B2 and "
                + "[0012] of US 8,534,348 B2.", context: cross)
        let targets = crossRuns.compactMap {
            if case .citation(let c) = $0 { c.target } else { nil }
        }
        log.equal(
            targets,
            [
                .paragraph(ParagraphKey(patent: key, number: 19)),
                .paragraph(ParagraphKey(patent: other, number: 12)),
            ],
            "cross-patent citations resolve to their named patents")
        log.check(
            !text(crossRuns).contains("  "),
            "the qualifier was not absorbed into the citation")

        // An unqualified citation in a cross-patent answer resolves to the primary
        // patent — the one that contributed the most passages — and the check downstream
        // is what catches it when that guess is wrong.
        let bare = scan("Both use a plug [0012].", context: cross)
        log.equal(
            bare.compactMap { if case .citation(let c) = $0 { c.target.patent } else { nil } },
            [key], "an unqualified citation resolves to the primary patent")
    }

    /// The three verdicts, against a synthetic library.
    ///
    /// Separate from the scanner suite because the distinction being tested is not about
    /// parsing: it is that "real but not shown" and "not real" are different failures
    /// with different meanings, and collapsing them throws away the more interesting one.
    private static func citationCheck(_ log: Log) {
        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        let other = PatentKey(country: "US", serial: "8534348", kind: "B2")
        let library = [
            key: fakePatent(key, paragraphs: [19, 41], claims: [1, 7]),
            other: fakePatent(other, paragraphs: [12], claims: [1]),
        ]
        let retrieved: Set<CitationTarget> = [
            .paragraph(ParagraphKey(patent: key, number: 19))
        ]

        func verdict(_ target: CitationTarget) -> CitationCheck.Verdict {
            CitationCheck.verdict(for: target, retrieved: retrieved, library: library)
        }

        log.equal(
            verdict(.paragraph(ParagraphKey(patent: key, number: 19))), .supported,
            "retrieved")
        log.equal(
            verdict(.paragraph(ParagraphKey(patent: key, number: 41))), .unretrieved,
            "real, not retrieved")
        log.equal(
            verdict(.paragraph(ParagraphKey(patent: key, number: 99))), .nonexistent,
            "no such paragraph")
        log.equal(verdict(.claim(ClaimKey(patent: key, number: 7))), .unretrieved, "a real claim")
        log.equal(
            verdict(.claim(ClaimKey(patent: key, number: 99))), .nonexistent,
            "no such claim")

        // A paragraph of a *different* patent in the library is real. Getting this wrong
        // would strike through every correct cross-patent citation.
        log.equal(
            verdict(.paragraph(ParagraphKey(patent: other, number: 12))), .unretrieved,
            "a real paragraph of another patent in the library")
        // And one of a patent that is not in the library at all is not.
        let absent = PatentKey(country: "US", serial: "1111111", kind: "A")
        log.equal(
            verdict(.paragraph(ParagraphKey(patent: absent, number: 1))), .nonexistent,
            "a paragraph of a patent that is not in the library")

        // Paragraph 0 is the abstract's synthetic address and is not a paragraph of the
        // document, so a citation to `[0000]` is a number the model made up.
        log.equal(
            verdict(.paragraph(ParagraphKey(patent: key, number: 0))), .nonexistent,
            "paragraph zero is not a real citation target")

        // Only `.supported` clicks. This is the whole `.unretrieved` argument in one
        // assertion: a link would launder a connection nothing supports.
        log.check(CitationCheck.Verdict.supported.isClickable, "supported clicks")
        log.check(!CitationCheck.Verdict.unretrieved.isClickable, "unretrieved does not")
        log.check(!CitationCheck.Verdict.nonexistent.isClickable, "nonexistent does not")
    }

    // MARK: - Retrieval

    /// Chunking, which is where the citation unit and the retrieval unit have to agree.
    private static func chunking(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the chunking checks")
            return
        }
        let chunks = Chunker.chunks(for: patent)
        log.check(!chunks.isEmpty, "no chunks were produced")

        // Every chunk resolves to something real. A chunk whose target does not exist is
        // an index entry that can only ever produce a `.nonexistent` citation.
        let byKey = [patent.key: patent]
        for chunk in chunks {
            let isAbstract: Bool
            if case .paragraph(let key) = chunk.target {
                isAbstract = key.number == 0
            } else {
                isAbstract = false
            }
            guard !isAbstract else { continue }
            log.check(
                CitationCheck.exists(chunk.target, in: byKey),
                "chunk \(chunk.target.slug) names something that does not exist")
            log.check(!chunk.text.isEmpty, "chunk \(chunk.target.slug) has no text")
            log.check(
                !chunk.embeddingText.isEmpty,
                "chunk \(chunk.target.slug) has nothing to embed")
        }

        // Every claim is chunked, and a dependent claim's *embedding* text carries its
        // parents while its *shown* text does not. Getting that backwards would make the
        // prompt cite claim 7 for a limitation that is in claim 1.
        for claim in patent.claims {
            guard
                let chunk = chunks.first(where: {
                    $0.target == .claim(ClaimKey(patent: patent.key, number: claim.number))
                })
            else {
                log.fail("claim \(claim.number) was not chunked")
                continue
            }
            log.equal(chunk.text, claim.fullText, "claim \(claim.number) shown text")
            if let parent = claim.dependsOn.first,
                let parentClaim = patent.claim(numbered: parent)
            {
                log.check(
                    chunk.embeddingText.contains(parentClaim.text.prefix(40)),
                    "claim \(claim.number) does not embed with claim \(parent)'s text")
                log.check(
                    !chunk.text.contains(parentClaim.text.prefix(40)),
                    "claim \(claim.number)'s shown text leaked its parent's")
            }
        }

        // Non-indexable sections stay in the document and out of the index. Both halves:
        // dropping them from the document would lose paragraphs a reader may cite.
        for section in patent.sections where !section.isIndexable {
            for paragraph in section.paragraphs {
                let target = CitationTarget.paragraph(
                    ParagraphKey(patent: patent.key, number: paragraph.number))
                log.check(
                    !chunks.contains { $0.target == target },
                    "boilerplate paragraph \(paragraph.number) was indexed")
                log.check(
                    patent.paragraph(numbered: paragraph.number) != nil,
                    "boilerplate paragraph \(paragraph.number) was dropped from the document")
            }
        }

        // Windowing. A long paragraph produces several chunks with **the same** citation
        // target, which is what keeps citations paragraph-granular while retrieval gets
        // the granularity it needs.
        let long = (1 ... 40)
            .map {
                "This is sentence number \($0) of a deliberately long paragraph about "
                    + "thermal management and the internal matrix."
            }
            .joined(separator: " ")
        let windows = Chunker.windows(long)
        log.check(windows.count > 1, "a 400-word paragraph was not windowed")
        for window in windows {
            let count = window.split(whereSeparator: \.isWhitespace).count
            log.check(
                count <= Chunker.windowWords + 60,
                "a window ran to \(count) words, past the budget plus one sentence")
        }
        // Overlap: consecutive windows share text, so a sentence on a boundary is whole
        // in at least one of them.
        for (first, second) in zip(windows, windows.dropFirst()) {
            let tail = first.split(whereSeparator: \.isWhitespace).suffix(8).joined(separator: " ")
            log.check(
                second.contains(tail),
                "consecutive windows do not overlap, so a boundary sentence is split")
        }
        log.equal(Chunker.windows("short").count, 1, "a short paragraph is one window")

        // Claim resolution terminates even on a cyclic `dependsOn`, which a text-derived
        // tree can contain.
        let cyclic = Patent(
            schemaVersion: 1, id: "USX", key: PatentKey(country: "US", serial: "999999", kind: nil),
            title: "t", abstract: "a", inventors: [], assignee: nil, publicationDate: nil,
            priorityDate: nil, classifications: [], numbering: .printed,
            source: fakeSource(), sections: [],
            claims: [
                Claim(
                    number: 1, text: "one", elements: [], dependsOn: [2], dependencySource: .text),
                Claim(
                    number: 2, text: "two", elements: [], dependsOn: [1], dependencySource: .text),
            ],
            calloutNumerals: [:])
        let resolved = Chunker.resolvedText(of: cyclic.claims[0], in: cyclic)
        log.check(resolved.contains("one"), "a cyclic claim chain lost the claim itself")
    }

    /// BM25, and specifically the queries dense retrieval is worst at.
    ///
    /// This is also the suite that runs with no GPU, so it is what validates half the
    /// retrieval story on the Simulator.
    private static func lexicalRetrieval(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the lexical checks")
            return
        }
        let chunks = Chunker.chunks(for: patent)
        let index = LexicalIndex(chunks: chunks)

        func top(_ query: String, _ count: Int = 3) -> [Chunk] {
            index.scores(for: query).prefix(count).map { chunks[$0.chunk] }
        }

        // A bare reference numeral. The whole reason this leg exists: a 768-dimensional
        // embedding puts 100 and 102 at nearly the same point, and BM25 does not.
        let numeral = patent.calloutNumerals.keys.sorted().first ?? 100
        let hits = top("what is \(numeral)?")
        log.check(
            hits.contains { $0.text.contains("\(numeral)") },
            "a bare reference numeral query found no paragraph containing it")

        // A term of art. Retrieval has to be able to tell these apart, because in a claim
        // they are three different scopes.
        let comprising = top("comprising")
        log.check(
            !comprising.isEmpty, "\"comprising\" matched nothing in a patent full of it")

        // Tokenization keeps run-ins whole. Splitting `H05K7` into `h05k` and `7` would
        // make a classification search match every paragraph with a 7 in it.
        log.equal(
            LexicalIndex.tokenize("US10123456B2 H05K7/20336"),
            ["us10123456b2", "h05k7", "20336", "#20336"],
            "alphanumeric run-ins survive tokenization")
        log.equal(
            LexicalIndex.tokenize("the heat sink 100"),
            ["the", "heat", "sink", "100", "#100"],
            "a bare number is indexed twice, plainly and as a numeral")

        // Nothing at all is a real answer.
        log.equal(
            index.scores(for: "zzzzz qqqqq").count, 0,
            "a query of nonsense matched something")
    }

    /// The whole index, structurally.
    ///
    /// The highest-value new suite, and it runs in milliseconds over the whole library.
    /// Vectors are synthetic and deterministic, so this stays model-free: what breaks
    /// silently about an index is not its numbers but its *structure* — an entry naming a
    /// paragraph that no longer exists, a dimension that drifted, a NaN that makes every
    /// dot product against it NaN.
    private static func indexIntegrity(_ log: Log) {
        for fixture in fixtures {
            guard let patent = parsed(fixture.name) else { continue }
            let chunks = Chunker.chunks(for: patent)
            let dimension = 8
            var seed: UInt64 = 12345

            /// A deterministic pseudo-random unit vector. Deterministic so a failure is
            /// reproducible, and normalized because the real ones are — the search takes
            /// a dot product and calls it a cosine.
            func vector() -> [Float] {
                var raw: [Float] = []
                for _ in 0 ..< dimension {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    raw.append(Float(Int32(truncatingIfNeeded: seed >> 33)) / 1e9)
                }
                return VectorOperations.normalize(raw)
            }

            let entries = chunks.map {
                PatentIndexFile.Entry(chunk: $0, vector: vector())
            }
            let file = PatentIndexFile(
                schemaVersion: PatentIndexFile.schemaVersion,
                patentSlug: patent.key.slug,
                patentDigest: patent.source.contentSHA256,
                parserVersion: patent.source.parserVersion,
                chunkerVersion: Chunker.version,
                modelID: "test",
                documentPrefix: EmbeddingService.documentPrefix,
                dimension: dimension,
                builtAt: Date(timeIntervalSince1970: 0),
                entries: entries)

            // The file round-trips. The vectors are base64 rather than a JSON array of
            // numbers, so a bug in that encoding is silent — every vector would decode to
            // garbage and every search would return the wrong paragraphs in a plausible
            // order.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? encoder.encode(file),
                let back = try? decoder.decode(PatentIndexFile.self, from: data)
            else {
                log.fail("\(fixture.name) index did not round-trip through JSON")
                continue
            }
            log.equal(back.entries.count, entries.count, "\(fixture.name) index entries")

            let byKey = [patent.key: patent]
            var indexedTargets: Set<CitationTarget> = []

            for (original, restored) in zip(entries, back.entries) {
                let floats = restored.floats
                log.equal(
                    floats.count, dimension,
                    "\(fixture.name) a vector decoded to the wrong length")
                log.check(
                    !VectorOperations.hasNonFiniteValues(floats),
                    "\(fixture.name) a vector contains a non-finite value")
                let norm = VectorOperations.l2Norm(floats)
                log.check(
                    abs(norm - 1) < 1e-3,
                    "\(fixture.name) a vector's norm is \(norm), not 1")
                // Float32 round-trips exactly through this encoding, so an inexact
                // comparison here would hide a byte-order bug.
                log.equal(
                    floats, original.floats,
                    "\(fixture.name) a vector changed across the round trip")

                let isAbstract: Bool
                if case .paragraph(let key) = restored.target {
                    isAbstract = key.number == 0
                } else {
                    isAbstract = false
                }
                if !isAbstract {
                    log.check(
                        CitationCheck.exists(restored.target, in: byKey),
                        "\(fixture.name) index names \(restored.target.slug), which does "
                            + "not exist in the patent")
                }
                indexedTargets.insert(restored.target)
                log.check(
                    !restored.text.isEmpty,
                    "\(fixture.name) an index entry has no text")
            }

            // Every indexable paragraph has at least one entry. The converse of the check
            // above, and the one that catches a chunker that silently drops a section.
            for section in patent.sections where section.isIndexable {
                for paragraph in section.paragraphs {
                    let target = CitationTarget.paragraph(
                        ParagraphKey(patent: patent.key, number: paragraph.number))
                    log.check(
                        indexedTargets.contains(target),
                        "\(fixture.name) paragraph \(paragraph.number) is indexable and "
                            + "was not indexed")
                }
            }
            for claim in patent.claims {
                let target = CitationTarget.claim(
                    ClaimKey(patent: patent.key, number: claim.number))
                log.check(
                    indexedTargets.contains(target),
                    "\(fixture.name) claim \(claim.number) was not indexed")
            }
        }

        // Reciprocal rank fusion, on a hand-built pair of rankings. The property that
        // matters: something ranked well by *both* legs beats something ranked slightly
        // better by one.
        let k = 60.0
        let bothSecond = 1 / (k + 1) + 1 / (k + 1)
        let oneFirst = 1 / (k + 0)
        log.check(
            bothSecond > oneFirst,
            "fusion does not prefer agreement between the two legs")
    }

    // MARK: - PDF

    /// The PDF path's two refusals, which are the whole reason it is safe to offer.
    ///
    /// Both are checked at the seam rather than through PDFKit, because what is being
    /// asserted is the *decision* — refuse rather than import — and building a synthetic
    /// two-column PDF with a text layer to assert it through would test PDFKit.
    private static func pdfParagraphRecovery(_ log: Log) {
        // Column order. Non-monotonic paragraph numbers mean the two columns were read
        // interleaved, and a document whose paragraphs are shuffled is worse than no
        // document.
        let shuffled = PatentPDFImporter.Failure.columnsOutOfOrder(at: 12, after: 40)
        log.check(
            shuffled.errorDescription?.contains("interleaved") ?? false,
            "the column-order failure does not explain itself")
        log.check(
            shuffled.errorDescription?.contains("Google Patents") ?? false,
            "the column-order failure does not say what to do instead")

        // No text layer. A pre-1976 grant is a scan, and indexing an empty patent would
        // be worse than refusing: it would answer every question about that patent with
        // silence and never say why.
        let scan = PatentPDFImporter.Failure.noTextLayer(pages: 10, characters: 120)
        log.check(
            scan.errorDescription?.contains("no text layer") ?? false,
            "the no-text-layer failure does not name the problem")
        log.check(
            scan.errorDescription?.contains("Google Patents") ?? false,
            "the no-text-layer failure does not say what to do instead")
    }

    // MARK: - Library

    /// The find field's three readings.
    private static func librarySearch(_ log: Log) {
        func query(_ text: String) -> LibrarySearch.Query { LibrarySearch.parse(text) }

        log.equal(query(""), .all, "an empty query")
        log.equal(query("   "), .all, "a whitespace query")

        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        log.equal(query("US10123456B2"), .number(key), "a full number")
        log.equal(
            query("10,123,456"),
            .number(PatentKey(country: "US", serial: "10123456", kind: nil)),
            "a grouped bare serial")

        log.equal(query("[0042]"), .locator(.paragraph(42)), "a bracketed paragraph")
        log.equal(query("¶42"), .locator(.paragraph(42)), "a pilcrow paragraph")
        log.equal(query("claim 7"), .locator(.claim(7)), "a claim locator")
        log.equal(query("Claim 7"), .locator(.claim(7)), "a capitalised claim locator")

        log.equal(query("heat sink"), .text("heat sink"), "a title query")
        log.equal(query("raytheon"), .text("raytheon"), "an assignee query")

        // Filtering, against the real fixtures.
        let library = fixtures.compactMap { parsed($0.name) }
        guard library.count == fixtures.count else {
            log.fail("could not load the fixtures for the library-search checks")
            return
        }

        func ids(_ text: String) -> [String] {
            LibrarySearch.matches(in: library, query: query(text)).map(\.id)
        }

        log.equal(ids("").count, library.count, "no query lists everything")
        log.equal(ids("[0042]").count, library.count, "a locator does not filter")
        log.equal(ids("raytheon"), ["US10123456B2"], "an assignee match")
        log.equal(ids("schlumberger"), ["US7654321B2"], "another assignee match")
        log.equal(ids("US10123456B2"), ["US10123456B2"], "a number match")
        log.equal(ids("zzzz"), [], "no match")

        // Folding: the diacritic and the apostrophe a reader will not type.
        log.check(
            LibrarySearch.matches(in: library, query: query("RAYTHEON")).count == 1,
            "assignee matching is not case-insensitive")

        // The fetch suggestion, which is the one place the field does something other
        // than filter.
        log.check(
            LibrarySearch.fetchSuggestion(for: query("US10123456B2"), in: library) == nil,
            "a number already in the library should not offer a fetch")
        log.equal(
            LibrarySearch.fetchSuggestion(for: query("US6285999B1"), in: library),
            PatentKey(country: "US", serial: "6285999", kind: "B1"),
            "a number not in the library should offer a fetch")
        log.check(
            LibrarySearch.fetchSuggestion(for: query("heat sink"), in: library) == nil,
            "a text query should not offer a fetch")

        // The outline's invariant: an open section belongs to the open patent.
        var outline = LibraryOutline.following(key)
        log.check(outline.isOpen(patent: key), "the read patent should be open")
        outline.toggle(section: 2, in: key)
        log.check(outline.isOpen(section: 2, in: key), "the tapped section should open")
        let other = PatentKey(country: "US", serial: "5000000", kind: "A")
        log.check(
            !outline.isOpen(section: 2, in: other),
            "an open section number should not read as open in another patent")
        outline.toggle(patent: key)
        log.check(!outline.isOpen(patent: key), "the tapped-open patent should close")
        log.check(
            !outline.isOpen(section: 2, in: key),
            "closing a patent should drop its open section")
    }

    // MARK: - Selection

    private static func selection(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the selection checks")
            return
        }
        let rows = patent.rows

        // Range normalizes regardless of drag direction.
        log.equal(PassageSelection(anchor: 4, head: 1).range, 1 ... 4, "a backwards range")
        log.equal(PassageSelection(anchor: 1, head: 4).range, 1 ... 4, "a forwards range")
        log.equal(PassageSelection(at: 2).count, 1, "a single-row selection")

        // Shift-click backwards through the anchor keeps the anchor.
        var backwards = PassageSelection(at: 4)
        backwards.extend(to: 1)
        log.equal(backwards.anchor, 4, "the anchor after extending backwards")
        log.equal(backwards.range, 1 ... 4, "the range after extending backwards")

        // Drag reversal: past the anchor and back again.
        var reversed = PassageSelection(at: 2)
        reversed.extend(to: 5)
        reversed.extend(to: 1)
        log.equal(reversed.range, 1 ... 2, "the range after a drag reverses")

        // Double-clicking a heading takes its whole section, which is how a reader scopes
        // a question to the Background.
        guard let heading = rows.firstIndex(where: { $0.isHeading }) else {
            log.fail("the fixture has no heading row")
            return
        }
        let section = PassageSelection.unit(at: heading, in: rows)
        log.equal(section.range.lowerBound, heading, "a section selection starts at its heading")
        log.check(
            section.range.upperBound > heading,
            "a section selection should include the rows under the heading")
        log.check(
            rows[(heading + 1) ... section.range.upperBound].allSatisfy { !$0.isHeading },
            "a section selection ran into the next section")

        // Double-clicking anything else takes just it: a paragraph and a claim are each
        // already the whole thing they are.
        guard let paragraph = rows.firstIndex(where: { !$0.isHeading }) else { return }
        log.equal(
            PassageSelection.unit(at: paragraph, in: rows).range, paragraph ... paragraph,
            "a paragraph selects alone")

        // Clamping at the document's edges.
        log.equal(
            PassageSelection(anchor: -4, head: 99_999).clamped(to: rows)?.range,
            0 ... (rows.count - 1), "clamping past both edges")
        log.check(
            PassageSelection(at: 0).clamped(to: [])?.range == nil,
            "clamping into an empty document should yield nil")
        log.equal(
            PassageSelection.unit(at: 99_999, in: rows).range, 99_999 ... 99_999,
            "a double-click on an out-of-range index")

        // Arrow moves. Nothing selected *lands* rather than steps, whichever way it was
        // pressed.
        func moved(_ from: PassageSelection?, _ step: Int, extending: Bool = false)
            -> PassageSelection?
        {
            PassageSelection.moved(from: from, by: step, extending: extending, in: rows)
        }

        log.equal(moved(nil, 1), PassageSelection(at: 0), "the first press down")
        log.equal(moved(nil, -1), PassageSelection(at: 0), "the first press up")
        log.equal(moved(PassageSelection(at: 2), 1), PassageSelection(at: 3), "stepping down")
        log.equal(moved(PassageSelection(at: 2), -1), PassageSelection(at: 1), "stepping up")

        // A collapsed selection moves as a whole rather than shrinking.
        log.equal(
            moved(PassageSelection(anchor: 1, head: 4), 1), PassageSelection(at: 5),
            "an unshifted step out of a range")

        // Off the edge with nothing to extend. Unlike a play, this does nothing rather
        // than rolling: a library is not a sequence.
        log.equal(moved(PassageSelection(at: rows.count - 1), 1), nil, "down at the last row")
        log.equal(moved(PassageSelection(at: 0), -1), nil, "up at row 0")

        // Extending stops at the edge.
        log.equal(
            moved(PassageSelection(at: rows.count - 1), 1, extending: true),
            PassageSelection(at: rows.count - 1), "shift-down at the last row")
        log.equal(
            moved(PassageSelection(anchor: 4, head: 3), -1, extending: true),
            PassageSelection(anchor: 4, head: 2),
            "shift-up back through the anchor keeps it")
        log.equal(
            PassageSelection.moved(from: nil, by: 1, extending: false, in: []), nil,
            "an arrow move in an empty document")
    }

    // MARK: - Quotations and follow-ups

    /// The quote check, ported and still earning its place.
    ///
    /// Patents attract fabricated quotation exactly as verse does, and here there is a
    /// second reason to keep it: the source text contains real OCR damage — US10123456B2
    /// claim 5 reads "wherein fon ling the internal matrix" — which a model will silently
    /// correct to "forming". The corrected version is then a quotation that is not in the
    /// passage, and this is what surfaces that rather than hiding it.
    private static func quoteCheck(_ log: Log) {
        let passage = """
            The lower shell, the upper shell and the internal matrix are formed as a \
            single component using additive manufacturing techniques.
            """
        log.equal(
            QuoteCheck.unsupported(
                in: "It says they are \"formed as a single component\".", passage: passage),
            [], "a quotation from the passage passes")
        log.equal(
            QuoteCheck.unsupported(
                in: "the \"hermetically sealed cavity\" is what matters", passage: passage),
            ["hermetically sealed cavity"],
            "a quotation from outside the passage is caught")
        log.equal(
            QuoteCheck.unsupported(in: "it uses \"a\" twice", passage: passage), [],
            "a span too short to prove anything is skipped")
        // Curly and straight quotation marks are the same quotation.
        log.equal(
            QuoteCheck.unsupported(
                in: "“formed as a single component”", passage: passage),
            [], "curly quotes are not a difference")
    }

    private static func followUpParsing(_ log: Log) {
        let plain = """
            1. What does the internal matrix do?
            2. Does claim 7 require expansion plugs?
            3. How is the cavity sealed?
            4. What is element 100?
            """
        log.equal(Prompts.FollowUps.parse(plain).count, 4, "a clean numbered list")
        log.equal(
            Prompts.FollowUps.parse("1) Why the first one?\n2) Why the second one?").count,
            2, "the `1)` style")
        log.equal(
            Prompts.FollowUps.parse("1. **What does the matrix do**\n2. Another").first,
            "What does the matrix do?", "bold markers stripped, question mark added")

        // A statement is not a question. Appending a bare "?" to a declarative sentence
        // produced rows like "It uses a phase change material.?"
        log.equal(
            Prompts.FollowUps.parse(
                "1. It uses a phase change material.\n2. Why is the matrix parallel"),
            ["Why is the matrix parallel?"],
            "a declarative item rejected, an interrogative one completed")
        log.equal(
            Prompts.FollowUps.parse("1. How is the cavity sealed.").first,
            "How is the cavity sealed?", "a trailing stop replaced rather than doubled")

        log.equal(
            Prompts.FollowUps.parse(
                "Here are some questions:\n1. First?\n2. Second?\n3. Third?\n4. Fourth?"
            ).count, 4, "a preamble line ignored")
        log.equal(
            Prompts.FollowUps.parse("1. Same question?\n2. same question?\n3. Other?")
                .count, 2, "duplicates collapsed")
        log.equal(
            Prompts.FollowUps.parse(
                "1. What is one?\n2. What is two?\n3. What is three?\n4. What is four?\n"
                    + "5. What is five?"
            ).count, 4, "capped at four")
        log.equal(
            Prompts.FollowUps.parse(
                "1. Already asked?\n2. Fresh one?",
                asked: [Prompts.FollowUps.normalized("Already asked?")]),
            ["Fresh one?"], "dedupe against questions already asked")
        log.equal(Prompts.FollowUps.parse("1. ok").count, 0, "a two-character question")
        log.equal(
            Prompts.FollowUps.parse("1. \(String(repeating: "long ", count: 40))").count, 0,
            "a paragraph masquerading as a question")

        // A question that *opens* with a quoted phrase keeps both its quotes.
        log.equal(
            Prompts.FollowUps.parse("1. \"internal matrix\" — what is it made of?").first,
            "\"internal matrix\" — what is it made of?",
            "an opening quoted phrase survives intact")
        log.equal(
            Prompts.FollowUps.parse("1. \"What does claim 7 cover?\"").first,
            "What does claim 7 cover?", "a wrapped question is unwrapped")
    }

    // MARK: - Golden prompt render

    /// One assembled prompt compared against a checked-in string.
    ///
    /// This is what catches prompt drift: any change to the labelled blocks, the passage
    /// headings or the closing contract shows up here as a diff, and the fix is to
    /// regenerate this string *deliberately*, alongside a `Prompts.version` bump.
    private static func goldenPromptRender(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the golden render")
            return
        }
        guard let context = goldenContext(patent) else {
            log.fail("the golden context did not build")
            return
        }

        let rendered = Prompts.answerRequest(context)
        if rendered != Self.goldenPrompt {
            log.fail(
                """
                the golden prompt render drifted. If the change was intended, bump \
                Prompts.version and replace SelfTest.goldenPrompt with:
                ----- begin -----
                \(rendered)
                ----- end -----
                """)
        }

        // The digest covers the question *and* the passages. Both halves matter: the same
        // question over different passages is a different answer, and a cache that
        // ignored the passages would attach the old answer's citations to a set the model
        // was never shown — manufacturing the `.unretrieved` failure the app exists to
        // surface.
        guard let same = goldenContext(patent),
            var different = goldenContext(patent)
        else { return }
        log.equal(context.digest, same.digest, "the same context digests the same")
        different.question = "something else entirely"
        log.check(
            context.digest != different.digest,
            "a different question digests the same")
        var fewer = context
        fewer.passages = Array(context.passages.dropLast())
        log.check(
            context.digest != fewer.digest, "a different passage set digests the same")

        // One patent in scope means bare citations; several means qualified. Getting this
        // backwards teaches the model a form the scanner does not accept.
        log.check(
            rendered.contains("Write a citation exactly as it is headed above: [0042]"),
            "a single-patent prompt does not ask for the bare citation form")
        log.check(
            !rendered.contains("[0042] of US 10,123,456 B2"),
            "a single-patent prompt asks for the qualified form")
    }

    /// The context the golden prompt is rendered from. Deterministic: fixed passages, in
    /// a fixed order, so the only thing that can move the render is `Prompts`.
    private static func goldenContext(_ patent: Patent) -> AnswerContext? {
        let targets: [CitationTarget] = [
            .paragraph(ParagraphKey(patent: patent.key, number: 19)),
            .claim(ClaimKey(patent: patent.key, number: 2)),
        ]
        let chunks = Chunker.chunks(for: patent)
        let picked = targets.compactMap { target in
            chunks.first { $0.target == target }
        }
        guard picked.count == targets.count else { return nil }

        return AnswerContext.build(
            question: "how is the internal matrix formed?",
            retrieved: picked.map {
                RetrievedChunk(
                    chunk: $0, denseScore: nil, denseRank: nil, lexicalScore: nil,
                    lexicalRank: nil, fusedScore: 1)
            },
            library: [patent],
            isLexicalOnly: false)
    }

    /// Regenerated deliberately, alongside a `Prompts.version` bump.
    private static let goldenPrompt = """
        PATENTS IN SCOPE:
        - US 10,123,456 B2 — Phase change material heat sink using additive manufacturing and method

        INDEPENDENT CLAIMS:
        claim 1: A method comprising: using additive manufacturing techniques: forming a structural component; forming a lower shell of a heat sink; forming an internal matrix of the heat sink, the internal matrix comprising a plurality of parallel pins arranged in a grid pattern; and forming an upper shell of the heat sink, wherein the lower shell, the internal matrix, and the upper shell of the heat sink comprise a single-structure component that is incorporated into the structural component, such that the heat sink and the structural component are integral.
        claim 10: A method comprising: using additive manufacturing techniques: forming a structural component; forming a lower shell of a heat sink; forming an internal matrix of the heat sink, the internal matrix comprising a plurality of parallel plates; and forming an upper shell of the heat sink, wherein the lower shell, the internal matrix, and the upper shell of the heat sink comprise a single-structure component that is incorporated into the structural component, such that the heat sink and the structural component are integral.
        claim 18: A method comprising: forming a structural component, a lower shell of a heat sink, an internal matrix of the heat sink, and an upper shell of the heat sink using additive manufacturing techniques, wherein the lower shell, the internal matrix, and the upper shell of the heat sink comprise a single-structure component that is incorporated into the structural component, such that the heat sink and the structural component are integral, wherein the internal matrix comprises a plurality of parallel plates or a plurality of parallel pins; using additive manufacturing techniques, forming a fill port and a vent port in the upper shell of the heat sink; inserting a phase change material into the heat sink via the fill port; and sealing the fill port and the vent port with seal plugs.

        QUESTION: how is the internal matrix formed?

        RETRIEVED PASSAGES — these are the only things you may cite:

        [0019]
        As a result, the heat sink 100 is less expensive to produce and more robust than conventional heat sinks. Additive manufacturing also allows for the possibility to generate the lower and upper shells 102 and 104, as well as the internal matrix 106, with more complex designs to address specific issues such as dissipating heat from high power density components. Thus, the design of the internal matrix 106 is not limited to a metal foam or other design that can be formed using traditional machining techniques. For example, a complex internal matrix 106 may be designed to optimize heat transport, maximize volume allocated for phase change material, and provide suitable PCM filling paths. This design may be customized to provide the most efficient removal of heat from a particular application and to optimize heat transfer into the phase change material.

        claim 2
        The method of claim 1, further comprising, using additive manufacturing techniques, forming a fill port and a vent port in the upper shell of the heat sink.

        Answer in 60-140 words. Every claim you make carries a citation, placed immediately after the clause it supports rather than at the end. Write a citation exactly as it is headed above: [0042], or claim 7. Cite only from the passages above — a paragraph that is not in that list does not exist for this answer. If those passages do not answer the question, say so in one sentence and cite nothing; that is a better answer than a cited guess.
        """

    // MARK: - Reader fonts

    /// The typeface picker's inputs. Model-free and network-free.
    ///
    /// Nothing here may touch `ReaderFontLibrary`, which is `@MainActor` while `run()` is
    /// synchronous and non-isolated — which is exactly why `installedFamilyNames()` is a
    /// `static` on `ReaderFont` that the library merely calls.
    private static let plausibleOpticalScales: ClosedRange<CGFloat> = 0.9 ... 1.3

    private static func readerFonts(_ log: Log) {
        for font in ReaderFont.allCases {
            // Literally the `@AppStorage("readerFont")` contract: a raw value that stops
            // round-tripping silently resets every reader to the system face.
            log.check(
                ReaderFont(rawValue: font.rawValue) == font,
                "ReaderFont.\(font) does not round-trip through its raw value")
            log.check(
                plausibleOpticalScales.contains(font.opticalScale),
                "ReaderFont.\(font) opticalScale \(font.opticalScale) is outside "
                    + "\(plausibleOpticalScales), which is not an optical correction")
        }

        log.equal(
            Set(ReaderFont.allCases.map(\.displayName)).count, ReaderFont.allCases.count,
            "the number of distinct display names")
        log.check(
            ReaderFont.system.familyName == nil,
            "the system face should not name a family")
        for font in ReaderFont.allCases where font != .system {
            log.check(font.familyName != nil, "ReaderFont.\(font) names no family")
        }

        // The only nontrivial logic in the feature, and pure CoreText: Baskerville has a
        // real italic cut, Big Caslon is a single face and has none.
        log.check(
            ReaderFont.baskerville.hasItalicFace,
            "Baskerville reported no italic face")
        log.check(
            !ReaderFont.caslon.hasItalicFace,
            "Big Caslon reported an italic face, so the synthetic oblique is dead code")

        // Machine-dependent, and kept anyway: a typo like "BigCaslon" is otherwise
        // completely silent — the reader would just get the system face forever.
        let installed = ReaderFont.installedFamilyNames()
        for font in [ReaderFont.caslon, .baskerville] {
            guard let family = font.familyName else { continue }
            log.check(
                installed.contains(family),
                "\"\(family)\" is not among the installed font families, so "
                    + "ReaderFont.\(font) would silently render as the system face")
        }
    }

    private static let plausibleTextSizeMultipliers: ClosedRange<CGFloat> = 0.7 ... 1.7

    /// The size ladder's inputs, and the arithmetic `ReaderTypeface` does with them.
    ///
    /// No `Font` is constructed except where comparing one is the point. `installed: []`
    /// short-circuits `hasItalicFace`, so nothing here reaches CoreText or the
    /// `@MainActor` `ReaderFontLibrary`.
    private static func readerTextSizes(_ log: Log) {
        func typeface(_ size: ReaderTextSize, at category: DynamicTypeSize = .large)
            -> ReaderTypeface
        {
            ReaderTypeface(
                .system, textSize: size, dynamicTypeSize: category, installed: [])
        }

        for size in ReaderTextSize.allCases {
            log.check(
                ReaderTextSize(rawValue: size.rawValue) == size,
                "ReaderTextSize.\(size) does not round-trip through its raw value")
            log.check(
                plausibleTextSizeMultipliers.contains(size.multiplier),
                "ReaderTextSize.\(size) multiplier \(size.multiplier) is outside "
                    + "\(plausibleTextSizeMultipliers), which is not a reading size")
            log.equal(
                size.isDefault, size.multiplier == 1,
                "ReaderTextSize.\(size).isDefault against a multiplier of exactly 1")
        }

        log.equal(ReaderTextSize.default.multiplier, 1, "the default multiplier")
        log.equal(
            ReaderTextSize.allCases.filter(\.isDefault).count, 1,
            "the number of neutral size steps")

        // Declaration order is menu order, so the multipliers have to rise along it.
        for (smaller, bigger) in zip(
            ReaderTextSize.allCases, ReaderTextSize.allCases.dropFirst())
        {
            log.check(
                smaller.multiplier < bigger.multiplier,
                "ReaderTextSize.\(smaller) does not sort below \(bigger)")
        }

        // The default is exactly the bare text style, on the identical code path rather
        // than an arithmetically equivalent one — only the text style follows Dynamic
        // Type, so the two are not interchangeable.
        let shipped = ReaderTypeface.system
        log.equal(shipped.body, .body, "the shipped body font")
        log.equal(shipped.sectionHeading, .headline, "the shipped heading font")
        log.equal(shipped.bodyItalic, .body.italic(), "the shipped italic font")
        log.equal(
            shipped.gutterFont, .caption2.monospacedDigit(), "the shipped gutter font")
        log.equal(shipped.gutterWidth, 42, "the shipped gutter width")
        log.equal(shipped.measure, 640, "the shipped reading measure")
        log.equal(shipped.blockGap, 10, "the shipped block gap")
        log.equal(shipped.claimIndent, 18, "the shipped claim indent")

        // And the other direction, which would catch the whole feature quietly becoming a
        // no-op for the system face.
        log.check(
            typeface(.large).body != .body,
            "the system face at the Large step still returns `Font.body`")

        // End-to-end through the rounding: a ladder whose steps round to the same size is
        // still a ladder, one that goes *down* somewhere is not.
        for (smaller, bigger) in zip(
            ReaderTextSize.allCases, ReaderTextSize.allCases.dropFirst())
        {
            let low = typeface(smaller)
            let high = typeface(bigger)
            log.check(
                low.blockGap <= high.blockGap,
                "the block gap falls from \(smaller) to \(bigger)")
            log.check(
                low.measure < high.measure,
                "the reading measure does not grow from \(smaller) to \(bigger)")
            log.check(
                low.gutterWidth <= high.gutterWidth,
                "the gutter width falls from \(smaller) to \(bigger)")
        }

        // What makes `DocumentReaderView`'s `.onChange(of: typeface)` re-anchor the
        // scroll position when only the size changed.
        log.check(
            typeface(.default) != typeface(.largest),
            "two size steps of the same face compare equal, so a size change would not "
                + "re-anchor the reader's scroll position")
        log.check(
            typeface(.large) == typeface(.large),
            "the same face and size compare unequal, so every render would re-anchor")
        log.check(
            typeface(.large, at: .large) != typeface(.large, at: .accessibility5),
            "two Dynamic Type categories compare equal, so the text would not follow the "
                + "reader's Larger Text setting")

        // The two multipliers meet in `ReaderTypeface.scale`, and it is their *product*
        // that sets the type.
        let plausibleProducts: ClosedRange<CGFloat> = 0.7 ... 2.0
        for font in ReaderFont.allCases {
            for size in ReaderTextSize.allCases {
                let product = font.opticalScale * size.multiplier
                log.check(
                    plausibleProducts.contains(product),
                    "\(font) at \(size) scales the type by \(product), outside "
                        + "\(plausibleProducts)")
            }
        }
    }

    // MARK: - Reading position and history

    /// The two pure seams of the restore — the record's codec, and resolving a record
    /// against the library — plus the back stack.
    ///
    /// Nothing here touches `ProgressStore`'s `UserDefaults`, so `--selftest` cannot read
    /// or overwrite the real reader's position.
    private static func readingProgress(_ log: Log) {
        guard let patent = parsed("US10123456B2"), let other = parsed("US5000000A") else {
            log.fail("could not load the fixtures for the reading-progress checks")
            return
        }
        let library = [patent, other]

        let selection = PassageSelection(anchor: 12, head: 20)
        let record = ReadingProgress(
            schemaVersion: ProgressStore.schemaVersion, patent: patent.key,
            selection: selection, stamp: patent.source.contentSHA256)

        guard let data = try? JSONEncoder().encode(record),
            let back = try? JSONDecoder().decode(ReadingProgress.self, from: data)
        else {
            log.fail("a record did not round-trip through JSON")
            return
        }
        log.equal(back, record, "a record carrying a selection")

        // A cold start: the first patent, nothing selected.
        let cold = ProgressStore.opening(from: nil, in: library)
        log.equal(cold.patent, library.first?.key, "the opening with no stored record")
        log.check(cold.selection == nil, "a cold start should select nothing")

        // The ordinary case.
        let restored = ProgressStore.opening(from: record, in: library)
        log.equal(restored.patent, patent.key, "the restored patent")
        log.equal(restored.selection, selection, "the restored selection")

        // A patent that is no longer in the library, which would otherwise leave the
        // reader on an empty pane forever.
        var removed = record
        removed.patent = PatentKey(country: "US", serial: "9999999", kind: "B2")
        log.equal(
            ProgressStore.opening(from: removed, in: library).patent, library.first?.key,
            "the opening for a patent the library no longer has")

        // A re-imported patent keeps the document and drops the highlight, rather than
        // putting it over whatever rows those indices now name.
        var drifted = record
        drifted.stamp = "not the digest of anything"
        let afterDrift = ProgressStore.opening(from: drifted, in: library)
        log.equal(afterDrift.patent, patent.key, "the patent after the source changed")
        log.check(
            afterDrift.selection == nil,
            "a selection should be dropped when the stamp does not match")

        // A record written against a longer document.
        var past = record
        past.selection = PassageSelection(anchor: 99_999, head: 99_999)
        log.equal(
            ProgressStore.opening(from: past, in: library).selection,
            PassageSelection(at: patent.rows.count - 1),
            "a selection past the end of the document")

        // MARK: The back stack

        var history = NavigationHistory()
        log.check(!history.canGoBack, "a fresh history has nothing to go back to")

        let first = NavigationHistory.Position(patent: patent.key, row: 5)
        let second = NavigationHistory.Position(patent: other.key, row: 9)
        history.push(first)
        log.check(history.canGoBack, "a pushed position is reachable")
        log.equal(history.goBack(from: second), first, "going back")
        log.check(history.canGoForward, "going back leaves something to go forward to")
        log.equal(history.goForward(from: first), second, "going forward")

        // A new jump clears the forward stack, which is the standard rule: an undone
        // history the reader cannot describe a route to is unreachable.
        history.push(first)
        _ = history.goBack(from: second)
        history.push(second)
        log.check(!history.canGoForward, "a new jump did not clear the forward stack")

        // Deleting a patent prunes the entries naming it, or ⌘[ eventually lands on a
        // document that does not exist.
        history = NavigationHistory()
        history.push(first)
        history.push(second)
        history.prune(to: [patent.key])
        log.check(history.canGoBack, "pruning removed an entry it should have kept")
        log.equal(
            history.goBack(from: second), first,
            "pruning left an entry naming a deleted patent")

        // The cap. A reader who clicks forty chips should not have forty entries to
        // unwind.
        history = NavigationHistory()
        for row in 0 ..< 100 {
            history.push(NavigationHistory.Position(patent: patent.key, row: row))
        }
        var depth = 0
        while history.canGoBack, depth < 200 {
            _ = history.goBack(from: first)
            depth += 1
        }
        log.check(depth <= 32, "the back stack grew past its cap: \(depth)")
    }

    // MARK: - Word lookup

    /// Where one word of the text begins and ends.
    ///
    /// Ported, and retargeted at the punctuation patents have rather than the punctuation
    /// verse has: hyphenated compounds, alphanumeric part designations, and decimals.
    private static func wordTokenizer(_ log: Log) {
        func words(_ text: String) -> [String] {
            WordTokenizer.words(in: text).map { String(text[$0]) }
        }

        /// The invariant that makes a hover mark trustworthy: the ranges tile the string.
        /// Ordered, non-overlapping, non-empty, and everything they leave out is
        /// punctuation or space — a gap with a letter in it is a word the reader can
        /// point at and be told nothing about.
        func tiles(_ text: String, _ label: String) {
            let ranges = WordTokenizer.words(in: text)
            var cursor = text.startIndex
            for range in ranges {
                log.check(!range.isEmpty, "\(label): an empty word range in \"\(text)\"")
                log.check(
                    range.lowerBound >= cursor,
                    "\(label): word ranges overlap or run backwards in \"\(text)\"")
                for character in text[cursor ..< range.lowerBound] {
                    log.check(
                        !character.isLetter && !character.isNumber,
                        "\(label): \"\(character)\" in \"\(text)\" is in no word")
                }
                cursor = range.upperBound
            }
            for character in text[cursor...] {
                log.check(
                    !character.isLetter && !character.isNumber,
                    "\(label): trailing \"\(character)\" in \"\(text)\" is in no word")
            }
            for range in ranges {
                for index in text[range].indices {
                    log.equal(
                        WordTokenizer.word(at: index, in: text), range,
                        "\(label): the word at \"\(text[index])\" in \"\(text)\"")
                }
            }
        }

        log.equal(
            words("the heat sink 100 is less expensive"),
            ["the", "heat", "sink", "100", "is", "less", "expensive"],
            "a sentence with a reference numeral")
        // Hyphenated compounds stay whole, which patents are full of and `.byWords` gets
        // wrong on its own.
        log.equal(
            words("hour-glass shaped pins"), ["hour-glass", "shaped", "pins"],
            "a hyphenated compound")
        log.equal(
            words("thermally-conductive matrix"), ["thermally-conductive", "matrix"],
            "another hyphenated compound")

        func term(_ text: String) -> String {
            guard let range = WordTokenizer.words(in: text).first else { return "" }
            return WordTokenizer.term(for: range, in: text)
        }
        log.equal(term("matrix,"), "matrix", "the term of \"matrix,\"")
        log.equal(term("hour-glass"), "hour-glass", "the term of \"hour-glass\"")

        let line = "the heat sink"
        guard let space = line.firstIndex(of: " ") else {
            log.fail("no space in a string with two of them")
            return
        }
        log.check(
            WordTokenizer.word(at: space, in: line) == nil, "a space resolved to a word")

        tiles("", "an empty line")
        for text in [
            "the heat sink 100 is less expensive", "hour-glass shaped pins, 0.5 mm apart",
            "H05K7/20336 and US 10,123,456 B2",
        ] {
            tiles(text, "a hand-written line")
        }

        // And against the real thing, because the invariant is about punctuation the
        // corpus has and hand-written strings do not.
        guard let patent = parsed("US10123456B2") else { return }
        for row in patent.rows {
            tiles(row.plainText, "US10123456B2 row \(row.index)")
        }
    }

    // MARK: - Fixtures for the synthetic suites

    private static func fakeSource() -> Source {
        Source(
            kind: .googlePatentsHTML, url: nil, retrieved: Date(timeIntervalSince1970: 0),
            contentSHA256: "0", parserVersion: GooglePatentsParser.version, note: nil)
    }

    private static func fakePatent(
        _ key: PatentKey, paragraphs: [Int], claims: [Int]
    ) -> Patent {
        Patent(
            schemaVersion: 1,
            id: key.slug,
            key: key,
            title: "Test patent",
            abstract: "An abstract.",
            inventors: ["A. Inventor"],
            assignee: nil,
            publicationDate: nil,
            priorityDate: nil,
            classifications: [],
            numbering: .printed,
            source: fakeSource(),
            sections: [
                SpecSection(
                    heading: "DETAILED DESCRIPTION",
                    paragraphs: paragraphs.enumerated().map { offset, number in
                        Paragraph(
                            index: offset, number: number,
                            text: "Paragraph \(number) of the test patent.",
                            hasPrintedNumber: true)
                    })
            ],
            claims: claims.map {
                Claim(
                    number: $0, text: "Claim \($0).", elements: [], dependsOn: [],
                    dependencySource: .none)
            },
            calloutNumerals: [:])
    }

    private static func fakeContext(
        question: String, retrieved: [CitationTarget], patents: [PatentKey]
    ) -> AnswerContext {
        AnswerContext(
            question: question,
            entries: patents.map {
                AnswerContext.Entry(
                    key: $0, title: "Test patent", numbering: .printed,
                    independentClaims: [])
            },
            passages: retrieved.map {
                AnswerContext.Passage(
                    target: $0,
                    label: AnswerContext.label(
                        $0, numbering: .printed, qualified: patents.count > 1),
                    text: "passage text")
            },
            retrieved: Set(retrieved),
            isCrossPatent: patents.count > 1,
            isLexicalOnly: false)
    }
}

/// `--show-prompt`: renders the assembled prompt and its exact token count for a sample
/// of questions, then exits.
///
/// The token count is the real one, from
/// `tokenizer.applyChatTemplate(messages:tools:additionalContext:)`, which is why this
/// loads the model. It also prints the retrieved chunks with each leg's rank, which is
/// how a retrieval regression gets diagnosed without a rebuild.
@MainActor
enum PromptDump {

    static func run(options: AppOptions) async -> Bool {
        let library = LibraryService()
        library.load()
        guard !library.patents.isEmpty else {
            print("the library is empty — import a patent first")
            return false
        }

        let service = AnswerService(
            modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
            greedy: options.greedy)
        await service.load()
        guard service.isReady else {
            print("the model did not load; cannot report exact token counts")
            return false
        }

        let scope = Self.scope(options, in: library)
        let questions = options.questions.isEmpty ? SampleQuestions.all : options.questions
        var counted: [(String, Int)] = []

        for question in questions {
            let vector = await library.embedder.embed(query: question)
            let chunks = Retriever.retrieve(
                question: question, queryVector: vector, index: library.index, scope: scope)
            guard
                let context = AnswerContext.build(
                    question: question, retrieved: chunks, library: library.patents,
                    isLexicalOnly: vector == nil)
            else {
                print("nothing retrieved for: \(question)")
                continue
            }

            let request = Prompts.answerRequest(context)
            let tokens = await service.promptTokenCount(for: request)
            counted.append((question, tokens))

            print(String(repeating: "=", count: 78))
            print("\(question) — \(tokens) prompt tokens\(vector == nil ? " (lexical only)" : "")")
            print(String(repeating: "-", count: 78))
            for chunk in chunks {
                let dense = chunk.denseRank.map(String.init) ?? "–"
                let lexical = chunk.lexicalRank.map(String.init) ?? "–"
                print(
                    String(
                        format: "  %-28@ dense %@  bm25 %@  fused %.4f",
                        chunk.chunk.target.slug, dense, lexical, chunk.fusedScore))
            }
            print(String(repeating: "-", count: 78))
            print(request)
            print()
        }

        print(String(repeating: "=", count: 78))
        print("prompt token counts (system instructions and chat template included)")
        for (question, tokens) in counted {
            print(String(format: "  %5d  %@", tokens, question))
        }
        let counts = counted.map(\.1)
        if let low = counts.min(), let high = counts.max(), !counts.isEmpty {
            print("  min \(low) · max \(high) · mean \(counts.reduce(0, +) / counts.count)")
        }
        return !counted.isEmpty
    }

    /// `--patent` narrows the search, as `--passage` narrowed it next door.
    static func scope(_ options: AppOptions, in library: LibraryService) -> Set<PatentKey>? {
        let keys = options.patents.compactMap(PatentNumberParser.parse)
        guard !keys.isEmpty else { return nil }
        return Set(
            library.patents.map(\.key).filter { key in
                keys.contains { $0.country == key.country && $0.serial == key.serial }
            })
    }
}
