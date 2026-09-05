// Copyright © 2026 Apple Inc.

import Foundation

/// The alias index: every name a reader might type, mapped to a book.
///
/// Built from the corpus rather than checked in separately, so a book's aliases live
/// in one place — its own JSON — and adding one is a parser change rather than a
/// change in two files that can drift apart.
struct BookTable: Sendable {
    struct Resolution: Equatable, Sendable {
        var bookID: String
        var hint: String?
    }

    private let byName: [String: String]
    private let shortNames: [String: String]

    /// Names that resolve correctly and still need something said about them.
    ///
    /// Only two entries, and both earn their place by being the traps a reader falls
    /// into exactly once. `1 Kings` in this edition is 1 Samuel — which is *correct*
    /// for the Douay-Rheims and completely wrong against the reader's expectation, so
    /// the hint names the book they probably wanted and gives them a landmark in it.
    private static let ambiguous: [String: String] = [
        "1 kings":
            "In this edition 1 Kings is 1 Samuel. For Elias on Carmel see 3 Kings 18.",
        "2 kings":
            "In this edition 2 Kings is 2 Samuel. For Elias and the fiery chariot see "
            + "4 Kings 2.",
    ]

    init(_ bible: Bible) {
        var names: [String: String] = [:]
        var shorts: [String: String] = [:]
        for book in bible.books {
            shorts[book.id] = book.name
            for name in [book.name, book.title] + book.abbreviations {
                // First writer wins, so a book's own short name is never displaced by
                // a later book's alias, and the canonical iteration order decides the
                // few genuine collisions in favour of the earlier book.
                let folded = Self.fold(name)
                if names[folded] == nil { names[folded] = book.id }
            }
        }
        byName = names
        shortNames = shorts
    }

    func name(of bookID: String) -> String? { shortNames[bookID] }

    func resolve(_ name: String) -> Resolution? {
        let folded = Self.fold(name)
        if let id = byName[folded] {
            return Resolution(bookID: id, hint: Self.ambiguous[folded])
        }
        // `st. mark`, `saint john`. Twenty of the twenty-seven New Testament titles in
        // this edition begin "The … of St. X", so a reader who types the honorific is
        // reading it off the page. Retried rather than added as 20 more aliases,
        // because the rule is one line and the alias list is per-book data.
        for honorific in ["st ", "saint "] where folded.hasPrefix(honorific) {
            let bare = String(folded.dropFirst(honorific.count))
            if let id = byName[bare] {
                return Resolution(bookID: id, hint: Self.ambiguous[bare])
            }
        }
        return nil
    }

    /// Case- and diacritic-insensitive, apostrophes dropped, internal runs of space
    /// collapsed, and a trailing period tolerated.
    ///
    /// The apostrophe and diacritic folding is `NavigatorSearch.fold` verbatim, and it
    /// earns its keep here too: `Solomon’s Canticle of Canticles` is the title in the
    /// JSON. The additions are for typed input — `1  cor`, `Gen.`, `st. mark`.
    static func fold(_ text: String) -> String {
        let folded =
            text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return
            folded
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .joined(separator: " ")
    }
}
