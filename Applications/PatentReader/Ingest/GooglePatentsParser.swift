// Copyright © 2026 Apple Inc.

import CryptoKit
import Foundation

/// Reads a Google Patents page into a `Patent`.
///
/// ## What the markup actually looks like
///
/// The page is server-rendered — no JavaScript needed, 200 KB, one request — and the
/// parts that matter are machine-generated and regular. What is *not* regular, and what
/// this parser exists to absorb, is that they are regular in **four different ways**.
/// Measured across five patents fetched while writing this:
///
/// | Shape | Paragraph element | Printed number? | Seen in |
/// |---|---|---|---|
/// | A | `<div id="p-0002" num="0001" class="description-paragraph">` | yes, in `num` | US10123456B2 |
/// | A′ | the same, but `class="description-line"` | yes | US20140030575A1 |
/// | B | `<div num="p-0002" class="description-paragraph">` | **no** — `num` holds the id | US7654321B2 |
/// | C | `<div class="description-paragraph">` | no | US5000000A, US6285999B1 |
///
/// Three things follow, and each is a decision the rest of the app is built on.
///
/// **`num` is only a paragraph number when it is digits.** In shape B it holds
/// `p-0002`, which is the *id* in a `num` attribute, and reading it as a number would
/// print `[2]` beside a paragraph the patent numbers `[0001]`. And in shape A the `id`
/// is offset from the `num` — `id="p-0002"` carries `num="0001"` — so the id suffix is
/// not the number either, and the offset is an artifact of how many non-paragraph nodes
/// precede rather than a constant. Cite `num` when it parses as an integer, ignore `id`
/// always.
///
/// **Missing paragraph numbers are not a pre-2001 problem.** That was the assumption
/// going in and it is wrong: US7654321B2 is a 2010 grant with printed `[0001]`s that
/// this source simply does not expose. So `Numbering` is a property of *what arrived*,
/// not of the patent's age, and the honest citation follows from that rather than from a
/// date comparison.
///
/// **`<claim-ref idref>` is not always there.** Where it is, the claim dependency graph
/// is exact data and no prose has to be read. Where it is not — US5000000A and
/// US6285999B1 have `div.claim-dependent` wrappers and zero `claim-ref` elements — the
/// dependency has to come from the claim's own text, and `Claim.dependencySource`
/// records which, because a tree drawn from inferred edges deserves to say so.
///
/// ## Discipline
///
/// The parser looks only for the shapes named in this file. Anything it was not told
/// about, it does not see — which is the property that makes markup drift a *failure*
/// rather than a subtly wrong document, and the reason `HTMLScanner` is a hundred lines
/// instead of a dependency. Its counterpart is that a missing block is an error and not
/// an empty section: see `Failure`.
///
/// `version` is stored on every patent and is the index's invalidation lever.
enum GooglePatentsParser {

    /// Bump on any change that alters the `Patent` a given page produces.
    ///
    /// 1: initial. Handles paragraph shapes A, A′, B and C, `claim-ref` and text-derived
    /// claim dependencies, `<meta>` front matter, `itemprop="classifications"`, and
    /// `figure-callout` reference numerals.
    static let version = 1

    enum Failure: LocalizedError, Equatable {
        case noDescription
        case noClaims
        case wrongPatent(requested: String, received: String)
        case mixedNumbering(numbered: Int, total: Int)
        case numberingOutOfOrder(at: Int)
        case danglingClaimReference(claim: Int, idref: String)

