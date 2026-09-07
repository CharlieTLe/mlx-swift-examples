// Copyright © 2026 Apple Inc.

import Foundation
import PDFKit

/// Reads a patent out of a PDF, and it is the worse path.
///
/// **Ranked honestly: Google Patents is primary and this is the fallback.** The HTML
/// gives structure the PDF only implies — section headings as elements, the claim
/// dependency graph as `claim-ref` attributes, reference numerals as tagged spans — and
/// the PDF gives text and nothing else. Everything this file reconstructs, the other
/// path is handed. So this exists for the documents Google does not have: a draft, an
/// office action, a grant from an office the site does not cover, a PDF somebody
/// emailed. Where both are available, fetch by number.
///
/// Four realities are handled rather than hoped about, and each of them reports rather
/// than producing a document that looks fine and is not.
///
/// - **Some grants have no text layer at all.** A pre-1976 US grant on Google's own
///   servers is a scan. Extraction returns a handful of characters or none, and the
///   right answer is to say so — "this PDF has no text layer" — not to index an empty
///   patent that then answers every question with silence.
/// - **Paragraph numbers may be absent, and their width is not fixed.** They are printed
///   from 2001 onwards and not before, and the fallback is `Numbering.synthesized`, which
///   the citation then admits to. Where they are printed, USPTO pads to four — `[0001]` —
///   and WIPO pads to three and then grows, so one PCT publication runs `[001]`, `[0010]`
///   and `[00100]`. Matching one width silently keeps the middle band and merges the
///   rest, so the width is a range and `paragraphsMerged` is the net beneath it.
/// - **The paragraph breaks may not be in the text at all.** A PCT application as filed
///   carries no `[nnnn]` markers, and PDFKit hands back a page as one line per printed
///   line with no blank line anywhere. Neither of the two readings that assume a marker
///   or a blank line then finds a single break. There is a third reading — a line that
///   stops short of the full measure is the last line of its paragraph — and it is the
///   crudest thing here, so `Source.note` says it was used.
/// - **Two columns.** `PDFPage.string` reads a USPTO grant in content-stream order,
///   which is *usually* column by column and is not guaranteed. The `[nnnn]` sequence is
///   the check: if the recovered numbers are not strictly ascending, the columns were
///   read interleaved, and a document whose paragraphs are shuffled is worse than no
///   document. It is reported rather than imported.
///
/// What the page furniture adds is stripped before any of that runs: see `normalized`.
enum PatentPDFImporter {

