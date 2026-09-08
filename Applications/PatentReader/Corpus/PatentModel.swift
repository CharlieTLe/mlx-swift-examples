// Copyright © 2026 Apple Inc.

import Foundation

/// One patent, as an importer produced it.
///
/// Strict `Codable`, on `PlayModel.swift`'s reasoning: a field the parser stopped
/// emitting should be a decode failure the self test catches, not a silently empty
/// document pane. Nothing here is bundled — the library is built by the reader, one
/// JSON file per patent under `Application Support/PatentReader/Library/` — so the
/// decode boundary is the only place a bad import can be caught before it reaches the
/// reader.
struct Patent: Codable, Sendable, Identifiable, Hashable {
    let schemaVersion: Int
    /// `PatentKey.slug`, e.g. `US10123456B2`. Duplicated out of `key` so the type is
    /// `Identifiable` by the same string the filename uses.
    let id: String
    let key: PatentKey
    let title: String
    let abstract: String
    let inventors: [String]
    let assignee: String?
    /// ISO-8601 dates as the source printed them, unparsed. A patent's dates are
    /// metadata to display and sort by, never arithmetic, and `Date` would invite a
    /// timezone question that has no answer for a publication date.
    let publicationDate: String?
    let priorityDate: String?
    let classifications: [Classification]
    let numbering: Numbering
    let source: Source
    let sections: [SpecSection]
    let claims: [Claim]
    /// Every reference numeral the source tagged, numeral → the term it labels.
    ///
    /// Authoritative rather than inferred: Google Patents marks these up as
    /// `<figure-callout id="100" label="heat sink">`, so the reader can style `100` as a
    /// part number without a regex guessing that every three-digit number is one. Empty
    /// for a source that carries no callouts, in which case nothing is styled — which is
    /// the right failure, since styling the wrong numbers is worse than styling none.
    let calloutNumerals: [Int: String]

    /// Every paragraph of every section, in document order. The flattened form is what
    /// the index, the citation resolver and the reader's row list all address.
    var paragraphs: [Paragraph] { sections.flatMap(\.paragraphs) }

    func paragraph(numbered number: Int) -> Paragraph? {
        paragraphs.first { $0.number == number }
    }

    func claim(numbered number: Int) -> Claim? {
        claims.first { $0.number == number }
    }
}

/// A CPC or IPC entry, code and the office's own human-readable gloss.
///
/// The description is kept rather than looked up later because it arrives free with the
/// code and because `H05K7/20336` means nothing to a reader who is not a patent
/// examiner. Both halves go in the front-page card; the code alone goes nowhere.
struct Classification: Codable, Sendable, Hashable {
    let code: String
    let description: String
}

/// A section of the specification: the source's own `<heading>` and the paragraphs filed
/// under it.
///
/// Sections are the document's own structure rather than something reconstructed, which
/// is what makes them safe to print as headings and to list in the navigator. A patent
/// whose first paragraphs precede any heading gets a section with an empty `heading`, and
/// the reader draws no rule for that one.
///
/// Named `SpecSection` and not `Section`, which is what it is: `SwiftUI.Section` is used
/// by every `List` in this app, and an unqualified `Section` in a view body resolves to
/// whichever is in scope. The sibling reader has the same collision with `Scene` and
/// qualifies its one use site; here the collision would recur at every list, so the model
/// type yields instead.
struct SpecSection: Codable, Sendable, Hashable {
    let heading: String
    let paragraphs: [Paragraph]

    /// Whether this section is worth putting in a retrieval index.
    ///
    /// Cross-reference boilerplate ("This application claims priority to…") and the
    /// brief description of the drawings ("FIG. 1 illustrates…") are both real text a
    /// reader may want to see, and both are noise to a question about the invention: the
    /// first is a chain of application numbers and the second is a figure index. They
    /// stay in the document and stay out of the index, which is a different decision
    /// from dropping them, and the reader can still scroll to them.
    var isIndexable: Bool {
        let folded = heading.lowercased()
        if folded.contains("cross") && folded.contains("reference") { return false }
        if folded.contains("brief description of the drawing") { return false }
        return true
    }
}