        var errorDescription: String? {
            switch self {
            case .noDescription:
                "The page carried no specification paragraphs. Either the patent has no "
                    + "published description, or the markup changed — run --selftest, "
                    + "which compares the parser against checked-in fixtures."
            case .noClaims:
                "The page carried no claims. Design patents and some published "
                    + "applications legitimately have none worth indexing; a granted "
                    + "utility patent with none means the markup changed."
            case .wrongPatent(let requested, let received):
                "Asked for \(requested) and the page returned \(received). Google "
                    + "Patents redirects to a family member when a number is not found."
            case .mixedNumbering(let numbered, let total):
                "\(numbered) of \(total) paragraphs carry a printed number. The parser "
                    + "cannot tell which numbering a citation should claim, so it "
                    + "refuses rather than guessing."
            case .numberingOutOfOrder(let at):
                "Paragraph numbers stop ascending at \(at), so they are not the "
                    + "document's own sequence."
            case .danglingClaimReference(let claim, let idref):
                "Claim \(claim) references \(idref), which is not a claim of this patent."
            }
        }
    }

    /// Parses `html`, which must be the whole page.
    ///
    /// - Parameter requested: the number that was asked for, checked against the page's
    ///   own. Google Patents answers an unknown number with a family member rather than
    ///   a 404, so without this an import can silently produce the wrong document.
    static func parse(
        _ html: String, requested: PatentKey?, url: String?, retrieved: Date = Date()
    ) throws -> Patent {
        let roots = HTMLScanner.parse(Substring(html))
        let metadata = Metadata(roots: roots)

        guard let key = metadata.key ?? requested else {
            throw Failure.wrongPatent(requested: requested?.slug ?? "?", received: "?")
        }
        if let requested, let found = metadata.key,
            found.country != requested.country
                || found.serial != requested.serial
        {
            throw Failure.wrongPatent(requested: requested.slug, received: found.slug)
        }

        let sections = try specification(in: roots)
        guard !sections.isEmpty, sections.contains(where: { !$0.paragraphs.isEmpty })
        else { throw Failure.noDescription }

        let claims = try self.claims(in: roots)
        guard !claims.isEmpty else { throw Failure.noClaims }
        try validate(claims)

        // Decided by the *source*, never by the date. US7654321B2 is a 2010 grant with
        // printed `[0001]`s that this page does not expose, so "post-2001 means
        // numbered" is false and a date test would have this patent citing paragraph
        // numbers it does not have. What is known here is only whether a number arrived.
        let numbering: Numbering =
            sections.contains { section in
                section.paragraphs.contains { $0.hasPrintedNumber }
            } ? .printed : .synthesized

        return Patent(
            schemaVersion: 1,
            id: key.slug,
            key: key,
            title: metadata.title ?? key.display,
            abstract: abstract(in: roots),
            inventors: metadata.inventors,
            assignee: metadata.assignee,
            publicationDate: metadata.publicationDate,
            priorityDate: metadata.priorityDate,
            classifications: classifications(in: roots),
            numbering: numbering,
            source: Source(
                kind: .googlePatentsHTML,
                url: url,
                retrieved: retrieved,
                contentSHA256: Self.digest(of: html),
                parserVersion: version,
                note: numbering == .synthesized
                    ? "This source carried no printed paragraph numbers, so they are "
                        + "counted from 1 by this reader. Citations say so."
                    : nil),
            sections: sections,
            claims: claims,
            calloutNumerals: calloutNumerals(in: roots))
    }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Front matter

    /// The front page, read from `<meta>` rather than from the rendered page.
    ///
    /// The metas are far more stable than the body: they are a citation interchange
    /// format other tools consume, where the visible front page is layout that gets
    /// redesigned. Every field here comes from one, except the title, which is
    /// cross-checked against the `<h1>` because the meta's is whitespace-padded.
    private struct Metadata {
        var key: PatentKey?
        var title: String?
        var inventors: [String] = []
        var assignee: String?
        var publicationDate: String?
        var priorityDate: String?

