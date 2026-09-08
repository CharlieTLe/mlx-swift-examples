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
        originalPDFLink(log)
        claimTree(log)
        patentNumbers(log)
        citations(log)
        citationScanner(log)
        citationCheck(log)
        chunking(log)
        lexicalRetrieval(log)
        indexIntegrity(log)
        pdfParagraphRecovery(log)
        // The PDF tab's two testable halves: reading the link out of a stored page, and
        // deciding what to say when there is no PDF. Deliberately no suite for
        // `PatentPDFService.pages`, which is a dictionary, or for `PatentPDFView`, which
        // would be asserting PDFKit's own notification behaviour — `pdfParagraphRecovery`
        // refuses that for the same reason. The manual checklist in the README stands in
        // for the representable.
        originalPDFAvailability(log)
        librarySearch(log)
        passageAnchors(log)
        passagePlacement(log)
        highlightPlan(log)
        passageLookup(log)
        documentFind(log)
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
        /// The filename at the end of the page's `citation_pdf_url`. In the table rather
        /// than in the suite so that this stays the single description of each fixture —
        /// and because three of these four drop the kind code and one keeps it, which is
        /// the fact `originalPDFLink` exists to pin down.
        let pdfFilename: String
        /// How many of this fixture's paragraphs are too short for a six-word anchor, and
        /// therefore cannot be located in the office's PDF at all.
        ///
        /// Pinned because it is the app's central promise expressed as a number. A parser
        /// change that starts splitting paragraphs, or an anchor rule that gets longer,
        /// shows up here as a build failure rather than as a reader clicking a chip and
        /// being told the passage cannot be found. See `passageAnchors`.
        let unanchorableParagraphs: Int
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "US10123456B2", paragraphs: 41, claims: 21, independentClaims: 3,
            sections: 5, numbering: .printed, dependencySource: .markup,
            assignee: "Raytheon Co", numerals: 12, pdfFilename: "US10123456.pdf",
            unanchorableParagraphs: 0),
        Fixture(
            name: "US20140030575A1", paragraphs: 97, claims: 20, independentClaims: 2,
            sections: 15, numbering: .printed, dependencySource: .markup,
            assignee: "Individual", numerals: 27, pdfFilename: "US20140030575A1.pdf",
            unanchorableParagraphs: 0),
        Fixture(
            name: "US7654321B2", paragraphs: 93, claims: 26, independentClaims: 6,
            sections: 4, numbering: .synthesized, dependencySource: .markup,
            assignee: "Schlumberger Technology Corp", numerals: 104,
            pdfFilename: "US7654321.pdf", unanchorableParagraphs: 1),
        Fixture(
            name: "US5000000A", paragraphs: 89, claims: 7, independentClaims: 2,
            sections: 34, numbering: .synthesized, dependencySource: .text,
            assignee: "University of Florida", numerals: 1,
            pdfFilename: "US5000000.pdf", unanchorableParagraphs: 0),
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

    /// The link to the office's own PDF, read out of each fixture's `<meta>`.
    ///
    /// The assertion that earns this suite its place is the third one: **at least one
    /// fixture's PDF filename is not its patent number**. Everything else here would pass
    /// against a `"\(slug).pdf"` string concatenation, and that concatenation is right for
    /// three of these four documents — which is exactly the shape of change that gets made
    /// as a simplification and then 404s for a quarter of a reader's library.
    private static func originalPDFLink(_ log: Log) {
        for fixture in fixtures {
            guard let html = fixtureHTML(fixture.name) else {
                log.fail("the \(fixture.name) fixture is missing from the bundle")
                continue
            }
            guard let url = PatentPDFLink.url(inPageHTML: html) else {
                log.fail("\(fixture.name) has no citation_pdf_url")
                continue
            }
            log.equal(url.scheme, "https", "\(fixture.name) PDF scheme")
            log.equal(
                url.host(), "patentimages.storage.googleapis.com",
                "\(fixture.name) PDF host")
            log.equal(
                url.lastPathComponent, fixture.pdfFilename, "\(fixture.name) PDF filename")
        }

        log.check(
            fixtures.contains { $0.pdfFilename != "\($0.name).pdf" },
            "constructing the PDF URL from the patent number would work for these "
                + "fixtures — the meta must still be read rather than the URL built")

        // A page with metas but no `citation_pdf_url`: the shape a stripped or redesigned
        // page takes, and the one that has to report rather than guess.
        log.check(
            PatentPDFLink.url(
                inPageHTML: "<html><head><meta name=\"DC.title\" content=\"A patent\">"
                    + "</head></html>") == nil,
            "a page with no citation_pdf_url produced a URL")
        log.check(
            PatentPDFLink.url(
                inPageHTML: "<html><head><meta name=\"citation_pdf_url\" content=\"\">"
                    + "</head></html>") == nil,
            "an empty citation_pdf_url produced a URL")
        log.check(
            PatentPDFLink.url(
                inPageHTML: "<html><head><meta name=\"citation_pdf_url\" content=\"   \">"
                    + "</head></html>") == nil,
            "a whitespace citation_pdf_url produced a URL")

        // Three schemes that must not survive, each named. This URL comes out of a
        // document fetched over the network and goes straight to `URLSession`.
        for (scheme, content) in [
            ("http", "http://patentimages.storage.googleapis.com/a.pdf"),
            ("file", "file:///etc/passwd"),
            ("javascript", "javascript:alert(1)"),
        ] {
            log.check(
                PatentPDFLink.url(
                    inPageHTML:
                        "<html><head><meta name=\"citation_pdf_url\" content=\"\(content)\">"
                        + "</head></html>") == nil,
                "a \(scheme): citation_pdf_url was accepted")
        }

        // The entity decoding is `HTMLScanner`'s, which is the reason this reuses the
        // scanner rather than growing a regex for one attribute: a hand-rolled match would
        // hand `URL` the literal `&amp;` and produce a query nobody wrote.
        let escaped = PatentPDFLink.url(
            inPageHTML: "<html><head><meta name=\"citation_pdf_url\" "
                + "content=\"https://example.com/a.pdf?x=1&amp;y=2\"></head></html>")
        log.equal(escaped?.query(), "x=1&y=2", "the PDF URL's entities were not decoded")
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

    /// The PDF path's refusals, and the two cover-page shapes it has to read.
    ///
    /// Driven through `PatentPDFImporter.patent(fromPages:url:title:)` on synthetic lines
    /// rather than through PDFKit, because what is worth asserting is the recovery —
    /// which line opens a paragraph, where the claims start, which of the numbers on a
    /// cover page is the document's — and building a PDF to assert it through would be
    /// asserting PDFKit.
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

        pdfPCTPublication(log)
        pdfPCTApplicationAsFiled(log)
        pdfCoverPageNumber(log)
        pdfMergedParagraphs(log)
    }

    /// What the Original PDF tab shows, and what it says when it has nothing to show.
    ///
    /// Driven through the pure `PatentPDFAvailability.availability(...)` with a real
    /// stored page, so the whole of the decision and the whole of the copy are asserted
    /// without a view, a file or a network — the same discipline `pdfParagraphRecovery`
    /// applies to the importer's refusals.
    private static func originalPDFAvailability(_ log: Log) {
        guard let html = fixtureHTML("US10123456B2") else {
            log.fail("the US10123456B2 fixture is missing from the bundle")
            return
        }
        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        let file = URL(fileURLWithPath: "/tmp/US10123456B2.source.pdf")

        // A fetched patent whose copy has arrived.
        if case .onDisk(let found) = PatentPDFAvailability.availability(
            kind: .googlePatentsHTML, cachedFile: file, storedPageHTML: html)
        {
            log.equal(found, file, "the stored PDF's URL")
        } else {
            log.fail("a fetched patent with its PDF on disk is not readable")
        }

        // **The retroactive case, and the requirement most worth a test**: a patent
        // imported long before this feature existed, with nothing on disk but the page it
        // was parsed from, gains a working PDF tab with no re-import and no second request
        // for the page.
        if case .downloadable(let url) = PatentPDFAvailability.availability(
            kind: .googlePatentsHTML, cachedFile: nil, storedPageHTML: html)
        {
            log.equal(
                url, PatentPDFLink.url(inPageHTML: html),
                "the recovered PDF URL disagrees with the page")
        } else {
            log.fail(
                "an already-imported patent does not recover its PDF from its stored page")
        }

        log.equal(
            PatentPDFAvailability.availability(
                kind: .googlePatentsHTML, cachedFile: nil, storedPageHTML: nil),
            .unavailable(.noStoredPage), "a fetched patent with no stored page")
        log.equal(
            PatentPDFAvailability.availability(
                kind: .googlePatentsHTML, cachedFile: nil,
                storedPageHTML: "<html><head></head></html>"),
            .unavailable(.noLinkInPage), "a stored page carrying no link")

        // The PDF import path, both ways round. Its bytes are the import, so nothing but
        // the reader can recover them.
        log.equal(
            PatentPDFAvailability.availability(
                kind: .pdf, cachedFile: file, storedPageHTML: nil),
            .onDisk(file), "an imported PDF with its copy kept")
        log.equal(
            PatentPDFAvailability.availability(
                kind: .pdf, cachedFile: nil, storedPageHTML: nil),
            .unavailable(.importedCopyGone), "an imported PDF with no copy kept")

        // `.plainText` is a case no importer produces today, which is exactly why it is
        // checked: it must report rather than fall through to a PDF that is not there.
        log.equal(
            PatentPDFAvailability.availability(
                kind: .plainText, cachedFile: nil, storedPageHTML: nil),
            .unavailable(.notAPDFSource), "a text import")
        log.equal(
            PatentPDFAvailability.availability(
                kind: .plainText, cachedFile: file, storedPageHTML: html),
            .unavailable(.notAPDFSource), "a text import with a stray file beside it")

        // The copy. Every reason says something, and the two with a remedy still name it —
        // a reword that drops the instruction fails the build rather than a reader's
        // afternoon.
        for reason in [
            PatentPDFAvailability.Reason.noStoredPage, .noLinkInPage, .importedCopyGone,
            .notAPDFSource,
        ] {
            log.check(!reason.headline.isEmpty, "\(reason) has no headline")
            log.check(!reason.detail(for: key).isEmpty, "\(reason) has no detail")
        }
        log.check(
            PatentPDFAvailability.Reason.noStoredPage.detail(for: key).contains("fetch"),
            "the missing-page report does not tell the reader to fetch the patent again")
        log.check(
            PatentPDFAvailability.Reason.noStoredPage.detail(for: key)
                .contains(key.display),
            "the missing-page report does not name the patent to remove")
        log.check(
            PatentPDFAvailability.Reason.importedCopyGone.detail(for: key)
                .contains("Import"),
            "the missing-copy report does not tell the reader to import the file again")

        // A captcha or an error page in place of the document, named with the host it came
        // from — the app's second network destination, and the one nothing else mentions.
        let notPDF = GooglePatentsSource.Failure.notPDF(
            host: "patentimages.storage.googleapis.com")
        log.check(
            notPDF.errorDescription?.contains("patentimages.storage.googleapis.com")
                ?? false,
            "the not-a-PDF failure does not name the host")
        log.check(
            notPDF.errorDescription?.contains("captcha") ?? false,
            "the not-a-PDF failure does not explain itself")
    }

    /// A PCT application as filed, which carries none of the structure the rest rely on.
    ///
    /// No `[nnnn]` markers are printed in one — the applicant did not number the
    /// paragraphs and no office added them — and PDFKit hands its pages back as one line
    /// per printed line with no blank line anywhere, so both readings that look for a
    /// marker or a blank line find not a single break in three hundred paragraphs. What it
    /// has instead is a numbered margin, and the page furniture that comes with it: a
    /// running head and a page number on every page, and the margin numbers themselves,
    /// one of which sits in front of a claim number and takes every later claim with it.
    ///
    /// Pages rather than lines, because that is what all three of those are defined
    /// against.
    private static func pdfPCTApplicationAsFiled(_ log: Log) {
        let head = "WO 2024/153586 PCT /EP2024/050800"
        let short = "and then it stops short of the margin."

        /// One spec page: a head, a page number, and four paragraphs whose first line
        /// carries the margin number and whose second stops short.
        func page(_ folio: Int, from first: Int) -> [String] {
            var lines = [head, "\(folio)"]
            for index in 0 ..< 4 {
                lines.append(
                    "\((index + 1) * 5) Paragraph \(first + index) opens here and runs on "
                        + "at the full measure of the page, as a justified line does,")
                lines.append(short)
            }
            return lines
        }

        let pages: [[String]] = [
            // The cover. Both field codes come out behind the glyph that extraction made
            // of the rule down the side of the block, so neither opens its line.
            [
                "~ (54) Title: ANTISENSE MOLECULES AND THEIR USES",
                "~ (57) Abstract: The invention relates to an oligonucleotide.",
            ],
            page(1, from: 1), page(2, from: 5), page(3, from: 9),
            [
                head, "4", "CLAIMS",
                "5 1. An antisense oligonucleotide, wherein it comprises a sequence set out in",
                "SEQ ID NO: 1 and one or more chemical modifications.",
                "10 2. The oligonucleotide of claim 1, wherein the modification is a locked",
                "nucleic acid modification.",
                // The one that mattered: a margin number in front of the claim number.
                // Unstripped, `10 3.` is not claim 3, and claims 3 onwards are lost.
                "15 3. The oligonucleotide of claim 2, wherein all nucleotides are modified.",
            ],
            // A drawing sheet, which is what follows the claims and has to not become the
            // text of the last one.
            [head, "1.0", "Cl) <(", "e>z in=", ".c >", "I *"],
        ]

        func imported(_ file: String) -> Patent? {
            try? PatentPDFImporter.patent(
                fromPages: pages, url: URL(fileURLWithPath: "/tmp/\(file).pdf"), title: nil)
        }

        guard let patent = imported("WO2024153586A1-pp") else {
            log.fail("a PCT application as filed does not import at all")
            return
        }

        let paragraphs = patent.sections.first?.paragraphs ?? []
        let body = paragraphs.filter { $0.text.hasPrefix("Paragraph ") }
        log.equal(patent.numbering, .synthesized, "the numbering of a document with no markers")
        log.equal(body.count, 12, "body paragraphs recovered from line lengths")
        // Worth pinning rather than filtering out: the cover page's own text is paragraphs
        // too. It is bibliographic data with no paragraph structure in it at all, and
        // showing it as rows is truer than dropping it on a guess about what prose looks
        // like.
        log.equal(
            paragraphs.count, body.count + 2,
            "the cover page's two field lines are paragraphs of their own")
        log.check(
            !paragraphs.contains { $0.text.contains("5 Paragraph") },
            "a margin number survived into the text of a paragraph")
        log.check(
            body.allSatisfy { $0.text.hasSuffix(short) },
            "a paragraph did not end where its line stopped short")
        // The same last line on every page, which is what pins the running-head rule to
        // position rather than to recurrence: a line repeated three times in the body is
        // not furniture, and a threshold that went by recurrence alone would delete it.
        log.check(
            body.count == 12 && body.allSatisfy { $0.text.contains(short) },
            "a body line repeated on every page was taken for a running head")
        log.check(
            !paragraphs.contains { $0.text.contains(head) },
            "the running head survived into the text of a paragraph")
        // The page number does two kinds of damage at once, and both are visible here: it
        // lands mid-sentence in the paragraph that spans the break, and — being two
        // characters — it breaks that paragraph in half as well.
        log.check(
            !paragraphs.contains { $0.text.contains("margin. 2") },
            "the page number survived into the text of a paragraph")
        log.check(
            patent.source.note?.contains("stop short of the full measure") ?? false,
            "the note does not admit that the paragraph breaks were inferred")

        log.equal(patent.claims.count, 3, "claims recovered past a margin-numbered page")
        log.equal(
            patent.claims.last?.text,
            "The oligonucleotide of claim 2, wherein all nucleotides are modified.",
            "the claim whose number a margin number preceded")
        log.check(
            !patent.claims.contains { $0.text.contains("Cl)") },
            "the drawing sheet after the claims was read as claim text")

        log.equal(
            patent.title, "Antisense molecules and their uses",
            "a title behind the glyph extraction made of the rule")
        // `-pp` is not a kind code, and the name is tried again without it.
        log.equal(
            patent.key, PatentKey(country: "WO", serial: "2024153586", kind: "A1"),
            "the number off a filename with a suffix on it")
        // A filename that names no office is a weaker claim about the office than the
        // document's own running head, which says WO on every page.
        log.equal(
            imported("2024153586")?.key,
            PatentKey(country: "WO", serial: "2024153586", kind: nil),
            "the number off the running head")
    }

    /// A PCT publication, which is where four things went wrong at once.
    ///
    /// Every one of them is silent on its own, which is why this fixture is one document
    /// rather than four: the marker width changes at paragraph 10 and again at 100, the
    /// claims carry no marker of their own, the number is labelled rather than prefixed,
    /// and an international search report is bound in after the claims. A recovery that
    /// handles three of the four still produces a document that looks imported.
    private static func pdfPCTPublication(_ log: Log) {
        var lines = [
            "(54) Title: METHODS OF PREPARING PROTEIN-OLIGONUCLEOTIDE COMPLEXES",
            "(74) Agent: GE, Zhiyun; 600 Atlantic Avenue, Boston, MA 02210-2206 (US).",
            "(10) International Publication Number: WO 2020/247738 A9",
        ]
        // WIPO writes the marker as `00` and the number, so one document prints [001],
        // [0010] and [00100] and only the middle band is four digits wide.
        for number in 1 ... 120 {
            lines.append(
                "[00\(number)] Paragraph \(number) of the specification, set out at "
                    + "enough length to read as prose.")
        }
        lines += [
            "CLAIMS",
            "What is claimed is:",
            "1. A method of isolating a complex, the method comprising contacting a",
            "mixture with a hydrophobic resin.",
            "2. The method of claim 1, wherein the resin is equilibrated first.",
            // A bare number alone on a line: extraction puts the claim number and its
            // text in different runs often enough that this is not a hypothetical.
            "3.",
            "The method of claim 2, wherein the elution solution is PBS.",
            "",
            "",
            "INTERNATIONAL SEARCH REPORT",
            "1. Claims Nos.: 5-28, because they are dependent claims.",
        ]

        guard
            let patent = try? PatentPDFImporter.patent(
                fromPages: [lines], url: URL(fileURLWithPath: "/tmp/WO2020247738A9.pdf"), title: nil
            )
        else {
            log.fail("a PCT publication does not import at all")
            return
        }

        let paragraphs = patent.sections.first?.paragraphs ?? []
        log.equal(paragraphs.count, 120, "the recovered paragraph count")
        log.equal(paragraphs.first?.number, 1, "the first paragraph's printed number")
        log.equal(paragraphs.last?.number, 120, "the last paragraph's printed number")
        // The failure this replaces: with a fixed-width marker the last paragraph that
        // matched swallows every later line, so it is the size of the document.
        log.check(
            paragraphs.allSatisfy { $0.text.count < 400 },
            "a paragraph swallowed the ones after it")
        log.check(
            !paragraphs.contains { $0.text.contains("What is claimed is") },
            "the claims were left inside the specification")

        log.equal(patent.claims.count, 3, "the recovered claim count")
        log.equal(
            patent.claims.last?.text,
            "The method of claim 2, wherein the elution solution is PBS.",
            "a claim whose number stood alone on its line")
        log.equal(patent.claims.last?.dependsOn, [2], "that claim's dependency")
        // The search report is a different document bound into the same file, and the
        // last claim is where it lands if nothing ends the claims.
        log.check(
            !patent.claims.contains { $0.text.contains("SEARCH REPORT") },
            "the appended search report was read as claim text")

        log.equal(
            patent.key, PatentKey(country: "WO", serial: "2020247738", kind: "A9"),
            "the number off a PCT cover page")
        log.equal(
            patent.title, "Methods of preparing protein-oligonucleotide complexes",
            "the title off a PCT cover page")
    }

    /// Which number on a cover page is the document's.
    ///
    /// The one that has to be got right by refusing rather than by guessing: an agent's
    /// address carries `Boston, MA 02210-2206`, which compacts to nine digits and is
    /// shaped exactly like a grant number. Filed under it, the patent is unfindable.
    private static func pdfCoverPageNumber(_ log: Log) {
        let body = (1 ... 4).map {
            "[000\($0)] Paragraph \($0), long enough to be read as a paragraph of prose."
        }
        func key(_ front: [String], file: String) -> PatentKey? {
            try? PatentPDFImporter.patent(
                fromPages: [front + body], url: URL(fileURLWithPath: "/tmp/\(file).pdf"), title: nil
            ).key
        }

        log.equal(
            key(["(10) Patent No.: US 10,123,456 B2"], file: "scan"),
            PatentKey(country: "US", serial: "10123456", kind: "B2"),
            "a US grant's labelled number")
        log.equal(
            key(["(10) Pub. No.: US 2014/0030575 A1"], file: "scan"),
            PatentKey(country: "US", serial: "20140030575", kind: "A1"),
            "a US pre-grant publication's labelled number")
        // Nothing labelled — which is the common case for a PCT publication, whose
        // number is set in the header artwork and never reaches the text layer — so the
        // filename is all there is.
        log.equal(
            key(
                ["(74) Agent: 600 Atlantic Avenue, Boston, MA 02210-2206 (US)."],
                file: "WO2020247738A9"),
            PatentKey(country: "WO", serial: "2020247738", kind: "A9"),
            "an unlabelled cover page falls back to the filename")
    }

    /// The net beneath the marker regex.
    ///
    /// Paragraph breaks that stop being found do not fail: every later line is appended
    /// to the last paragraph that did break, and the import succeeds, shows one
    /// unreadable row, and cites that one paragraph for most of the document. This is the
    /// check that turns it into a report.
    private static func pdfMergedParagraphs(_ log: Log) {
        let filler = Array(
            repeating: String(repeating: "unmarked prose that nothing recognises. ", count: 20),
            count: 40)

        func refusal(_ lines: [String]) -> PatentPDFImporter.Failure? {
            do {
                _ = try PatentPDFImporter.patent(
                    fromPages: [lines], url: URL(fileURLWithPath: "/tmp/US10123456B2.pdf"),
                    title: nil)
                return nil
            } catch {
                return error as? PatentPDFImporter.Failure
            }
        }

        // Markers that stop partway, which is a PCT publication whose numbering ran past
        // whatever width was matched.
        let stopped = refusal(["[0001] One paragraph.", "[0002] Two.", "[0003] Three."] + filler)
        log.equal(
            stopped, .paragraphsMerged(number: 3, percent: 100),
            "markers that stop partway")
        log.check(
            stopped?.errorDescription?.contains("Google Patents") ?? false,
            "the merged-paragraph failure does not say what to do instead")

        // No breaks found at all, which is an OCR'd grant: `[0001]` came out as `0001.`
        // so there are no markers, and the extraction has no blank lines to fall back on
        // either. One paragraph holding the whole document is the worst version of this
        // and has to be caught by the same check.
        log.equal(
            refusal(filler), .paragraphsMerged(number: 1, percent: 100),
            "an extraction with no paragraph breaks at all")

        // ...but a short document that is genuinely one paragraph is not a failure, and
        // the absolute floor is what keeps it from being reported as one.
        log.equal(
            refusal(["A single paragraph, well under the floor, and so not suspicious."]),
            nil, "a short single-paragraph document")
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

    // MARK: - Anchoring a passage in the office's PDF

    /// The needles, and the three rules that decide them.
    ///
    /// **This is where the app's central promise is defended in a form a build can check.**
    /// Everything downstream of an anchor — the placement, the highlight, the jump — is
    /// PDFKit, which `--selftest` deliberately does not touch. The needle is the part that
    /// is pure, and it is also the part that a well-meaning simplification would quietly
    /// ruin: lengthen it and line wrap defeats it, shorten it and it matches everywhere,
    /// build a claim's out of `fullText` and it scores 3/20. Each of those is pinned below.
    private static func passageAnchors(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the anchor checks")
            return
        }
        let anchors = PassageAnchors.anchors(in: patent)

        func anchor(_ target: CitationTarget) -> PassageAnchor? {
            anchors.first { $0.target == target }
        }

        // A paragraph's needle is exactly six single-spaced words of its own text, written
        // out here rather than derived, so that a change to the rule has to be typed twice.
        let first = ParagraphKey(patent: patent.key, number: 1)
        log.equal(
            anchor(.paragraph(first))?.needle, "The present disclosure is directed, in",
            "the needle for [0001]")
        log.check(
            anchor(.paragraph(first))?.fallback == nil,
            "a paragraph should carry no fallback needle")

        // Every needle is exactly six words, single-spaced, and is a prefix of the
        // paragraph's own text — the invariant that makes it findable at all.
        for anchor in anchors {
            guard case .paragraph(let key) = anchor.target,
                let paragraph = patent.paragraph(numbered: key.number)
            else { continue }
            log.equal(
                anchor.needle.split(separator: " ").count, PassageAnchors.paragraphWords,
                "the word count of the needle for [\(key.number)]")
            log.check(
                !anchor.needle.contains("  "),
                "the needle for [\(key.number)] is not single-spaced")
            log.check(
                PassageAnchors.normalized(paragraph.text)
                    .hasPrefix(PassageAnchors.normalized(anchor.needle)),
                "the needle for [\(key.number)] is not the paragraph's own opening")
        }

        // A claim's needle is its printed number and its preamble, and **never** spills
        // into `elements`. That is the 20/20-against-3/20 measurement: a claim's elements
        // are separated in the printed document by line breaks and a hanging indent, which
        // no `findString` crosses. Claim 7 of this fixture has elements, which is what makes
        // it the one to assert on.
        guard let seven = patent.claim(numbered: 7),
            let sevenAnchor = anchor(.claim(ClaimKey(patent: patent.key, number: 7)))
        else {
            log.fail("US10123456B2 has no claim 7 to anchor")
            return
        }
        log.check(
            sevenAnchor.needle.hasPrefix("7. "), "a claim's needle should open with its "
                + "printed number, which `Claim.text` has stripped")
        for element in seven.elements {
            log.check(
                !sevenAnchor.needle.contains(element.text),
                "a claim's needle must never reach into its elements")
        }
        log.equal(
            sevenAnchor.needle.split(separator: " ").count,
            PassageAnchors.claimWords + 1, "the word count of claim 7's needle")

        // Claim 1 of this fixture reads, in full, `A method comprising:` — three words,
        // which is the commonest independent-claim shape there is. The number is what makes
        // it findable, so it anchors on what is there rather than on nothing.
        log.equal(
            anchor(.claim(ClaimKey(patent: patent.key, number: 1)))?.needle,
            "1. A method comprising:", "the needle for a three-word claim preamble")

        // Front matter exists in no document and is never anchored.
        log.check(
            anchor(.paragraph(ParagraphKey(patent: patent.key, number: 0))) == nil,
            "the synthetic front-matter chunk should never be anchored")

        // Anchors arrive in `Patent.rows` order, which is what `monotonic` requires: the
        // specification section by section, then the claims.
        let order = patent.rows.compactMap { $0.target(in: patent.key) }
        log.equal(
            anchors.map(\.target), order.filter { target in anchors.contains { $0.target == target } },
            "anchors should be in document order")

        // What cannot be anchored, per fixture, as a number. See `Fixture`.
        for fixture in fixtures {
            guard let patent = parsed(fixture.name) else {
                log.fail("could not load \(fixture.name) for the anchor counts")
                continue
            }
            let anchored = Set(
                PassageAnchors.anchors(in: patent).compactMap { anchor -> Int? in
                    guard case .paragraph(let key) = anchor.target else { return nil }
                    return key.number
                })
            log.equal(
                patent.paragraphs.filter { !anchored.contains($0.number) }.count,
                fixture.unanchorableParagraphs,
                "\(fixture.name): paragraphs too short to anchor")
        }
    }

    /// The ordering rule, which is the whole of the placement algorithm.
    ///
    /// Synthetic candidate lists rather than a document, because what is being asserted is
    /// arithmetic over ordinals and because there is no PDF in this repository to assert it
    /// against — `--anchor` is how the real thing gets measured. Every case here is one that
    /// naive first-match gets wrong.
    private static func passagePlacement(_ log: Log) {
        func c(_ page: Int, _ offset: Int) -> Candidate { Candidate(page: page, offset: offset) }

        // Lexicographic, and this is the comparison a geometric ordinal got wrong: a hit at
        // the bottom of page 1 precedes one at the top of page 2, whatever their heights.
        log.check(c(1, 9000) < c(2, 0), "a later page should sort after an earlier one")
        log.check(c(1, 5) < c(1, 6), "a later offset on one page should sort after an earlier")
        log.check(!(c(2, 0) < c(1, 9000)), "the comparison should not be symmetric")

        // Unambiguous input is the identity.
        log.equal(
            PassagePlacement.monotonic([[c(0, 10)], [c(0, 20)], [c(1, 5)]]),
            [c(0, 10), c(0, 20), c(1, 5)], "one candidate each")

        // The case first-match gets wrong: every target's *first* candidate is early, and
        // only the ordering picks the run that ascends.
        log.equal(
            PassagePlacement.monotonic([
                [c(0, 1), c(0, 50)], [c(0, 2), c(0, 60)], [c(0, 70)],
            ]),
            [c(0, 1), c(0, 2), c(0, 70)], "the earliest ascending run")

        // A target placed late forces the next one past its own first candidate.
        log.equal(
            PassagePlacement.monotonic([[c(0, 50)], [c(0, 20), c(0, 60)]]),
            [c(0, 50), c(0, 60)], "a late placement pushes the next one along")

        // Stuck: unplaced, the cursor unmoved, and everything after it still places. The
        // alternative — resetting the cursor — trades one lost chip for a cascade.
        log.equal(
            PassagePlacement.monotonic([[c(0, 50)], [c(0, 20)], [c(0, 60)]]),
            [c(0, 50), nil, c(0, 60)], "a stuck target should not move the cursor")

        // Nothing found at all.
        log.equal(
            PassagePlacement.monotonic([[c(0, 10)], [], [c(0, 20)]]),
            [c(0, 10), nil, c(0, 20)], "an anchor that found nothing")
        log.equal(PassagePlacement.monotonic([]), [], "an empty document")

        // The invariant that is the whole guarantee, over a thousand seeded random shapes:
        // **every placed ordinal is strictly greater than the one before it.** A placement
        // that goes backwards is a highlight in the wrong place, which looks exactly like a
        // highlight in the right place.
        var seed: UInt64 = 0x5EED
        func random(_ bound: Int) -> Int {
            // xorshift64, so the shapes are the same on every machine and a failure can be
            // reproduced from the seed alone.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for shape in 0 ..< 1000 {
            let targets = 1 + random(30)
            let lists = (0 ..< targets).map { _ -> [Candidate] in
                (0 ..< random(5)).map { _ in c(random(20), random(4000)) }
            }
            let placed = PassagePlacement.monotonic(lists).compactMap { $0 }
            for (previous, next) in zip(placed, placed.dropFirst()) where !(previous < next) {
                log.fail("shape \(shape): placements did not ascend — \(previous), \(next)")
            }
            log.equal(
                PassagePlacement.monotonic(lists).count, targets,
                "shape \(shape): one answer per target")
        }

        // The find cursor, ported out of `DocumentFind` so its assertions outlive it.
        log.equal(PassagePlacement.index(nearest: nil, in: [3, 7, 9]), 0, "no reading position")
        log.equal(PassagePlacement.index(nearest: 7, in: [3, 7, 9]), 1, "a hit on the page")
        log.equal(PassagePlacement.index(nearest: 4, in: [3, 7, 9]), 1, "the next hit after")
        log.equal(
            PassagePlacement.index(nearest: 40, in: [3, 7, 9]), 0,
            "a position past the last hit should wrap to the first")

        log.equal(PassagePlacement.stepped(from: nil, by: 1, count: 3), 1, "the first step")
        log.equal(PassagePlacement.stepped(from: 2, by: 1, count: 3), 0, "wrapping forwards")
        log.equal(PassagePlacement.stepped(from: 0, by: -1, count: 3), 2, "wrapping backwards")
        log.equal(
            PassagePlacement.stepped(from: nil, by: 1, count: 0), nil,
            "stepping through nothing")
    }

    /// Which passages an answer paints on the document, and — the interesting half — which
    /// it refuses to.
    private static func highlightPlan(_ log: Log) {
        let key = PatentKey(country: "US", serial: "10123456", kind: "B2")
        let other = PatentKey(country: "US", serial: "5000000", kind: "A")
        func paragraph(_ number: Int, in patent: PatentKey = key) -> CitationTarget {
            .paragraph(ParagraphKey(patent: patent, number: number))
        }
        func cited(_ target: CitationTarget, _ verdict: CitationCheck.Verdict) -> AnswerRun {
            .citation(AnswerRun.Citation(target: target, literal: "x", verdict: verdict))
        }

        log.equal(
            HighlightPlan.make(for: key, retrieved: [], runs: [], focus: nil),
            .empty, "no answer, no plan")

        // Precedence. A passage that was retrieved, cited and then clicked is one passage,
        // and it draws in the strongest of the three.
        let plan = HighlightPlan.make(
            for: key,
            retrieved: [paragraph(1), paragraph(2), paragraph(3)],
            runs: [cited(paragraph(2), .supported), cited(paragraph(3), .supported)],
            focus: PassageFocus(paragraph(3)))
        log.equal(plan.roles[paragraph(1)], .retrieved, "a retrieved passage")
        log.equal(plan.roles[paragraph(2)], .cited, "cited beats retrieved")
        log.equal(plan.roles[paragraph(3)], .focused, "focused beats cited")

        // A citation the model was never shown is real and is not painted. Marking it would
        // be the app endorsing a connection the model invented, in the most authoritative
        // place it has — the same argument that already makes that chip unclickable.
        let unsupported = HighlightPlan.make(
            for: key, retrieved: [],
            runs: [cited(paragraph(9), .unretrieved), cited(paragraph(99), .nonexistent)],
            focus: nil)
        log.check(
            unsupported.roles.isEmpty,
            "only a `.supported` citation should be painted on the document")

        // Front matter is `Chunker`'s title-and-abstract address and exists in no document.
        // Retrieval hits it constantly, so this is the ordinary case.
        let front = HighlightPlan.make(
            for: key, retrieved: [paragraph(0), paragraph(4)],
            runs: [cited(paragraph(0), .supported)], focus: nil)
        log.equal(
            Set(front.roles.keys), [paragraph(4)], "front matter should never be marked")

        // Another patent's passages. Retrieval is library-wide; marking is per document.
        let across = HighlightPlan.make(
            for: key, retrieved: [paragraph(5), paragraph(6, in: other)],
            runs: [cited(paragraph(7, in: other), .supported)], focus: nil)
        log.equal(
            Set(across.roles.keys), [paragraph(5)],
            "a passage in another patent should be dropped")

        // Clicking the same chip twice has to move the reader twice, which is what the
        // focus identity is for and the whole reason it is not a bare target.
        let once = PassageFocus(paragraph(3))
        let twice = PassageFocus(paragraph(3))
        log.check(once != twice, "two focuses on one passage must not compare equal")
        log.equal(once.target, twice.target, "…while still naming the same passage")
    }

    /// A string the reader dragged out of the PDF, back to the passage it came from.
    ///
    /// The textual fallback for `PatentPDFMap`'s bracket lookup, and the leg that has to
    /// survive what a PDF does to text on the way out: hard line breaks where the parse has
    /// spaces, a hyphen the typesetter put in at a line end, and doubled spaces from
    /// justification.
    private static func passageLookup(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the passage-lookup checks")
            return
        }
        guard let paragraph = patent.paragraphs.first(where: { $0.text.count > 200 }) else {
            log.fail("the fixture has no paragraph long enough to mangle")
            return
        }
        let expected = CitationTarget.paragraph(
            ParagraphKey(patent: patent.key, number: paragraph.number))

        log.equal(
            PassageAnchors.target(containing: paragraph.text, in: patent), expected,
            "a paragraph's own text")

        /// What a selection out of a PDF looks like: the words, re-wrapped at 40 characters,
        /// with a hyphen inserted at one break and the odd doubled space.
        func mangled(_ text: String) -> String {
            var out = ""
            var column = 0
            var hyphenated = false
            for word in text.split(whereSeparator: \.isWhitespace) {
                if column + word.count > 40 {
                    // One hyphenated break, across lowercase letters, which is the only
                    // shape `normalized` is allowed to rejoin.
                    if !hyphenated, word.count > 6, word.allSatisfy(\.isLowercase) {
                        let split = word.index(word.startIndex, offsetBy: 3)
                        out += String(word[..<split]) + "-\n" + String(word[split...]) + " "
                        hyphenated = true
                        column = word.count - 3
                        continue
                    }
                    out += "\n"
                    column = 0
                }
                out += word + (column % 7 == 0 ? "  " : " ")
                column += word.count + 1
            }
            return out
        }

        let selection = mangled(paragraph.text)
        log.check(
            selection.contains("-\n"), "the mangler did not produce a hyphenated break")
        log.equal(
            PassageAnchors.target(containing: selection, in: patent), expected,
            "a mangled selection should still resolve to its paragraph")

        // Part of a paragraph, which is what a drag usually is.
        let part = paragraph.text.split(whereSeparator: \.isWhitespace).dropFirst(3).prefix(12)
            .joined(separator: " ")
        log.equal(
            PassageAnchors.target(containing: mangled(part), in: patent), expected,
            "part of a paragraph")

        // A claim, which is as citable as a paragraph.
        guard let claim = patent.claims.first(where: { !$0.elements.isEmpty }) else {
            log.fail("the fixture has no claim with elements")
            return
        }
        log.equal(
            PassageAnchors.target(containing: claim.text, in: patent),
            .claim(ClaimKey(patent: patent.key, number: claim.number)),
            "a claim's preamble")

        // Nothing, rather than a nearest guess. A selection this app cannot place is a
        // quotation it must copy uncited, and saying so is the whole doctrine.
        log.check(
            PassageAnchors.target(containing: "", in: patent) == nil, "an empty selection")
        log.check(
            PassageAnchors.target(containing: "   \n  ", in: patent) == nil,
            "a whitespace selection")
        log.check(
            PassageAnchors.target(
                containing: "the quality of mercy is not strained", in: patent) == nil,
            "a foreign string should resolve to nothing rather than to the nearest paragraph")

        // The two rules `normalized` has, stated on their own.
        log.equal(
            PassageAnchors.normalized("a  b\nc"), "a b c", "whitespace collapses")
        log.equal(
            PassageAnchors.normalized("manufactur- ing"), "manufacturing",
            "a lowercase break rejoins")
        log.equal(
            PassageAnchors.normalized("thermally- Conductive"), "thermally- Conductive",
            "a break before a capital does not rejoin")
    }

    // MARK: - Find in the document

    /// The reader's find field: the offsets, the order, the wrap, and the claim clipping.
    ///
    /// **The offsets are the reason this suite exists.** Everything else here would fail
    /// visibly — a wrong count is on screen, a broken wrap goes nowhere — but a match
    /// addressed one character to the left just draws a highlight that looks slightly off,
    /// which is the kind of wrong that ships. So every match found in the real fixture is
    /// checked by going back to the row's text and reading what the offsets actually
    /// address.
    private static func documentFind(_ log: Log) {
        guard let patent = parsed("US10123456B2") else {
            log.fail("could not load US10123456B2 for the document-find checks")
            return
        }
        let rows = patent.rows
        let text = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0.plainText) })

        /// What a match's offsets actually address, or `nil` if they address nothing.
        func addressed(_ match: DocumentFind.Match) -> String? {
            guard let row = text[match.row] else { return nil }
            let count = row.utf16.count
            guard match.range.lowerBound >= 0, match.range.lowerBound < match.range.upperBound,
                match.range.upperBound <= count
            else { return nil }
            let lower = String.Index(utf16Offset: match.range.lowerBound, in: row)
            let upper = String.Index(utf16Offset: match.range.upperBound, in: row)
            return String(row[lower ..< upper])
        }

        // Below the minimum nothing runs, and the field reports *nothing* rather than "no
        // matches" — the reader is still typing and has not failed at anything yet.
        var find = DocumentFind()
        find.search("s", in: rows, near: nil)
        log.check(find.matches.isEmpty, "a one-character query should not run")
        log.check(find.summary == nil, "a query too short to run should report nothing")
        log.check(!find.isActive, "a one-character query should not read as active")

        // A real term from the fixture, checked against the text it claims to address.
        find.search("matrix", in: rows, near: nil)
        log.check(!find.matches.isEmpty, "\"matrix\" should occur in US10123456B2")
        log.equal(
            find.matches.compactMap { addressed($0)?.lowercased() }.filter { $0 != "matrix" },
            [], "every match should address exactly the query")
        log.equal(
            find.matches.filter { addressed($0) == nil }.count, 0,
            "no match should address a range outside its row")
        log.equal(find.summary, "1 of \(find.matches.count)", "the opening summary")

        // Reading order, and no overlaps: rows never go backwards, and within a row each
        // hit starts at or after the end of the one before it.
        var ordered = true
        for (previous, next) in zip(find.matches, find.matches.dropFirst()) {
            if next.row < previous.row { ordered = false }
            if next.row == previous.row, next.range.lowerBound < previous.range.upperBound {
                ordered = false
            }
        }
        log.check(ordered, "matches should be in reading order and should not overlap")

        // Case insensitivity, from a query nobody would type the same way twice.
        var upper = DocumentFind()
        upper.search("MATRIX", in: rows, near: nil)
        log.equal(
            upper.matches, find.matches, "matching should be case-insensitive")

        // The wrap, in both directions. Running off the end of a document is not an error.
        let total = find.matches.count
        guard total > 1 else {
            log.fail("the fixture needs more than one \"matrix\" for the wrap checks")
            return
        }
        log.equal(find.cursor, 0, "a fresh search should start at the first match")
        log.equal(find.advance(by: -1)?.row, find.matches[total - 1].row, "wrapping backwards")
        log.equal(find.cursor, total - 1, "the cursor after wrapping backwards")
        log.equal(find.advance(by: 1)?.row, find.matches[0].row, "wrapping forwards")
        log.equal(find.summary, "1 of \(total)", "the summary after wrapping forwards")

        // The reading position, which is what stops ⌘F from throwing the reader back to
        // `[0001]`: the cursor lands on the first hit at or after the row they are on. The
        // *first* in that row matters and is why this is asserted by row — the row a reader
        // is on often contains several hits, and landing on the last of them would skip the
        // ones above it.
        let last = find.matches[total - 1].row
        var nearEnd = DocumentFind()
        nearEnd.search("matrix", in: rows, near: last)
        log.equal(nearEnd.current?.row, last, "a search should start at the reader's row")
        log.equal(
            nearEnd.cursor, find.matches.firstIndex { $0.row == last },
            "a search should start at the first hit in that row, not a later one in it")
        var pastEnd = DocumentFind()
        pastEnd.search("matrix", in: rows, near: rows.count)
        log.equal(pastEnd.cursor, 0, "a position past the last match should wrap to the first")

        // Clearing takes the highlights with it.
        find.clear()
        log.check(find.matches.isEmpty, "clearing should drop the matches")
        log.check(
            find.highlights(in: find.matches.first?.row ?? 0).isEmpty,
            "clearing should drop the highlights")

        // Diacritics and apostrophes, which is the case `LibrarySearch.fold` handles by
        // rewriting the string and this one cannot: the offsets have to keep addressing the
        // original. `L'Oréal` before the hit is what would shift a folded answer.
        let accented = [
            DocumentRow(
                index: 0,
                kind: .paragraph(
                    Paragraph(
                        index: 0, number: 1,
                        text: "L'Oréal's café process forms a Nestlé wrapper.",
                        hasPrintedNumber: true)))
        ]
        var folded = DocumentFind()
        folded.search("nestle", in: accented, near: nil)
        log.equal(folded.matches.count, 1, "a diacritic should not defeat a match")
        log.equal(
            folded.matches.first.flatMap { match -> String? in
                let row = accented[0].plainText
                let lower = String.Index(utf16Offset: match.range.lowerBound, in: row)
                let upper = String.Index(utf16Offset: match.range.upperBound, in: row)
                return String(row[lower ..< upper])
            },
            "Nestlé",
            "an accented match should address the accented text, not a folded copy")

        // A claim is one row and three drawn pieces, so a highlight has to be cut to the
        // piece and rebased onto it. The element hit is the one that matters: it is where
        // most of a claim's words are.
        let claim = Claim(
            number: 1, text: "A method comprising:",
            elements: [
                ClaimElement(depth: 0, text: "heating a substrate;"),
                ClaimElement(depth: 0, text: "cooling the substrate."),
            ],
            dependsOn: [], dependencySource: .none)
        let claimRows = [DocumentRow(index: 0, kind: .claim(claim))]
        var inClaim = DocumentFind()
        inClaim.search("substrate", in: claimRows, near: nil)
        log.equal(inClaim.matches.count, 2, "both elements should be searched")

        let highlights = inClaim.highlights(in: 0)
        let preamble = 0 ..< claim.text.utf16.count
        log.check(
            highlights.clipped(to: preamble).isEmpty,
            "a hit in an element should not be drawn in the preamble")

        let firstElement = claim.text.utf16.count + 1
        let firstLength = claim.elements[0].text.utf16.count
        let clipped = highlights.clipped(to: firstElement ..< firstElement + firstLength)
        log.equal(clipped.ranges.count, 1, "the first element should get exactly its own hit")
        log.equal(
            clipped.ranges.first.map { range -> String in
                let element = claim.elements[0].text
                let lower = String.Index(utf16Offset: range.lowerBound, in: element)
                let upper = String.Index(utf16Offset: range.upperBound, in: element)
                return String(element[lower ..< upper])
            },
            "substrate",
            "a clipped highlight should be rebased onto the piece it is drawn in")
        log.equal(
            clipped.current, clipped.ranges.first,
            "the current match should survive being clipped to its own piece")

        // The preamble half of the same split, from a query that is only in the preamble.
        var inPreamble = DocumentFind()
        inPreamble.search("comprising", in: claimRows, near: nil)
        log.equal(
            inPreamble.highlights(in: 0).clipped(to: preamble).ranges.count, 1,
            "a hit in the preamble should be drawn in the preamble")
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