/// One paragraph of the specification.
///
/// `number` is what a citation prints, and what it *means* depends on `Patent.numbering`
/// — see there. `index` is the paragraph's position in the flattened document and is
/// always defined, which is what the reader's scroll target and the index's chunk keys
/// are built on: a number can be synthesized or duplicated across a bad import, and a
/// position cannot.
struct Paragraph: Codable, Sendable, Hashable {
    let index: Int
    let number: Int
    let text: String
    /// Whether `number` came from the document or from counting.
    ///
    /// Per paragraph rather than only per patent, even though `Patent.numbering` is what
    /// the citation reads, because it is what *decides* `Patent.numbering` and because a
    /// source that numbers some paragraphs and not others is a shape the parser has to
    /// be able to detect in order to refuse it.
    let hasPrintedNumber: Bool
}

/// One claim, with its dependencies as data.
///
/// `dependsOn` is the whole reason the claims pane can draw a tree rather than a list.
/// Where the source marks it up (`<claim-ref idref="CLM-00001">`) it is exact; where it
/// does not — older grants carry no `claim-ref` at all — it is recovered from the claim's
/// own text, and `dependencySource` records which, because the two deserve different
/// confidence and a reader looking at an indented tree deserves to know it was inferred.
struct Claim: Codable, Sendable, Hashable {
    /// Where a claim's dependency came from.
    enum DependencySource: String, Codable, Sendable {
        /// `<claim-ref idref>` in the source. Exact.
        case markup
        /// Recovered from "The method of claim 1" in the claim's own text. Reliable in
        /// practice and still a reading of prose, so it is labelled.
        case text
        /// An independent claim depends on nothing, and there is nothing to source.
        case none
    }

    let number: Int
    /// The claim's opening clause, **with its printed number removed**.
    ///
    /// The reader that stripped it drew the number in its own margin, and that reader is
    /// gone; the field keeps the shape because everything downstream now depends on it —
    /// and because one of them depends on putting it *back*. `PassageAnchors` anchors a
    /// claim on `"\(number). "` plus this, because the office's typesetter prints the
    /// number and it is what makes the anchor nearly unique.
    let text: String
    let elements: [ClaimElement]
    let dependsOn: [Int]
    let dependencySource: DependencySource

    var isIndependent: Bool { dependsOn.isEmpty }

    /// The whole claim as one run, which is what the index embeds and what a copied
    /// selection is resolved against.
    ///
    /// **Never an anchor.** `PassageAnchors` scored 3/20 with this against 20/20 with the
    /// number and the preamble: the office prints a claim as a preamble and a hanging
    /// indent, so its elements are separated in the document by line breaks that no
    /// `findString` crosses.
    var fullText: String {
        ([text] + elements.map(\.text)).joined(separator: " ")
    }
}

/// One of a claim's own sub-paragraphs, and how deep it is nested.
///
/// A claim is drafted as a preamble and a nested list — "A method comprising: / using
/// additive manufacturing techniques: / forming a lower shell; / forming an internal
/// matrix" — and the nesting is the claim's logical structure, not its layout. Flattened
/// with a depth rather than kept as a tree because a tree would have to be flattened again
/// for the index and for the terminal's `--claim`, and because the depth is the only part
/// of the nesting anything downstream reads.
struct ClaimElement: Codable, Sendable, Hashable {
    let depth: Int
    let text: String
}

/// What a paragraph number *is* in this patent.
///
/// This is `PlayModel`'s "(this edition)" idea carried over, and it earns its keep much
/// harder here. Shakespeare's line numbers are always this app's own, so one suffix on
/// every citation says so once. Patent paragraph numbers are the patent's own about half
/// the time and this app's the other half, and which one it is cannot be guessed from
/// the date: US7654321B2 is a 2010 grant whose printed `[0001]`s the source simply does
/// not expose, and US5000000A is a 1991 grant that has none to expose.
///
/// So the citation has to change shape rather than carry a constant apology.
/// `.printed` renders `[0042]`; `.synthesized` renders `¶42 (numbered by this reader)`,
/// because a reader who quotes `[0042]` into a brief and then looks for it in the
/// printed grant will not find it, and that is a failure this app would have caused.
enum Numbering: String, Codable, Sendable {
    /// The source gave a printed paragraph number for every paragraph.
    case printed
    /// The source gave none, so the importer counted from 1.
    case synthesized
}

/// Where a patent came from, recorded per patent rather than assumed.
///
/// The `NOTICE.md` idea from `Resources/Plays`, moved inside the document because the
/// library is per-reader: there is no checked-in corpus to write one notice for. Every
/// field here answers a question someone will actually ask — what was fetched, from
/// where, when, whether the bytes have changed since, and which parser read them.
/// `parserVersion` is additionally the index's invalidation lever: bump it and every
/// index built by the old parser stops matching.
struct Source: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case googlePatentsHTML
        case pdf
        case plainText
    }

    let kind: Kind
    let url: String?
    let retrieved: Date
    /// SHA-256 of the bytes that were parsed, hex.
    let contentSHA256: String
    let parserVersion: Int
    /// Anything the importer had to admit to — reconstructed numbering, a PDF with a
    /// thin text layer. Shown in the library row, so a document that came in badly says
    /// so before it is cited.
    let note: String?
}