        init(roots: [HTMLScanner.Node]) {
            for meta in roots.flatMap({ $0.descendants(named: "meta") }) {
                let content = (meta["content"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }

                switch (meta["name"], meta["scheme"]) {
                case ("citation_patent_number", _):
                    // `US:10123456` — the office and the serial, colon-separated, with
                    // no kind code. The kind comes off the page title below, which is
                    // the only place it appears.
                    key = PatentNumberParser.parse(
                        content.replacingOccurrences(of: ":", with: ""))
                case ("DC.title", _):
                    title = content
                case ("DC.contributor", "inventor"):
                    inventors.append(content)
                case ("DC.contributor", "assignee"):
                    // First wins: the list is current assignee then original, and the
                    // current one is what a reader is looking for.
                    assignee = assignee ?? content
                case ("DC.date", "issue"):
                    publicationDate = content
                case ("DC.date", "dateSubmitted"):
                    priorityDate = content
                case ("DC.date", nil):
                    // A published application has no issue date, and its bare `DC.date`
                    // is the publication. Written as a fallback rather than a
                    // replacement so a grant, which carries both, keeps the issue date.
                    publicationDate = publicationDate ?? content
                default:
                    break
                }
            }

            // `US10123456B2 - Phase change material heat sink … - Google Patents`. The
            // kind code lives only here; the title is taken from the meta above because
            // this one is wrapped in the page's own suffix.
            if let heading = roots.flatMap({ $0.descendants(named: "h1") })
                .first(where: { $0["itemprop"] == "pageTitle" })?.textContent,
                let lead = heading.split(separator: "-").first
            {
                let parsed = PatentNumberParser.parse(String(lead))
                if let parsed, parsed.kind != nil { key = parsed }
            }
        }
    }

    private static func abstract(in roots: [HTMLScanner.Node]) -> String {
        roots.flatMap { $0.descendants(named: "abstract") }.first?.textContent ?? ""
    }

    /// CPC and IPC entries, code plus the office's own gloss.
    ///
    /// **Scoped to the page's own Classifications section, and that scoping is
    /// load-bearing.** `itemprop="classifications"` appears 64 times on US5000000A: once
    /// for this patent's hierarchy and the rest inside "Similar Documents" and "Cited
    /// By", which are other patents' classifications. Taking them all gave that patent
    /// 31 codes, most of them somebody else's — a front page that is quietly about the
    /// wrong invention. The `<section>` whose `<h2>` reads "Classifications" is the pin.
    ///
    /// The list is nested, and the nesting is the hierarchy: `H` → `H05` → `H05K` →
    /// `H05K7/20336`. All levels are kept rather than only the leaf, because
    /// "ELECTRICITY" is what tells a reader what field they are in and the leaf code
    /// alone tells them nothing.
    private static func classifications(in roots: [HTMLScanner.Node]) -> [Classification] {
        let sections = roots.flatMap { $0.descendants(named: "section") }
        guard
            let section = sections.first(where: { section in
                section.descendants(named: "h2")
                    .contains { $0.textContent == "Classifications" }
            })
        else { return [] }

        var found: [Classification] = []
        var seen: Set<String> = []

        func walk(_ node: HTMLScanner.Node) {
            if node["itemprop"] == "classifications" {
                let code = node.descendants(named: "span")
                    .first { $0["itemprop"] == "Code" }?.textContent
                let description = node.descendants(named: "span")
                    .first { $0["itemprop"] == "Description" }?.textContent
                if let code, !code.isEmpty, seen.insert(code).inserted {
                    found.append(
                        Classification(code: code, description: description ?? ""))
                }
            }
            for child in node.children where !child.isText { walk(child) }
        }

        walk(section)
        return found
    }

    // MARK: - Specification

