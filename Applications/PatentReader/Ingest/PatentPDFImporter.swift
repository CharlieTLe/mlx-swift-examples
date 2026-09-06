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
/// - **Paragraph numbers may be absent.** They are printed as `[0001]` from 2001
///   onwards and not before, and the fallback is `Numbering.synthesized`, which the
///   citation then admits to. Same machinery the HTML path uses for the same reason.
/// - **Two columns.** `PDFPage.string` reads a USPTO grant in content-stream order,
///   which is *usually* column by column and is not guaranteed. The `[nnnn]` sequence is
///   the check: if the recovered numbers are not strictly ascending, the columns were
///   read interleaved, and a document whose paragraphs are shuffled is worse than no
///   document. It is reported rather than imported.
enum PatentPDFImporter {

    /// Bump alongside `GooglePatentsParser.version` when a change here alters the
    /// `Patent` a given PDF produces. Separate counter, same job: it invalidates the
    /// index.
    static let version = 1

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case noTextLayer(pages: Int, characters: Int)
        case columnsOutOfOrder(at: Int, after: Int)
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

        let key =
            number(in: lines) ?? PatentNumberParser.parse(
                url.deletingPathExtension().lastPathComponent)
            ?? PatentKey(country: "US", serial: "000000", kind: nil)

        let (paragraphs, numbering) = try self.paragraphs(in: lines)
        // The claims are paragraphs too until something tells them apart, and the
        // preamble line is that something. Everything from it onwards becomes claims and
        // everything before it stays specification, so a paragraph is never both — which
        // it would be if the claims were merely *also* extracted, and the reader would
        // scroll past the claims twice.
        let boundary = claimSectionStart(in: paragraphs)
        let claims = self.claims(from: Array(paragraphs[(boundary ?? paragraphs.count)...]))
        let spec = Array(paragraphs[..<(boundary ?? paragraphs.count)])

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
                contentSHA256: GooglePatentsParser.digest(of: joined),
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
    private static func paragraphs(in lines: [String]) throws -> ([Paragraph], Numbering) {
        let marker = /^\[(\d{4})\]\s*(.*)$/

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

    /// Where the claims begin: the paragraph opening with the claim preamble.
    ///
    /// Every US grant prints one — "What is claimed is:", "We claim:" — and it is the
    /// only reliable boundary in extracted text. A document with none has no claims this
    /// importer will recognise, and `Source.note` says so rather than the reader
    /// discovering it by finding no Claims section.
    private static func claimSectionStart(in paragraphs: [Paragraph]) -> Int? {
        let preamble = /^(what is claimed is|we claim|i claim|the invention claimed is)/
            .ignoresCase()
        return paragraphs.firstIndex {
            (try? preamble.prefixMatch(in: $0.text)) != nil
        }
    }

    /// The claims, recovered from their own numbering.
    ///
    /// Split on a leading `N.` where `N` is the *next expected* number. Requiring the
    /// next one rather than any number is what keeps "35 U.S.C. 112" and a stray "2." in
    /// prose out of the claim list: a sequence has to be a sequence, and a number out of
    /// turn is text.
    private static func claims(from paragraphs: [Paragraph]) -> [Claim] {
        guard !paragraphs.isEmpty else { return [] }

        var claims: [Claim] = []
        var expected = 1
        var current: (number: Int, text: String)?

        for paragraph in paragraphs {
            let text = paragraph.text
            if let range = text.range(of: "\(expected). "),
                text[text.startIndex ..< range.lowerBound]
                    .allSatisfy({ !$0.isLetter && !$0.isNumber })
            {
                if let current { claims.append(claim(current)) }
                current = (expected, String(text[range.upperBound...]))
                expected += 1
                continue
            }
            if current != nil { current?.text += " " + text }
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

    /// The patent number off the cover page, which USPTO sets as `US 10,123,456 B2`.
    private static func number(in lines: [String]) -> PatentKey? {
        for line in lines.prefix(60) {
            guard line.contains("US") || line.contains("Patent No") else { continue }
            for token in line.split(whereSeparator: { $0 == " " || $0 == ":" }) {
                if let key = PatentNumberParser.parse(String(token)), key.serial.count >= 7 {
                    return key
                }
            }
            // `US 10,123,456 B2` is four tokens; try the whole line too.
            if let key = PatentNumberParser.parse(line), key.serial.count >= 7 {
                return key
            }
        }
        return nil
    }

    /// The title, which on a USPTO cover page follows a line of `(54)`.
    ///
    /// Best-effort and often wrong, which is why the caller passes a fallback: the
    /// filename is a poor title and a wrong one is worse.
    private static func title(in lines: [String]) -> String? {
        guard let marker = lines.firstIndex(where: { $0.hasPrefix("(54)") }) else {
            return nil
        }
        let head = lines[marker].dropFirst(4).trimmingCharacters(in: .whitespaces)
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