// MARK: - Keys

/// Addresses one patent. `PlayModel`'s `SceneKey`, one level up.
///
/// The three components are kept apart rather than stored as one string because the
/// library search has to normalize `10,123,456` and `US 10123456 B2` and `us10123456b2`
/// onto the same patent, and that is a comparison of parts.
struct PatentKey: Hashable, Sendable, Codable {
    /// Two-letter office code, upper case: `US`, `EP`, `WO`.
    var country: String
    /// Digits only, no grouping commas.
    var serial: String
    /// `B2`, `A1`, … Optional because a reader who types a number rarely remembers it.
    var kind: String?

    var slug: String { country + serial + (kind ?? "") }

    /// `US 10,123,456 B2` — the form a patent is written in prose.
    ///
    /// Grouped in threes for US numbers only. Other offices do not group, and grouping
    /// an EP number would be inventing a convention.
    var display: String {
        let number = country == "US" ? Self.grouped(serial) : serial
        return ([country, number] + [kind].compactMap { $0 }).joined(separator: " ")
    }

    private static func grouped(_ digits: String) -> String {
        // Application publication serials are eleven digits (`20140030575`) and are
        // never grouped; grant serials are seven or eight and always are.
        guard digits.count <= 8, digits.allSatisfy(\.isNumber) else { return digits }
        var out: [Character] = []
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return String(out.reversed())
    }
}

/// Addresses one paragraph, for a citation and for the jump.
///
/// Carries `number` rather than the flattened index, because that is what the model
/// writes and what the reader reads. Resolving it to a row is the document's job and can
/// fail — a citation to `[0099]` in a patent with 41 paragraphs is exactly the failure
/// `CitationCheck.nonexistent` exists to render.
struct ParagraphKey: Hashable, Sendable, Codable {
    var patent: PatentKey
    var number: Int

    var slug: String { "\(patent.slug)-p\(String(format: "%04d", number))" }
}

/// Addresses one claim.
struct ClaimKey: Hashable, Sendable, Codable {
    var patent: PatentKey
    var number: Int

    var slug: String { "\(patent.slug)-c\(number)" }
}

/// Addresses a selected span of rows in the open document.
///
/// `first` and `last` are row indices, not paragraph numbers, exactly as
/// `PlayModel.PassageKey`'s are indices into `Scene.lines`: indices are always defined —
/// a selection can be nothing but a claim's elements — and a re-import that shifts them
/// is caught by a digest rather than by the key.
struct PassageKey: Hashable, Sendable, Codable {
    var patent: PatentKey
    var first: Int
    var last: Int

    var slug: String { "\(patent.slug)-\(first)_\(last)" }
}

/// What a citation points at. One type, because the scanner, the check, the chip, the
/// URL and the jump all have to agree about what was cited, and three parallel
/// enumerations would be three chances to disagree.
enum CitationTarget: Hashable, Sendable, Codable {
    case paragraph(ParagraphKey)
    case claim(ClaimKey)

    var patent: PatentKey {
        switch self {
        case .paragraph(let key): key.patent
        case .claim(let key): key.patent
        }
    }

    var slug: String {
        switch self {
        case .paragraph(let key): key.slug
        case .claim(let key): key.slug
        }
    }
}

// MARK: - Citations

/// The reference printed beside anything this app says about a patent.
enum Citation {

    /// `US 10,123,456 B2 · [0042]`, or `US 10,123,456 B2 · ¶42 (numbered by this
    /// reader)` where the source gave no printed numbers.
    ///
    /// The parenthetical is not modesty and it is not decoration. Roughly half the
    /// patents this app can import arrive without paragraph numbers — see `Numbering` —
    /// and a reader who copies `[0042]` into a brief and then opens the printed grant
    /// will not find it. Saying so costs six words and prevents a wrong citation in
    /// somebody else's document.
    static func string(_ target: CitationTarget, numbering: Numbering) -> String {
        switch target {
        case .paragraph(let key):
            "\(key.patent.display) · "
                + paragraphLabel(
                    key.number, numbering: numbering, country: key.patent.country)
        case .claim(let key):
            "\(key.patent.display) · claim \(key.number)"
        }
    }