    /// The specification, as sections of paragraphs.
    ///
    /// Both class spellings are accepted — `description-paragraph` and
    /// `description-line`, which are shapes A and A′ and differ for no reason this
    /// parser can see — and a paragraph belongs to the last `<heading>` above it.
    /// Paragraphs before the first heading get a section with an empty name rather than
    /// being dropped; US5000000A opens with a government-support statement above any
    /// heading, and dropping it would lose a paragraph a reader may well cite.
    private static func specification(in roots: [HTMLScanner.Node]) throws -> [SpecSection] {
        guard
            let description = roots.compactMap({ node -> HTMLScanner.Node? in
                if node.hasClass("description") { return node }
                return node.descendants(class: "description").first
            }).first
        else { throw Failure.noDescription }

        var sections: [(heading: String, paragraphs: [Paragraph])] = [("", [])]
        var index = 0
        var printed: [Int] = []
        var total = 0

        func walk(_ node: HTMLScanner.Node) {
            if node.name == "heading" {
                let text = node.textContent
                if !text.isEmpty { sections.append((text, [])) }
                return
            }
            if node.hasClass("description-paragraph") || node.hasClass("description-line") {
                let text = node.textContent
                total += 1
                // A `num` is a paragraph number only when it is digits: shape B puts
                // `p-0002` there. Zero means "none", and `Numbering` is decided from
                // whether any paragraph is left at zero.
                let declared = node["num"].flatMap(Int.init)
                if let declared { printed.append(declared) }
                guard !text.isEmpty else { return }
                sections[sections.count - 1].paragraphs.append(
                    Paragraph(
                        index: index, number: declared ?? (index + 1), text: text,
                        hasPrintedNumber: declared != nil))
                index += 1
                return
            }
            for child in node.children where !child.isText { walk(child) }
        }

        walk(description)

        // Either every paragraph carries a printed number or none does. A page where
        // some do is a shape this parser has not seen, and guessing which numbering the
        // citation should claim is exactly the guess that puts a wrong `[0042]` in
        // somebody's brief.
        if !printed.isEmpty, printed.count != total {
            throw Failure.mixedNumbering(numbered: printed.count, total: total)
        }
        if let broken = zip(printed, printed.dropFirst()).first(where: { $0 >= $1 }) {
            throw Failure.numberingOutOfOrder(at: broken.1)
        }

        return
            sections
            .filter { !$0.heading.isEmpty || !$0.paragraphs.isEmpty }
            .map { SpecSection(heading: $0.heading, paragraphs: $0.paragraphs) }
    }

    /// Reference numerals, numeral → the term the source says it labels.
    ///
    /// `<figure-callout id="100" label="heat sink">heat sink</figure-callout>` repeated
    /// once per mention, so this is a deduplicating pass over a few hundred elements.
    /// The `id` is the numeral despite the name.
    ///
    /// Empty is a fine answer and produces a document with no numerals styled, which is
    /// the right degradation: styling nothing is a missing feature, and styling the
    /// wrong three-digit numbers is a document that lies about which numbers are parts.
    private static func calloutNumerals(in roots: [HTMLScanner.Node]) -> [Int: String] {
        var found: [Int: String] = [:]
        for callout in roots.flatMap({ $0.descendants(named: "figure-callout") }) {
            guard let numeral = callout["id"].flatMap(Int.init) else { continue }
            let label = callout["label"] ?? callout.textContent
            guard !label.isEmpty else { continue }
            // First label wins. A numeral is occasionally given two labels across a long
            // specification ("shell" then "lower shell"), and the first is the one the
            // patent introduces it with.
            if found[numeral] == nil { found[numeral] = label }
        }
        return found
    }

    // MARK: - Claims

