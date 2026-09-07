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
/// Three realities are handled rather than hoped about, and each of them reports rather
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
/// - **Two columns.** `PDFPage.string` reads a USPTO grant in content-stream order,
///   which is *usually* column by column and is not guaranteed. The `[nnnn]` sequence is
///   the check: if the recovered numbers are not strictly ascending, the columns were
///   read interleaved, and a document whose paragraphs are shuffled is worse than no
///   document. It is reported rather than imported.
enum PatentPDFImporter {

    /// Bump alongside `GooglePatentsParser.version` when a change here alters the
    /// `Patent` a given PDF produces. Separate counter, same job: it invalidates the
    /// index.
    static let version = 2

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
    /// misread rather than that paragraph being long. See `checkMerged`.
    private static let mergedShare = 0.5

    /// ...and only once that paragraph is this long in absolute terms. Some 3,000 words,
    /// which is past anything an office prints as one paragraph, so a document that is
    /// legitimately one or two paragraphs is not refused for being short.
    private static let mergedMinimum = 20_000

    static func load(_ url: URL, title fallbackTitle: String? = nil) throws -> Patent {
        guard let document = PDFDocument(url: url) else {
            throw Failure.unreadable(url.lastPathComponent)
        }

        var pages: [String] = []
        for index in 0 ..< document.pageCount {
            pages.append(document.page(at: index)?.string ?? "")
        }
        let joined = pages.joined(separator: "\n")
        let characters = joined.filter { !$0.isWhitespace }.count

        guard characters >= minimumCharacters else {
            throw pages.isEmpty || characters < minimumCharactersPerPage * max(1, pages.count)
                ? Failure.noTextLayer(pages: pages.count, characters: characters)
                : Failure.tooShort(characters: characters)
        }
        if characters < minimumCharactersPerPage * pages.count {
            throw Failure.noTextLayer(pages: pages.count, characters: characters)
        }

        let lines = joined.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        return try patent(from: lines, url: url, title: fallbackTitle)
    }

    /// The recovery itself, from the extracted lines.
    ///
    /// Split from `load` so `SelfTest` can drive it. What is worth asserting is which
    /// line starts a paragraph, where the claims begin and which number off the cover
    /// page is the document's; building a PDF to assert that through would be asserting
    /// PDFKit.
    static func patent(from lines: [String], url: URL, title fallbackTitle: String?) throws
        -> Patent
    {
        let key =
            number(in: lines) ?? PatentNumberParser.parse(
                url.deletingPathExtension().lastPathComponent)
            ?? PatentKey(country: "US", serial: "000000", kind: nil)

        // The claims are cut off the end *before* the paragraphs are recovered, rather
        // than picked out of them afterwards. They have to be: a claim carries no
        // `[nnnn]` marker of its own, so left in place the entire claim set is
        // continuation text and lands inside whichever specification paragraph happened
        // to be last. Cutting first also means a paragraph is never both, which it would
        // be if the claims were merely *also* extracted, and the reader would scroll past
        // the claims twice.
        let boundary = claimSectionStart(in: lines)
        let claims = self.claims(in: Array(lines[(boundary ?? lines.count)...]))
        let (spec, numbering) = try paragraphs(in: Array(lines[..<(boundary ?? lines.count)]))
        try checkMerged(spec)

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
                note: note(numbering: numbering, claims: claims.count)),
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