    /// `[0042]`, or `¶42` where the numbering is this app's.
    ///
    /// The short form, for a chip inside prose about a patent already on screen. The
    /// synthesized case drops the qualifier here and keeps the `¶`, which is the whole
    /// signal in miniature: a bracketed number claims the patent's authority and a
    /// pilcrow does not, so the two never look alike even at chip size. The full
    /// qualifier is in the chip's accessibility label and its tooltip.
    static func chipLabel(_ target: CitationTarget, numbering: Numbering) -> String {
        switch target {
        case .paragraph(let key):
            numbering == .printed
                ? "[\(padded(key.number, country: key.patent.country))]" : "¶\(key.number)"
        case .claim(let key):
            "claim \(key.number)"
        }
    }

    private static func paragraphLabel(
        _ number: Int, numbering: Numbering, country: String
    ) -> String {
        numbering == .printed
            ? "[\(padded(number, country: country))]"
            : "¶\(number) (numbered by this reader)"
    }

    /// The marker as the office that published this document prints it.
    ///
    /// **Not one convention, and the difference is not cosmetic.** USPTO zero-pads to four,
    /// so paragraph 42 is `[0042]` and paragraph 100 is `[0100]`. WIPO writes `00` and then
    /// the number, so 1 is `[001]`, 10 is `[0010]` and 100 is `[00100]`.
    /// `PatentPDFImporter` states this at the top of the file and its marker regex accepts
    /// three to five digits *because* of it — and then this function padded every office's
    /// numbers to four regardless.
    ///
    /// On WO 2020247738 A9 that made 347 of 437 paragraph citations name a marker the
    /// publication does not contain: the app cited `[0309]` for a paragraph the office
    /// prints as `[00309]`. The 90 that were right are paragraphs 10 to 99, which is
    /// exactly the band where the two conventions agree — so the defect was invisible in
    /// any sample small enough to read, while being wrong about four fifths of the
    /// document. This is the failure `Citation.string`'s own note says the app must never
    /// cause: a number a reader copies into a brief and then cannot find in the grant.
    ///
    /// The country is the discriminator because the convention belongs to the office, and
    /// `PatentKey` already carries it — the same reasoning that makes `display` group US
    /// serials in threes and leave every other office's alone. Nothing is stored and no
    /// library is reindexed to know this. A third office that pads differently is a case
    /// here, not a redesign.
    private static func padded(_ number: Int, country: String) -> String {
        country == "WO" ? "00\(number)" : String(format: "%04d", number)
    }

    /// The cited text with the citation appended, which is what makes a passage pasted
    /// into notes traceable.
    ///
    /// Here rather than in the reader view for `PlayModel.Citation.quotation`'s reason:
    /// the two platforms copy through different mechanisms from different views — macOS
    /// hands an `NSItemProvider` to the responder chain, iOS writes `UIPasteboard` from
    /// a toolbar — and the *text* is the same either way.
    ///
    /// **What was selected**, verbatim, and not the paragraphs it fell inside. A drag across
    /// half a sentence is a request to quote half a sentence; handing back the two whole
    /// paragraphs it touched would be the app deciding what the reader meant to copy.
    /// `targets` therefore only supplies the trailer.
    ///
    /// The one case that arises only here is a selection this app could not place, and it is
    /// not rare enough to pass over in silence: 3% of paragraphs cannot be located in their
    /// own PDF, and a drag across a cover page or a figure caption falls outside every
    /// passage there is. So it is *said*, in the copied text itself, where it will still be
    /// true after the paste. A quotation in somebody's brief with no citation is a problem
    /// they can see; one with a citation this app guessed at is not.
    static func quotation(_ patent: Patent, text: String, targets: [CitationTarget]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return body }
        let references = targets.map { string($0, numbering: patent.numbering) }
        guard let trailer = trailer(references) else {
            return body + "\n\n\(patent.key.display) "
                + "(this reader could not tell which passage this is)"
        }
        return body + "\n\n" + trailer
    }

    /// One reference for a passage inside one paragraph, a range for a sweep across
    /// several, `nil` for a selection that cites nothing.
    ///
    /// Deduplicated in order, because a long paragraph is several rows and a long drag
    /// crosses one passage several times.
    private static func trailer(_ references: [String]) -> String? {
        var seen: Set<String> = []
        let unique = references.filter { seen.insert($0).inserted }
        guard let first = unique.first else { return nil }
        return unique.count == 1 ? first : "\(first) – \(unique[unique.count - 1])"
    }
}