    /// The claims, with their dependency edges.
    ///
    /// The markup wraps each claim in either `div.claim` (independent) or
    /// `div.claim-dependent`, and puts the claim itself in a nested `div.claim` carrying
    /// `num`. The wrapper is the discriminator rather than the text, which is what makes
    /// independence exact.
    private static func claims(in roots: [HTMLScanner.Node]) throws -> [Claim] {
        guard
            let container = roots.compactMap({ node -> HTMLScanner.Node? in
                if node.hasClass("claims") { return node }
                return node.descendants(class: "claims").first
            }).first
        else { throw Failure.noClaims }

        // Ids to numbers, so a `claim-ref idref="CLM-00001"` can be resolved without
        // parsing the id's digits — which would be the shape-B mistake all over again.
        var numbers: [String: Int] = [:]
        var wrappers: [(node: HTMLScanner.Node, isDependent: Bool)] = []

        func walk(_ node: HTMLScanner.Node, dependent: Bool) {
            let isWrapper = node.hasClass("claim") || node.hasClass("claim-dependent")
            let dependent = dependent || node.hasClass("claim-dependent")

            if isWrapper, let number = node["num"].flatMap(claimNumber) {
                if let id = node["id"] { numbers[id] = number }
                wrappers.append((node, dependent))
                return
            }
            for child in node.children where !child.isText {
                walk(child, dependent: dependent)
            }
        }

        walk(container, dependent: false)

        var claims: [Claim] = []
        for (node, isDependent) in wrappers {
            let number = node["num"].flatMap(claimNumber) ?? 0
            guard number > 0 else { continue }

            // The claim's preamble and its nested sub-paragraphs. A claim is drafted as
            // a list — "A method comprising: / using additive manufacturing techniques:
            // / forming a lower shell;" — nested in the markup as `div.claim-text`
            // inside `div.claim-text`, and that nesting is the claim's logic rather than
            // its layout, so it is flattened to a depth rather than discarded.
            var blocks = claimText(of: node)
            guard !blocks.isEmpty else { continue }
            let head = stripLeadingNumber(blocks.removeFirst().text, number: number)
            guard !head.isEmpty || !blocks.isEmpty else { continue }

            let references = node.descendants(named: "claim-ref")
            var dependsOn: [Int] = []
            var dependencySource: Claim.DependencySource = .none

            if isDependent {
                if !references.isEmpty {
                    dependencySource = .markup
                    for reference in references {
                        guard let idref = reference["idref"] else { continue }
                        guard let parent = numbers[idref] else {
                            throw Failure.danglingClaimReference(
                                claim: number, idref: idref)
                        }
                        if !dependsOn.contains(parent) { dependsOn.append(parent) }
                    }
                }
                if dependsOn.isEmpty {
                    // Older grants carry no `claim-ref`. The claim's own text says
                    // "The method of claim 1" or "according to claim 1", and reading it
                    // is the only way to draw the tree those patents also have.
                    let whole = ([head] + blocks.map(\.text)).joined(separator: " ")
                    let recovered = referencedClaims(in: whole, excluding: number)
                    if !recovered.isEmpty {
                        dependsOn = recovered
                        dependencySource = .text
                    }
                }
            }

            claims.append(
                Claim(
                    number: number, text: head, elements: blocks,
                    dependsOn: dependsOn, dependencySource: dependencySource))
        }

        return claims.sorted { $0.number < $1.number }
    }

    /// A claim's text blocks, flattened depth-first with their nesting depth.
    ///
    /// The first is the preamble and gets depth 0; each nested `div.claim-text` is one
    /// level further in. Only a node's *own* text is taken at each level — see
    /// `directText` — because the outer block contains the inner ones, so
    /// `textContent` on it would repeat the whole claim as its own preamble.
    private static func claimText(of node: HTMLScanner.Node) -> [ClaimElement] {
        var out: [ClaimElement] = []

        func walk(_ node: HTMLScanner.Node, depth: Int) {
            let own = directText(of: node)
            if !own.isEmpty { out.append(ClaimElement(depth: depth, text: own)) }
            for child in node.descendants(class: "claim-text") {
                walk(child, depth: depth + 1)
            }
        }

        let blocks = node.descendants(class: "claim-text")
        guard !blocks.isEmpty else {
            let text = node.textContent
            return text.isEmpty ? [] : [ClaimElement(depth: 0, text: text)]
        }
        for block in blocks { walk(block, depth: 0) }
        // Depths are relative to whichever top-level block they came from; a claim whose
        // preamble and elements are siblings rather than nested (US6285999B1) therefore
        // has every block at 0, which is correct — that claim is printed flat.
        return out
    }

    /// `00001` and `1` are both claim one. `p-0002` is not a claim number at all, and
    /// returning nil for it is what keeps the shape-B trap out of the claims too.
    private static func claimNumber(_ raw: String) -> Int? {
        guard raw.allSatisfy(\.isNumber) else { return nil }
        return Int(raw)
    }