    /// Bump alongside `GooglePatentsParser.version` when a change here alters the
    /// `Patent` a given PDF produces. Separate counter, same job: it invalidates the
    /// index.
    static let version = 3

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case noTextLayer(pages: Int, characters: Int)
        case columnsOutOfOrder(at: Int, after: Int)
        case paragraphsMerged(number: Int, percent: Int)
        case tooShort(characters: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "\(name) could not be opened as a PDF."
            case .noTextLayer(let pages, let characters):
                "This PDF has no text layer — \(characters) characters across \(pages) "
                    + "pages, which is a scan rather than a document. Import it from "
                    + "Google Patents by number instead; the text there is searchable."
            case .columnsOutOfOrder(let at, let after):
                "Paragraph [\(String(format: "%04d", at))] follows "
                    + "[\(String(format: "%04d", after))], so the two columns were read "
                    + "interleaved rather than one after the other. The paragraphs would "
                    + "be shuffled, so this import is refused. Import from Google "
                    + "Patents by number instead."
            case .paragraphsMerged(let number, let percent):
                "Paragraph \(number) came out holding \(percent)% of the document's "
                    + "text, so the paragraph breaks stopped being recognised there and "
                    + "everything after it was merged into it. The reader would show that "
                    + "as one unreadable row and every citation into it would name the "
                    + "same paragraph, so this import is refused. Import from Google "
                    + "Patents by number instead."
            case .tooShort(let characters):
                "Only \(characters) characters of text were recovered, which is too "
                    + "little to be a specification."
            }
        }
    }

    /// Below this, per page, the document is a scan.
    ///
    /// 50 characters a page rather than a flat total, so a 200-page file with one text
    /// page of cover sheet is still caught. A real grant page carries 2,000-4,000
    /// characters, so the threshold is nearly two orders of magnitude clear of a
    /// legitimate page and only catches the "a few stray glyphs from the header" case
    /// that a scan produces.
    private static let minimumCharactersPerPage = 50

    /// A whole specification under this is not one.
    private static let minimumCharacters = 500

    /// Above this share of the recovered text in one paragraph, the paragraph breaks were
    /// misread rather than that paragraph being long. See `merged`.
    private static let mergedShare = 0.5

    /// ...and only once that paragraph is this long in absolute terms. Some 3,000 words,
    /// which is past anything an office prints as one paragraph, so a document that is
    /// legitimately one or two paragraphs is not refused for being short.
    private static let mergedMinimum = 20_000

    /// A line shorter than this share of the measure is the last line of its paragraph.
    ///
    /// 0.8 rather than something nearer 1.0 because justified text does not reach the
    /// margin exactly: the last word of a full line lands a few characters either side of
    /// the measure, and a threshold that tight would break a paragraph at every one of
    /// them.
    private static let shortLineShare = 0.8

    /// How the paragraph breaks were found, which `Source.note` reports.
    ///
    /// Worth naming rather than inferring from `Numbering`, which cannot tell the last two
    /// apart: both count from 1 and only one of them guessed where the paragraphs are.
    private enum Breaks {
        case printedMarkers, blankLines, lineLengths
    }

    static func load(_ url: URL, title fallbackTitle: String? = nil) throws -> Patent {
        guard let document = PDFDocument(url: url) else {
            throw Failure.unreadable(url.lastPathComponent)
        }

        var pages: [[String]] = []
        for index in 0 ..< document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            pages.append(
                text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        let characters = pages.joined().joined().filter { !$0.isWhitespace }.count

        guard characters >= minimumCharacters else {
            throw pages.isEmpty || characters < minimumCharactersPerPage * max(1, pages.count)
                ? Failure.noTextLayer(pages: pages.count, characters: characters)
                : Failure.tooShort(characters: characters)
        }
        if characters < minimumCharactersPerPage * pages.count {
            throw Failure.noTextLayer(pages: pages.count, characters: characters)
        }

        return try patent(fromPages: pages, url: url, title: fallbackTitle)
    }

    /// The recovery itself, from the extracted lines of each page.
    ///
    /// Split from `load` so `SelfTest` can drive it. What is worth asserting is which
    /// line starts a paragraph, where the claims begin and which number off the cover
    /// page is the document's; building a PDF to assert that through would be asserting
    /// PDFKit.
    ///
    /// Pages rather than one flat array of lines because the page is where the furniture
    /// is: a running head is a line that recurs *per page*, and printed line numbers are
    /// judged a page at a time so that a document's drawings and tables are left alone.
    static func patent(fromPages pages: [[String]], url: URL, title fallbackTitle: String?)
        throws -> Patent
    {
        let heads = runningHeads(pages)
        let lines = normalized(pages, heads: heads)
        let measure = self.measure(of: lines)

        // Four sources, most trustworthy first. A labelled cover-page field says what the
        // number is; a filename that names its office was typed by somebody who knew; the
        // running head is the document repeating itself on every page; a bare serial in a
        // filename is a guess about the office. Then the sentinel, so a document with none
        // of them is still importable and visibly unidentified.
        let key =
            number(in: lines) ?? qualifiedFilename(url) ?? number(inHeads: heads)
            ?? PatentNumberParser.parse(url.deletingPathExtension().lastPathComponent)
            ?? PatentKey(country: "US", serial: "000000", kind: nil)

        // The claims are cut off the end *before* the paragraphs are recovered, rather
        // than picked out of them afterwards. They have to be: a claim carries no
        // `[nnnn]` marker of its own, so left in place the entire claim set is
        // continuation text and lands inside whichever specification paragraph happened
        // to be last. Cutting first also means a paragraph is never both, which it would
        // be if the claims were merely *also* extracted, and the reader would scroll past
        // the claims twice.
        let boundary = claimSectionStart(in: lines)
        let claims = self.claims(
            in: Array(lines[(boundary ?? lines.count)...]), measure: measure)
        let (spec, numbering, breaks) = try paragraphs(
            in: Array(lines[..<(boundary ?? lines.count)]), measure: measure)

        return Patent(
            schemaVersion: 1,
            id: key.slug,
            key: key,
            title: title(in: lines) ?? fallbackTitle
                ?? url.deletingPathExtension().lastPathComponent,
            abstract: "",
            inventors: [],
            assignee: nil,
            publicationDate: nil,
            priorityDate: nil,
            classifications: [],
            numbering: numbering,
            source: Source(
                kind: .pdf,
                url: url.absoluteString,
                retrieved: Date(),
                contentSHA256: GooglePatentsParser.digest(of: lines.joined(separator: "\n")),
                parserVersion: version,
                note: note(breaks: breaks, numbering: numbering, claims: claims.count)),
            // One unnamed section: a PDF's headings are typography, and telling a
            // heading from a short paragraph in extracted text is a guess this refuses
            // to make. The navigator shows the paragraph range instead, which is true.
            sections: [SpecSection(heading: "", paragraphs: spec)],
            claims: claims,
            // No callouts. The HTML path gets these as tagged spans; recovering them
            // here would mean deciding that every three-digit number is a part number,
            // which is the heuristic `Patent.calloutNumerals` exists to avoid. So a PDF
            // import styles no reference numerals, which is a missing feature rather
            // than a wrong one.
            calloutNumerals: [:])
    }

    private static func note(breaks: Breaks, numbering: Numbering, claims: Int) -> String {
        var parts = [
            "Imported from a PDF, which carries text and no structure: no section "
                + "headings, no reference numerals, and claim dependencies read from the "
                + "claims' own wording."
        ]
        if numbering == .synthesized {
            parts.append(
                "No [0001] paragraph numbers were found, so they are counted from 1 by "
                    + "this reader. Citations say so.")
        }
        if breaks == .lineLengths {
            parts.append(
                "The text had no blank lines either, so where one paragraph ends and the "
                    + "next begins was inferred from which lines stop short of the full "
                    + "measure. Two paragraphs are run together wherever the first one's "
                    + "last line happened to fill it.")
        }
        if claims == 0 {
            parts.append("No claims were recognised.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Page furniture

    /// Lines that recur at the *top* of a third or more of the pages, which is what a
    /// running head is.
    ///
    /// Both halves of that are needed, and recurrence alone is not enough. Measured over
    /// real documents, a running head sits on 50-80% of pages — and so does body text: one
    /// grant repeats `fatty acid, ester, an organic-organic compound, an organic` on half
    /// of its pages, because it is claim language and the claims restate themselves. A
    /// threshold that removed the head of that document would delete a limitation out of
    /// its claims, which is the worst thing in this file it is possible to do.
    ///
    /// Position is what separates them. Furniture is printed at the top of the page and
    /// recurring claim language is wherever the claim reached, so only appearances in the
    /// first two lines of a page count. Three pages minimum on top of the ratio, because a
    /// third of a four-page document is one page and one appearance is not a pattern.
    private static func runningHeads(_ pages: [[String]]) -> Set<String> {
        guard pages.count >= 4 else { return [] }

        var pagesHeaded: [String: Int] = [:]
        for page in pages {
            // `Set` so a line repeated within the top of one page counts once.
            for line in Set(page.prefix(2)) where line.count >= 8 {
                pagesHeaded[line, default: 0] += 1
            }
        }
        let threshold = max(3, pages.count / 3)
        return Set(pagesHeaded.filter { $0.value >= threshold }.keys)
    }

    /// The lines of every page with the furniture taken out.
    ///
    /// None of the running head, the page number or the printed line numbers in the margin
    /// is part of the document, all three are invisible in a PDF reader, and all three land
    /// in the middle of a sentence once the text is extracted. The line numbers are much
    /// the worst: `5 5' untranslated region (5'UTR)` is a corrupted sentence that would be
    /// embedded, retrieved and then quoted back to the reader with the margin number still
    /// in it, and a claim whose number one of them precedes — `10 10. The composition of
    /// claim 8` — is not recognised as the next claim, which loses every claim after it.
    ///
    /// In this order, because each step makes the next one's job easier: the page number is
    /// only recognisable once the head above it has gone, and it is a multiple of five
    /// every fifth page, which would otherwise be read as a margin number.
    private static func normalized(_ pages: [[String]], heads: Set<String>) -> [String] {
        pages.flatMap { page in
            withoutLineNumbers(withoutPageNumber(page.filter { !heads.contains($0) }))
        }
    }

    /// One page without the number the printer put at the top of it.
    ///
    /// Only a bare number, and only in the first two lines, which is where it sits once the
    /// running head above it has gone. Left in it does two kinds of damage: a paragraph
    /// that spans the page break reads `Accordingly, ASO therapy 2 has so far been
    /// proposed`, and — because a two-character line is a short line — it also breaks that
    /// paragraph in half where nothing in the document does.
    private static func withoutPageNumber(_ page: [String]) -> [String] {
        var page = page
        for index in page.indices.prefix(2).reversed()
        where !page[index].isEmpty && page[index].count <= 4
            && page[index].allSatisfy(\.isNumber)
        {
            page.remove(at: index)
        }
        return page
    }

    /// One page with its printed line numbers removed, if it has them.
    ///
    /// The evidence required is three or more *distinct* multiples of five, each opening a
    /// line. That is what a numbered typescript's margin looks like — 5, 10, 15 down the
    /// page — and it is not something ordinary prose does three times on one page, which
    /// is what keeps `5 mL of buffer was added` from being shortened to `mL of buffer`.
    /// Judged a page at a time, because the same document's drawings, sequence tables and
    /// search report have no margin and must not be touched.
    private static func withoutLineNumbers(_ page: [String]) -> [String] {
        let candidate = /^(\d{1,3})(?:\s+(.*))?$/

        /// The margin number opening `line`, and whatever follows it.
        func split(_ line: String) -> (number: Int, rest: String)? {
            guard let match = try? candidate.wholeMatch(in: line), let number = Int(match.1),
                number >= 5, number <= 200, number % 5 == 0
            else { return nil }
            return (number, match.2.map(String.init) ?? "")
        }

        guard Set(page.compactMap { split($0)?.number }).count >= 3 else { return page }

        return page.compactMap { line in
            // An already-blank line is a paragraph break where the extraction has them,
            // and is not furniture. Kept.
            guard !line.isEmpty else { return line }

            var rest = line
            // Repeatedly, because a page break puts two of them on one line: `15 20`.
            while let next = split(rest) { rest = next.rest }
            return rest.isEmpty ? nil : rest
        }
    }

    /// The width of a full line, as the 85th percentile of the lines there are.
    ///
    /// Not the maximum, which one run-together line out of a table would set, and not the
    /// median, which the short last line of every paragraph pulls down. The 85th
    /// percentile sits inside the body of full-measure lines for a single-column
    /// typescript at about 105 characters and for a two-column grant at about 62, without
    /// either being told apart.
    private static func measure(of lines: [String]) -> Int {
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        guard !lengths.isEmpty else { return 0 }
        return lengths[min(lengths.count - 1, Int(Double(lengths.count) * 0.85))]
    }

    // MARK: - Paragraphs

    /// Paragraphs, by whichever of three readings the document supports.
    ///
    /// Tried in order of how much each one claims. The printed `[nnnn]` markers are the
    /// document's own numbering and are believed outright. Blank lines are the
    /// extraction's own paragraph breaks, exact wherever it put them. Line lengths are a
    /// guess, and reaching them means neither of the other two found anything.
    ///
    /// What promotes the next reading is that the one above it found *no breaks* — one
    /// paragraph holding the document — and not that its output looks merged. Those are
    /// different questions, and `merged` answers only the second: it carries an absolute
    /// floor so that a genuinely short document is not refused, and a short document with
    /// no blank lines still needs the reading below.
    private static func paragraphs(in lines: [String], measure: Int) throws -> (
        [Paragraph], Numbering, Breaks
    ) {
        if let printed = try printedParagraphs(in: lines) {
            // Markers that stop partway leave the rest merged into the last one that
            // matched. Nothing else would notice.
            if let bad = merged(printed) {
                throw Failure.paragraphsMerged(number: bad.number, percent: bad.percent)
            }
            return (printed, .printed, .printedMarkers)
        }

        let byBlankLine = blankLineParagraphs(in: lines)
        if byBlankLine.count > 1, merged(byBlankLine) == nil {
            return (byBlankLine, .synthesized, .blankLines)
        }

        let byLineLength = shortLineParagraphs(in: lines, measure: measure)
        if let bad = merged(byLineLength) {
            throw Failure.paragraphsMerged(number: bad.number, percent: bad.percent)
        }
        return (byLineLength, .synthesized, .lineLengths)
    }

    /// Paragraphs recovered from the `[0001]` markers, or `nil` where there are none.
    ///
    /// Anchored at the start of a line, which is what makes it safe: `[0001]` inside a
    /// sentence is a citation to another paragraph and not the start of one, and patents
    /// contain those.
    ///
    /// Three to five digits, because the padding is not a constant. USPTO pads to four
    /// and WIPO pads to three, so a PCT publication that runs past paragraph 99 prints
    /// `[001]`, `[0010]` and `[00100]` in the same document and only the middle band is
    /// four digits wide. Widening does not cost precision — the strictly-ascending check
    /// below is what rejects a false match, and it is unchanged.
    private static func printedParagraphs(in lines: [String]) throws -> [Paragraph]? {
        let marker = /^\[(\d{3,5})\]\s*(.*)$/

        var numbered: [(number: Int, text: String)] = []
        var current: (number: Int, text: String)?

        for line in lines {
            if let match = try? marker.wholeMatch(in: line), let number = Int(match.1) {
                if let current { numbered.append(current) }
                current = (number, String(match.2))
            } else if current != nil, !line.isEmpty {
                current?.text += " " + line
            }
        }
        if let current { numbered.append(current) }

        // Too few markers to be this document's numbering — a pre-2001 grant, a PCT
        // application as filed, or a file whose extraction lost them. Not this reading.
        guard numbered.count >= 3 else { return nil }

        // The column-order check. Strictly ascending or the columns were interleaved.
        for (previous, next) in zip(numbered, numbered.dropFirst())
        where next.number <= previous.number {
            throw Failure.columnsOutOfOrder(at: next.number, after: previous.number)
        }

        return numbered.enumerated().map { index, entry in
            Paragraph(
                index: index, number: entry.number, text: tidy(entry.text),
                hasPrintedNumber: true)
        }
    }

    /// Whether one paragraph swallowed the rest of the document, and which.
    ///
    /// This is both how a reading is rejected in favour of the next one and, once there is
    /// no next one, how the import is refused. The same kind of check as
    /// `columnsOutOfOrder` and for the same reason: when the paragraph breaks stop being
    /// found — a marker scheme this does not know, an OCR'd grant where `[0001]` came out
    /// as `0001.` and the brackets are simply gone — *nothing fails*. Every later line is
    /// appended to the last paragraph that did break, and the result imports cleanly, shows
    /// one unreadable row, and answers every question with a citation to the same
    /// paragraph. Silent, so it has to be looked for rather than waited for.
    ///
    /// Share of the text rather than a multiple of the median, because patents do have
    /// long paragraphs — a table, a sequence listing — and a long paragraph is only
    /// suspicious when it is most of the document. The absolute floor is what makes the
    /// share safe to trust: 20,000 characters is some 3,000 words, which no paragraph any
    /// office prints comes near, so a short document that is legitimately one or two
    /// paragraphs is not called merged.
    private static func merged(_ paragraphs: [Paragraph]) -> (number: Int, percent: Int)? {
        let lengths = paragraphs.map(\.text.count)
        let total = lengths.reduce(0, +)
        guard let largest = lengths.max(), let index = lengths.firstIndex(of: largest),
            largest >= mergedMinimum, total > 0
        else { return nil }

        let share = Double(largest) / Double(total)
        guard share > mergedShare else { return nil }
        return (paragraphs[index].number, Int((share * 100).rounded()))
    }

    /// Paragraphs from blank lines, for a document with no markers.
    ///
    /// Exact where the extraction has them, and nothing at all where it does not: PDFKit
    /// returns many PDFs as one line per printed line with no blank line anywhere, and
    /// this then returns the whole document as one paragraph, which `merged` catches and
    /// `shortLineParagraphs` takes over from.
    private static func blankLineParagraphs(in lines: [String]) -> [Paragraph] {
        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
            } else {
                current += current.isEmpty ? line : " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return synthesised(paragraphs)
    }

    /// Paragraphs from line lengths, for a document with neither markers nor blank lines.
    ///
    /// The crudest reading here and the one `Source.note` admits to. A line that stops
    /// short of the measure is the last line of its paragraph — that is what a page of
    /// justified text looks like — and once the extraction has given up both the markers
    /// and its blank lines it is the only evidence left. It is what makes a PCT
    /// application as filed readable at all: no `[nnnn]` markers are printed in one, and
    /// its 300-odd paragraphs are otherwise a single row.
    ///
    /// Wrong at every paragraph whose last line happens to fill the measure, where two
    /// paragraphs are run together. That is the cost, it is visible in the reader rather
    /// than hidden, and the numbering is this reader's own and says so either way.
    private static func shortLineParagraphs(in lines: [String], measure: Int) -> [Paragraph] {
        guard measure > 0 else { return [] }
        let short = Int(Double(measure) * shortLineShare)

        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            guard !line.isEmpty else {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
                continue
            }
            current += current.isEmpty ? line : " " + line
            if line.count < short {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return synthesised(paragraphs)
    }

    /// The tail both fallbacks share: tidy, drop the furniture, number from 1.
    private static func synthesised(_ paragraphs: [String]) -> [Paragraph] {
        paragraphs
            .map(tidy)
            // A "paragraph" of four words is a running head, a page number or a figure
            // label. Keeping them would put a hundred rows of noise in the reader and a
            // hundred meaningless chunks in the index.
            .filter { $0.split(whereSeparator: \.isWhitespace).count >= 8 }
            .enumerated()
            .map {
                Paragraph(
                    index: $0.offset, number: $0.offset + 1, text: $0.element,
                    hasPrintedNumber: false)
            }
    }

    /// Rejoins words a line break hyphenated, and collapses whitespace.
    ///
    /// Only across a lowercase-to-lowercase break, so `thermally-conductive` split
    /// across lines stays hyphenated and `manufactur- ing` is rejoined. A patent's real
    /// hyphenated compounds are overwhelmingly of the first kind, so the asymmetry is
    /// the right way round: a missed rejoin is a visible typo and a wrong one invents a
    /// word.
    private static func tidy(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.replacing(/([a-z])- ([a-z])/) { "\($0.1)\($0.2)" }
    }

    // MARK: - Claims

    /// The claim preamble, which both marks the boundary and gets stripped off it.
    ///
    /// Computed rather than stored because `Regex` is not `Sendable`, and one shared
    /// across the two places that need it beats two spellings that could drift apart.
    private static var claimPreamble: Regex<Substring> {
        /^(?:what is claimed is|we claim|i claim|the invention claimed is)\s*:?\s*/
            .ignoresCase()
    }

    /// A heading that is nothing but the word, which is how a PCT application sets it.
    ///
    /// The whole line, deliberately: `claims.` at the end of a sentence — "encompassed by
    /// the following claims." — is the last line of a specification paragraph and not a
    /// heading, and the trailing full stop is the only thing that says so.
    private static var claimsHeading: Regex<Substring> {
        /^claims?\s*:?\s*$/.ignoresCase()
    }

    /// How many very short lines in a row end the claims. See `claims(in:measure:)`.
    ///
    /// Three, because two in a row does not happen inside a claim set: a claim's last line
    /// is short and the next claim's first line is full, so short lines alternate rather
    /// than run. Three is therefore already anomalous while still leaving a margin.
    private static let endOfClaimsRun = 3

    /// Where the claims begin: the heading line, or the line opening with the preamble.
    ///
    /// Two spellings because the offices differ and one document uses both. A US grant
    /// prints `What is claimed is:` with no heading over it; a PCT application prints
    /// `CLAIMS` and no preamble under it; one PCT publication in hand prints the heading
    /// and then the preamble on the next line. Taking the first of either gets all three.
    ///
    /// A document with neither has no claims this importer will recognise, and
    /// `Source.note` says so rather than the reader discovering it by finding no Claims
    /// section.
    ///
    /// A line rather than a paragraph, because the claims have to be cut off *before*
    /// paragraph recovery runs: a claim carries no `[nnnn]` marker, so by the time there
    /// are paragraphs the preamble is buried mid-paragraph and there is no boundary left
    /// to find.
    private static func claimSectionStart(in lines: [String]) -> Int? {
        lines.firstIndex {
            (try? claimsHeading.wholeMatch(in: $0)) != nil
                || (try? claimPreamble.prefixMatch(in: $0)) != nil
        }
    }

    /// The claims, recovered from their own numbering, given the lines from the boundary
    /// onwards.
    ///
    /// Split on a line opening with `N.` where `N` is the *next expected* number.
    /// Requiring the next one rather than any number is what keeps "35 U.S.C. 112" and a
    /// stray "2." in prose out of the claim list: a sequence has to be a sequence, and a
    /// number out of turn is text. Requiring a space or the line's end after the dot is
    /// the other half of it, and is what keeps "1.5 mL" from opening claim 1 — while
    /// still admitting a bare `8.` alone on a line, which extraction produces often
    /// enough, the number and its text having landed in different text runs. That is also
    /// why the number is tested before the length: `8.` is two characters, and a rule that
    /// looked at its length first would file it as noise and lose every claim after it.
    ///
    /// Stops at a run of very short lines, and holds them back until a full one arrives
    /// rather than appending them as it goes. Both offices set the claims on their own
    /// sheets, and what follows them in the file is a different document — a drawing set,
    /// a PCT search report — that nothing in numbers next, so *all* of it would otherwise
    /// become the text of the last claim. A run rather than a blank page, because plenty of
    /// extractions contain no blank line anywhere and a drawing sheet still comes out as a
    /// dozen fragments of three characters.
    private static func claims(in lines: [String], measure: Int) -> [Claim] {
        let body = skippingClaimSectionHeading(lines)

        // A third of the measure: shorter than any line of claim prose, including the last
        // line of a claim, and longer than the fragments a drawing sheet extracts as.
        let shortLine = max(1, measure / 3)
        let lead = /^(\d{1,3})\.(?:\s+(.*))?$/

        var claims: [Claim] = []
        var expected = 1
        var current: (number: Int, text: String)?
        // Short lines seen since the last full one. A claim's own last line is short, so
        // these are only noise once enough of them arrive in a row.
        var pending: [String] = []

        func close() {
            defer {
                current = nil
                pending = []
            }
            guard var entry = current else { return }
            if !pending.isEmpty { entry.text += " " + pending.joined(separator: " ") }
            claims.append(claim(entry))
        }

        for line in body {
            if let match = try? lead.wholeMatch(in: line), Int(match.1) == expected {
                close()
                current = (expected, match.2.map(String.init) ?? "")
                expected += 1
                continue
            }
            if line.count < shortLine {
                pending.append(line)
                if pending.count >= endOfClaimsRun, current != nil {
                    pending = []
                    break
                }
                continue
            }
            guard current != nil else {
                pending = []
                continue
            }
            current?.text += " " + (pending + [line]).joined(separator: " ")
            pending = []
        }
        close()
        return claims
    }

    /// The claim lines with the heading and the preamble taken off the front.
    ///
    /// Either, both, or neither may be there. The preamble is stripped rather than dropped
    /// whole, because a cover page sometimes sets claim 1 on the same line as it.
    private static func skippingClaimSectionHeading(_ lines: [String]) -> [String] {
        var body = Array(lines)
        while let first = body.first {
            if (try? claimsHeading.wholeMatch(in: first)) != nil {
                body.removeFirst()
                continue
            }
            guard let match = try? claimPreamble.prefixMatch(in: first) else { break }
            let remainder = String(first[match.range.upperBound...])
            body.removeFirst()
            if !remainder.isEmpty { body.insert(remainder, at: 0) }
            break
        }
        return body
    }

    private static func claim(_ entry: (number: Int, text: String)) -> Claim {
        let parents = referencedClaims(in: entry.text, excluding: entry.number)
        return Claim(
            number: entry.number,
            text: tidy(entry.text),
            elements: [],
            dependsOn: parents,
            // Always `.text` here: a PDF has no `claim-ref` to be exact from, so every
            // edge in a PDF-imported claim tree is a reading of prose and the tree says
            // so.
            dependencySource: parents.isEmpty ? .none : .text)
    }

    private static func referencedClaims(in text: String, excluding own: Int) -> [Int] {
        let pattern = /\bclaims?\s+(\d{1,3})/.ignoresCase()
        var found: [Int] = []
        for match in text.matches(of: pattern) {
            guard let number = Int(match.1), number != own, number < own,
                !found.contains(number)
            else { continue }
            found.append(number)
        }
        return found
    }

    // MARK: - Front matter

    /// What a cover page calls the number, in the spellings the two offices use.
    private static let numberLabels = [
        "Patent Number", "Patent No", "Publication Number", "Publication No", "Pub. No",
    ]

    /// The patent number off the cover page, taken from the line that *labels* it.
    ///
    /// Anchoring on the label is the whole point. The obvious reading — the first thing
    /// near the top of the page that looks like a serial — picks up the attorney docket
    /// number: `Boston, MA 02210-2206` on an agent's address compacts to nine digits and
    /// is otherwise indistinguishable from a grant number, and a patent filed under it is
    /// unfindable. A docket is never labelled and the number always is: USPTO prints
    /// `(10) Patent No.: US 10,123,456 B2` and WIPO prints `(10) International
    /// Publication Number WO 2020/247738 A9`.
    private static func number(in lines: [String]) -> PatentKey? {
        for line in lines.prefix(60) {
            guard let tail = labelledNumber(in: line) else { continue }
            if let key = parseNumber(in: tail) { return key }
        }
        return nil
    }

    /// The number in the file's own name, but only where it names its office too.
    ///
    /// `WO2024153586A1.pdf` is a deliberate name and is trusted ahead of the running head,
    /// which is the same number with the kind code left off — WIPO does not print one in
    /// the head. `1004848.pdf` is not: a bare serial is assumed to be US by
    /// `PatentNumberParser`, correctly for a reader typing one into the find field and not
    /// at all for a downloaded file that could be from anywhere, so it ranks *below* what
    /// the document says about itself. Requiring the country code to be there in the name
    /// is what separates the two.
    ///
    /// A trailing `-pp`, `-annotated`, `_v2` is dropped and the name tried again, because
    /// that is what people add and none of it is a kind code.
    private static func qualifiedFilename(_ url: URL) -> PatentKey? {
        let stem = url.deletingPathExtension().lastPathComponent
        let candidates = [stem, String(stem.prefix(while: { $0 != "-" && $0 != "_" }))]

        for candidate in candidates {
            guard let key = PatentNumberParser.parse(candidate),
                candidate.uppercased().hasPrefix(key.country)
            else { continue }
            return key
        }
        return nil
    }

    /// The number off the running head, which every page of a publication carries.
    ///
    /// Worth having because the cover page is the one page whose text layer is least
    /// trustworthy. It is set in two columns around artwork, and extraction interleaves
    /// the number with the words beside it: one real PCT cover page comes out as
    /// `lntoern2atoio2na4I /Plu b5h3" ca5ti8on6NAumlber`, which is `International
    /// Publication Number` and `2024/153586` woven together character by character and is
    /// not recoverable from. The same number is plain text in the head of forty pages.
    private static func number(inHeads heads: Set<String>) -> PatentKey? {
        // Sorted so a document with two running heads picks the same one every time.
        heads.sorted().lazy.compactMap { parseNumber(in: $0) }.first
    }

    /// The longest run of up to three adjacent tokens in `text` that parses as a number.
    ///
    /// Longest-run-first because the cover page and the running head both set the office
    /// code, the serial and the kind code as three separate words. Reading them singly
    /// would take `2020/247738` on its own and return a *US* patent, since a bare serial is
    /// assumed to be US — right for a reader typing one into the find field, wrong for a
    /// WIPO page that said `WO` right next to it.
    private static func parseNumber(in text: some StringProtocol) -> PatentKey? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == ":" })
        guard !tokens.isEmpty else { return nil }

        for width in stride(from: min(3, tokens.count), through: 1, by: -1) {
            for start in 0 ... (tokens.count - width) {
                let joined = tokens[start ..< start + width].joined()
                if let key = PatentNumberParser.parse(joined), key.serial.count >= 7 {
                    return key
                }
            }
        }
        return nil
    }

    /// Whatever follows a number label on `line`, or `nil` if it carries none.
    private static func labelledNumber(in line: String) -> Substring? {
        for label in numberLabels {
            guard let range = line.range(of: label, options: .caseInsensitive) else { continue }
            // Drop the `.:` and the spaces between the label and the number.
            return line[range.upperBound...].drop { !$0.isLetter && !$0.isNumber }
        }
        return nil
    }

    /// The title, which on a cover page follows the `(54)` field code.
    ///
    /// Found by containment rather than by prefix, and its run-on lines stop at the next
    /// field code rather than at a line that opens with a bracket. Both allowances are for
    /// the same thing: a PCT cover page sets the bibliographic block sideways down the
    /// page, and extraction puts whatever glyph it made of the rule in front of every line
    /// of it. One real page comes out as `~ (54) Title: ANTISENSE MOLECULES...` followed by
    /// `~ PARTICULAR THE TREATMENT...` and then `~ (57) Abstract: ...`, where a prefix test
    /// finds no title and a bracket test runs the abstract onto the end of it.
    ///
    /// Best-effort and often wrong even so, which is why the caller passes a fallback: the
    /// filename is a poor title and a wrong one is worse.
    private static func title(in lines: [String]) -> String? {
        let field = /\(\d\d\)/
        guard let marker = lines.firstIndex(where: { $0.contains("(54)") }),
            let code = lines[marker].range(of: "(54)")
        else { return nil }

        var head = lines[marker][code.upperBound...].trimmingCharacters(in: .whitespaces)
        // WIPO sets the field as `(54) Title: METHODS OF...` where USPTO sets `(54)
        // METHODS OF...`. "Title:" is the field's label and not part of the title, and
        // left in it also defeats `capitalizedFirstLetterOnly` below — the mixed case
        // makes a shouted title look deliberate.
        if let label = head.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            head = head[label.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let continued = lines[(marker + 1)...].prefix(2)
            .prefix { !$0.isEmpty && $0.firstMatch(of: field) == nil }
            .map { String($0.drop { !$0.isLetter && !$0.isNumber }) }
        let title = ([head] + continued).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title.capitalizedFirstLetterOnly
    }
}

extension String {
    /// USPTO sets titles in full capitals on the cover page, and a shouted title in the
    /// library list is unreadable next to fetched ones. Only the first letter is raised,
    /// because title-casing would lowercase the acronyms patents are full of.
    fileprivate var capitalizedFirstLetterOnly: String {
        guard self == uppercased() else { return self }
        return prefix(1) + dropFirst().lowercased()
    }
}
