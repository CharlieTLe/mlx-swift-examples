// Copyright © 2026 Apple Inc.

import Foundation

/// The navigator's find field, as a function of the corpus and a query.
///
/// A pure function rather than something the view does inline, so `SelfTest` can assert
/// on the matching rules without a view — and so the view has a single render path.
///
/// **Two kinds of answer, not one**, which is the difference from ShakespeareReader.
/// `jn 3:16` is not a search: it is an address, and returning "the Gospel of John, one
/// match" for it would make the reader do a second step the query already specified. So
/// the result is a sum type, and the view either jumps or lists.
enum NavigatorSearch {

    enum Result: Equatable {
        /// The query parsed as a reference. The view offers it as a jump.
        case reference(ResolvedReference)
        /// The query is a name, or is nothing at all. The view lists.
        case books([BookMatch])
    }

    /// A book worth showing.
    ///
    /// There is no per-chapter match, and that is not an omission: a chapter has nothing
    /// to match *on*. ShakespeareReader could search scene settings because a scene has a
    /// setting; a chapter has a number and Challoner's argument, and searching arguments
    /// would be a full-text search over 1,296 paragraphs pretending to be navigation.
    /// **Full-text search is out of scope for v1** — it needs an index, not a substring
    /// scan over 5 MB, and the README says so.
    struct BookMatch: Identifiable, Equatable {
        let book: Book
        /// What matched, when it was not the book's own name: the alias the reader
        /// typed. Rendered as a secondary note, so `sirach` explains why Ecclesiasticus
        /// came back.
        let via: String?

        var id: String { book.id }

        /// By identity rather than by value. `Book` carries 1,334 chapters and 35,805
        /// verses; comparing two of them field by field to decide whether a navigator row
        /// changed would walk the whole corpus, and the id already answers the question.
        static func == (lhs: BookMatch, rhs: BookMatch) -> Bool {
            lhs.book.id == rhs.book.id && lhs.via == rhs.via
        }
    }

    /// One rule, so the view never branches more than twice:
    ///
    /// - A query that parses as a reference to a chapter this edition has is
    ///   `.reference`, hint and all.
    /// - An empty query is every book, which the outline alone decides the visibility of.
    /// - Otherwise, every book whose name, title or alias contains the query, in
    ///   canonical order. `[]` is the view's cue for its "No books match" placeholder.
    static func matches(in bible: Bible, table: BookTable, query: String) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = fold(trimmed)
        guard !needle.isEmpty else {
            return .books(bible.books.map { BookMatch(book: $0, via: nil) })
        }

        if let resolved = ReferenceParser.parse(trimmed, table: table, bible: bible) {
            return .reference(resolved)
        }

        return .books(
            bible.books.compactMap { book in
                if fold(book.name).contains(needle) || fold(book.title).contains(needle) {
                    return BookMatch(book: book, via: nil)
                }
                // An alias match says so. "Sirach" finding Ecclesiasticus is right and
                // also surprising, and the row that does not explain itself is the one
                // the reader mistrusts.
                guard let alias = book.abbreviations.first(where: { fold($0).contains(needle) })
                else { return nil }
                return BookMatch(book: book, via: alias)
            })
    }

    /// Both sides of every comparison go through this: lowercased and
    /// diacritic-insensitive, with apostrophes dropped.
    ///
    /// Kept verbatim from ShakespeareReader, and it earns its keep here too: titles are
    /// mixed case in the JSON, `Solomon’s Canticle of Canticles` carries a curly
    /// apostrophe, and dropping `'` and `’` alike is what lets a reader type
    /// `solomons canticle` without guessing which quote mark the transcription used.
    ///
    /// Deliberately *not* `BookTable.fold`, which additionally collapses periods so that
    /// `Gen.` resolves. That is right for an address and wrong for a filter, where a
    /// reader typing `st.` should still narrow.
    static func fold(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil
            )
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }
}