    /// A node's text down to, but not into, its nested `claim-text` blocks.
    ///
    /// Needed because a claim's preamble and its elements live in the *same*
    /// `div.claim-text`: the outer one holds "A method comprising:" as loose text and
    /// then the element divs as children, so `textContent` on it returns the whole claim
    /// and the preamble cannot be told from the rest.
    ///
    /// Inline markup is descended into rather than skipped, and that distinction is the
    /// whole content of this function. Taking only *direct* text children was the first
    /// version, and it silently deleted the two things this parser most needs: the claim
    /// number, which some sources set as `<b>1</b>.`, and the cross-reference, which is
    /// `<claim-ref>claim 1</claim-ref>`. Claims came out reading "The method of ,
    /// further comprising" — and worse, the text-recovery fallback for sources with no
    /// `claim-ref` then found no number and reported all 29 claims of US6285999B1 as
    /// independent.
    private static func directText(of node: HTMLScanner.Node) -> String {
        var out = ""

        func walk(_ node: HTMLScanner.Node) {
            for child in node.children {
                if let text = child.text {
                    out += text
                } else if !child.hasClass("claim-text") {
                    walk(child)
                }
            }
        }

        walk(node)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Drops the claim's own printed number from the front of its text.
    ///
    /// The source prints it and the reader draws it in the margin, so leaving it would
    /// print it twice. Written as a scan rather than a `hasPrefix` because the number is
    /// wrapped in `<b>` in some sources — `<b>1</b>. An apparatus` — and inline markup
    /// leaves a space behind it, so the printed forms in the fixtures are `1. `, `1 . `
    /// and `1) `. Anchored on the claim's *own* number, so a claim that genuinely opens
    /// with a figure is untouched.
    private static func stripLeadingNumber(_ text: String, number: Int) -> String {
        var rest = Substring(text).drop(while: \.isWhitespace)
        guard rest.hasPrefix("\(number)") else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        rest = rest.dropFirst("\(number)".count).drop(while: \.isWhitespace)
        guard let separator = rest.first, ".)".contains(separator) else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Claim numbers named in a claim's prose, for the sources that carry no
    /// `claim-ref`.
    ///
    /// Deliberately narrow. It matches `claim 1`, `claims 1 and 3`, `claim 1 or 2` — the
    /// forms a dependent claim's opening clause uses — and it excludes the claim's own
    /// number, because "the method of claim 3" inside claim 3 is a thing an OCR'd
    /// document says and a self-edge would put a claim under itself in the tree.
    private static func referencedClaims(in text: String, excluding own: Int) -> [Int] {
        // Built per call rather than held in a `static let`: `Regex` is not `Sendable`,
        // and this runs a few dozen times per import.
        let pattern = /\bclaims?\s+(\d{1,3})(?:\s*(?:,|or|and|to|-|–)\s*(\d{1,3}))*/
            .ignoresCase()
        var found: [Int] = []
        for match in text.matches(of: pattern) {
            for capture in [match.1, match.2] {
                guard let capture, let number = Int(capture), number != own,
                    !found.contains(number)
                else { continue }
                found.append(number)
            }
        }
        return found
    }

    /// Every dependency resolves, nothing depends on a later claim, and nothing depends
    /// on itself.
    ///
    /// "Nothing depends on a later claim" is a rule of patent drafting rather than a
    /// property of this parser, and it is checked here because it is the cheapest signal
    /// that a text-recovered edge went wrong: a forward reference in a dependency clause
    /// is almost always a sentence about claim scope that was read as a dependency.
    private static func validate(_ claims: [Claim]) throws {
        let numbers = Set(claims.map(\.number))
        for claim in claims {
            for parent in claim.dependsOn {
                guard numbers.contains(parent), parent < claim.number else {
                    throw Failure.danglingClaimReference(
                        claim: claim.number, idref: "claim \(parent)")
                }
            }
        }
    }
}