    private static func note(numbering: Numbering, claims: Int) -> String {
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
        if claims == 0 {
            parts.append("No claims were recognised.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Paragraphs

    /// Paragraphs, recovered from the `[0001]` markers where they exist.
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
    private static func paragraphs(in lines: [String]) throws -> ([Paragraph], Numbering) {
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

        guard numbered.count >= 3 else {
            // Too few markers to be this document's numbering — a pre-2001 grant, or a
            // file whose extraction lost them. Fall back to blank-line segmentation.
            return (blankLineParagraphs(in: lines), .synthesized)
        }

        // The column-order check. Strictly ascending or the columns were interleaved.
        for (previous, next) in zip(numbered, numbered.dropFirst())
        where next.number <= previous.number {
            throw Failure.columnsOutOfOrder(at: next.number, after: previous.number)
        }

        let paragraphs = numbered.enumerated().map { index, entry in
            Paragraph(
                index: index, number: entry.number, text: tidy(entry.text),
                hasPrintedNumber: true)
        }
        return (paragraphs, .printed)
    }

    /// Refuses an import in which one paragraph swallowed the rest of the document.
    ///
    /// The same kind of check as `columnsOutOfOrder`, for the same reason. The paragraph
    /// breaks are the only structure this recovery has, and when they stop being found —
    /// a marker scheme it does not know, an OCR'd grant where `[0001]` came out as
    /// `0001.` and the brackets are simply gone, a file with no blank lines to fall back
    /// on — *nothing fails*. Every later line is appended to the last paragraph that did
    /// break, and the result imports cleanly, shows one unreadable row, and answers every
    /// question with a citation to the same paragraph. Silent, so it has to be looked for
    /// rather than waited for.
    ///
    /// Share of the text rather than a multiple of the median, because patents do have
    /// long paragraphs — a table, a sequence listing — and a long paragraph is only
    /// suspicious when it is most of the document. The absolute floor is what makes the
    /// share safe to trust: 20,000 characters is some 3,000 words, which no paragraph any
    /// office prints comes near, so a short document that is legitimately one or two
    /// paragraphs is not refused for being short.
    private static func checkMerged(_ paragraphs: [Paragraph]) throws {
        let lengths = paragraphs.map(\.text.count)
        let total = lengths.reduce(0, +)
        guard let largest = lengths.max(), let index = lengths.firstIndex(of: largest),
            largest >= mergedMinimum, total > 0
        else { return }

        let share = Double(largest) / Double(total)
        guard share > mergedShare else { return }
        throw Failure.paragraphsMerged(
            number: paragraphs[index].number, percent: Int((share * 100).rounded()))
    }

    /// Paragraphs from blank lines, for a document with no markers.
    ///
    /// Crude and labelled as such in `Source.note`. A patent set in two columns with no
    /// paragraph numbers is the hardest case this app has, and the honest output is
    /// paragraphs that are roughly right with numbering that says it is this app's own.
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

        return
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

    /// Where the claims begin: the line opening with the claim preamble.
    ///
    /// Every US grant and every PCT publication prints one — "What is claimed is:", "We
    /// claim:" — and it is the only reliable boundary in extracted text. A document with
    /// none has no claims this importer will recognise, and `Source.note` says so rather
    /// than the reader discovering it by finding no Claims section.
    ///
    /// A line rather than a paragraph, because the claims have to be cut off *before*
    /// paragraph recovery runs: a claim carries no `[nnnn]` marker, so by the time there
    /// are paragraphs the preamble is buried mid-paragraph and there is no boundary left
    /// to find.
    private static func claimSectionStart(in lines: [String]) -> Int? {
        lines.firstIndex { (try? claimPreamble.prefixMatch(in: $0)) != nil }
    }

    /// The claims, recovered from their own numbering, given the lines from the preamble
    /// onwards.
    ///
    /// Split on a line opening with `N.` where `N` is the *next expected* number.
    /// Requiring the next one rather than any number is what keeps "35 U.S.C. 112" and a
    /// stray "2." in prose out of the claim list: a sequence has to be a sequence, and a
    /// number out of turn is text. Requiring a space or the line's end after the dot is
    /// the other half of it, and is what keeps "1.5 mL" from opening claim 1 — while
    /// still admitting a bare `8.` alone on a line, which extraction produces often
    /// enough, the number and its text having landed in different text runs.
    ///
    /// Stops at a text-less page, which is what a run of blank lines means here. Both
    /// offices set the claims on their own sheets, and what follows them in the file is a
    /// different document — a PCT search report, a drawing set — which would otherwise be
    /// appended wholesale to the last claim, since nothing in it is numbered next.
    private static func claims(in lines: [String]) -> [Claim] {
        guard let first = lines.first else { return [] }

        // The preamble is stripped rather than skipped, because a cover page sometimes
        // sets claim 1 on the same line as it.
        var body = Array(lines.dropFirst())
        if let match = try? claimPreamble.prefixMatch(in: first) {
            let remainder = String(first[match.range.upperBound...])
            if !remainder.isEmpty { body.insert(remainder, at: 0) }
        }

        let lead = /^(\d{1,3})\.(?:\s+(.*))?$/
        var claims: [Claim] = []
        var expected = 1
        var current: (number: Int, text: String)?
        var blanks = 0

        for line in body {
            if line.isEmpty {
                blanks += 1
                if blanks >= 2, current != nil { break }
                continue
            }
            blanks = 0

            if let match = try? lead.wholeMatch(in: line), Int(match.1) == expected {
                if let current { claims.append(claim(current)) }
                current = (expected, match.2.map(String.init) ?? "")
                expected += 1
                continue
            }
            if current != nil { current?.text += " " + line }
        }
        if let current { claims.append(claim(current)) }
        return claims
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
    ///
    /// Tokens are joined longest-run-first because the cover page sets the office code,
    /// the serial and the kind code as three separate words. Reading them singly would
    /// take `2020/247738` on its own and return a *US* patent, since a bare serial is
    /// assumed to be US — right for a reader typing one and wrong for a WIPO cover page.
    ///
    /// Nothing labelled means `nil`, and the caller falls back to the filename. That is
    /// the common case for a PCT publication, where the number is set in the header
    /// artwork and never reaches the text layer at all.
    private static func number(in lines: [String]) -> PatentKey? {
        for line in lines.prefix(60) {
            guard let tail = labelledNumber(in: line) else { continue }
            let tokens = tail.split(whereSeparator: { $0 == " " || $0 == ":" })
            guard !tokens.isEmpty else { continue }

            for width in stride(from: min(3, tokens.count), through: 1, by: -1) {
                for start in 0 ... (tokens.count - width) {
                    let joined = tokens[start ..< start + width].joined()
                    if let key = PatentNumberParser.parse(joined), key.serial.count >= 7 {
                        return key
                    }
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

    /// The title, which on a cover page follows a line of `(54)`.
    ///
    /// Best-effort and often wrong, which is why the caller passes a fallback: the
    /// filename is a poor title and a wrong one is worse.
    private static func title(in lines: [String]) -> String? {
        guard let marker = lines.firstIndex(where: { $0.hasPrefix("(54)") }) else {
            return nil
        }
        var head = lines[marker].dropFirst(4).trimmingCharacters(in: .whitespaces)
        // WIPO sets the field as `(54) Title: METHODS OF...` where USPTO sets `(54)
        // METHODS OF...`. "Title:" is the field's label and not part of the title, and
        // left in it also defeats `capitalizedFirstLetterOnly` below — the mixed case
        // makes a shouted title look deliberate.
        if let label = head.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            head = head[label.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let continued = lines[(marker + 1)...].prefix(2)
            .prefix { !$0.isEmpty && !$0.hasPrefix("(") }
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
