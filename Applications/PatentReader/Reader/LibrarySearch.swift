// Copyright © 2026 Apple Inc.

import Foundation

/// The library's find field, as a function of the library and a query.
///
/// A pure function rather than something the view does inline, so `SelfTest` can assert
/// the matching rules without a view — `NavigatorSearch`'s reason, and its `fold` is
/// ported verbatim because case- and diacritic-insensitive with apostrophes dropped is
/// exactly right for titles and assignee names too.
///
/// What is new is that the field is **three readings racing**, and the first that
/// recognises the query wins. A patent library's search box is asked three different
/// kinds of thing and they want three different answers: a number is a request to open
/// or fetch a document, a locator is a request to jump inside the one already open, and
/// everything else is a filter.
enum LibrarySearch {

    enum Query: Equatable, Sendable {
        /// Nothing typed. The whole library, in order.
        case all
        /// `US10123456`, `10,123,456`, `US 10123456 B2`. Opens it, or offers to fetch it.
        case number(PatentKey)
        /// `[0042]`, `¶42` or `claim 7`. A *jump*, not a filter — nobody types a
        /// paragraph number hoping to see a shorter list.
        case locator(LocatorKind)
        /// Substring, folded, over title and assignee and inventors.
        case text(String)
    }

    enum LocatorKind: Equatable, Sendable {
        case paragraph(Int)
        case claim(Int)
    }

    /// What the reader typed, read.
    ///
    /// Order matters and is the whole design. The locator forms are tested first because
    /// `claim 7` also contains a number and `[0042]` would parse as a serial if it
    /// reached `PatentNumberParser`; the number form is tested next because
    /// `PatentNumberParser.looksLikeNumber` is deliberately strict, so a title that
    /// happens to be numeric falls through rather than triggering a fetch.
    static func parse(_ raw: String) -> Query {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .all }

        if let match = try? /^\[?\s*[¶#]?\s*0*(\d{1,5})\s*\]$/.wholeMatch(in: trimmed),
            let number = Int(match.1)
        {
            return .locator(.paragraph(number))
        }
        if let match = try? /^¶\s*0*(\d{1,5})$/.wholeMatch(in: trimmed),
            let number = Int(match.1)
        {
            return .locator(.paragraph(number))
        }
        if let match = try? /^claims?\s+(\d{1,3})$/.ignoresCase().wholeMatch(in: trimmed),
            let number = Int(match.1)
        {
            return .locator(.claim(number))
        }
        if PatentNumberParser.looksLikeNumber(trimmed),
            let key = PatentNumberParser.parse(trimmed)
        {
            return .number(key)
        }
        return .text(trimmed)
    }

    /// The patents a query lists, in library order.
    ///
    /// A locator lists everything, because it is not a filter: the reader is asking to go
    /// somewhere in the document they already have open, and narrowing the library under
    /// them while they do it would be answering a question they did not ask.
    static func matches(in library: [Patent], query: Query) -> [Patent] {
        switch query {
        case .all, .locator:
            return library
        case .number(let key):
            return library.filter {
                $0.key.country == key.country && $0.key.serial == key.serial
            }
        case .text(let text):
            let needle = fold(text)
            return library.filter { patent in
                if fold(patent.title).contains(needle) { return true }
                if let assignee = patent.assignee, fold(assignee).contains(needle) {
                    return true
                }
                if patent.inventors.contains(where: { fold($0).contains(needle) }) {
                    return true
                }
                return fold(patent.key.slug).contains(needle)
            }
        }
    }

    /// Whether the field should offer to fetch rather than saying nothing matched.
    ///
    /// A number typed into a patent app is a request for that patent, so an unmatched
    /// number is not an empty result — it is an action the reader has all but asked for.
    /// This is the one place the search field does something other than filter, and it is
    /// the difference between "No patents match" and a row that gets them the document.
    static func fetchSuggestion(for query: Query, in library: [Patent]) -> PatentKey? {
        guard case .number(let key) = query else { return nil }
        let present = library.contains {
            $0.key.country == key.country && $0.key.serial == key.serial
        }
        return present ? nil : key
    }

    /// Both sides of every comparison go through this: lowercased and
    /// diacritic-insensitive, with apostrophes dropped.
    ///
    /// Ported verbatim from `NavigatorSearch`. Assignee names are full of both — `Nestlé`,
    /// `L'Oréal`, `Bull S.A.` — so folding is what lets a reader type what is on their
    /// keyboard.
    private static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }
}

/// What the library has expanded: at most one patent, and at most one section inside it.
///
/// `NavigatorOutline`, and the polarity argument transfers without a word changed. A
/// patent runs to a few hundred rows and a library to a few dozen patents, so a set of
/// *collapsed* sections has the wrong default — empty means everything open, which is
/// what a first launch gets. Recording what is *open* instead, one of each, makes the
/// closed outline free.
///
/// Nothing here is persisted. The reading position implies the whole value, so at launch
/// the outline is whatever the restored `PatentKey` says.
///
/// The invariant, which is why both mutators write both fields: an open section belongs
/// to the open patent.
struct LibraryOutline: Equatable, Sendable {
    private(set) var patent: PatentKey?
    /// The index of the open section within `Patent.sections`, or `claimsSection` for the
    /// claims, which are not one of them.
    private(set) var section: Int?

    /// The claims are addressed as a section so the outline needs one field rather than
    /// two, and `-1` is chosen because no array index is negative — a section index and
    /// this can never collide.
    static let claimsSection = -1

    init(patent: PatentKey? = nil, section: Int? = nil) {
        self.patent = patent
        self.section = section
    }

    static func following(_ key: PatentKey) -> LibraryOutline {
        LibraryOutline(patent: key, section: nil)
    }

    func isOpen(patent key: PatentKey) -> Bool { patent == key }

    func isOpen(section index: Int, in key: PatentKey) -> Bool {
        patent == key && section == index
    }

    /// Closing a patent drops its section with it; opening another starts with its
    /// sections shut. That second half is deliberate: opening a patent should give the
    /// reader six section rows to choose between, not three hundred paragraph rows.
    mutating func toggle(patent key: PatentKey) {
        patent = isOpen(patent: key) ? nil : key
        section = nil
    }

    /// Opens the section's patent along with it, since a section cannot be open inside a
    /// closed patent. Closing the section leaves the patent open.
    mutating func toggle(section index: Int, in key: PatentKey) {
        section = isOpen(section: index, in: key) ? nil : index
        patent = key
    }
}
