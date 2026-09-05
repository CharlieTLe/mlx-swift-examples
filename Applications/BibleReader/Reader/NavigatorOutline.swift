// Copyright © 2026 Apple Inc.

/// What the navigator has open: at most one division, and at most one book inside it.
///
/// An accordion rather than a set of collapsed ids, and the polarity is the point. 73
/// books across 1,334 chapters is far more than fits a 210pt column, so a set of
/// *collapsed* books has the wrong default — empty means everything open, which is
/// exactly what a first launch gets. Recording what is *open* instead, one of each,
/// makes the closed outline free: a cold start is nine division rows.
///
/// Two levels rather than ShakespeareReader's play-and-act, and one level shallower
/// than the corpus is deep. Chapters are **not** the third accordion level: a book
/// opens onto a grid of numbered buttons, because Psalms would otherwise be 150 rows.
/// See `NavigatorView.chapterGrid`.
///
/// Nothing here is persisted. The reading position implies the whole value, so at launch
/// the outline is whatever the restored `ChapterKey` says (see `ContentView`'s
/// `onChange(of: chapterKey)`), and a reader who collapsed the current book before
/// quitting comes back with it open — one tap to redo, and arguably the right thing to
/// forget.
///
/// The invariant, which is why both mutators write both fields: an open book belongs to
/// the open division. There is no state where `book` names a book of a closed one.
struct NavigatorOutline: Equatable, Sendable {
    private(set) var division: Division?
    /// `Book.id` within `division`.
    private(set) var book: String?

    init(division: Division? = nil, book: String? = nil) {
        self.division = division
        self.book = book
    }

    /// The outline the reading position implies: the division and book of the chapter
    /// being read, and nothing else.
    static func following(_ key: ChapterKey, in bible: Bible) -> NavigatorOutline {
        guard let book = bible.book(key.bookID) else { return NavigatorOutline() }
        return NavigatorOutline(division: book.division, book: book.id)
    }

    func isOpen(division value: Division) -> Bool { division == value }

    func isOpen(book id: String, in value: Division) -> Bool {
        division == value && book == id
    }

    /// Closing a division drops its book with it; opening another starts with its books
    /// shut. That second half is deliberate: opening the Prophets should give the reader
    /// eighteen book rows to choose between, not a chapter grid.
    mutating func toggle(division value: Division) {
        division = isOpen(division: value) ? nil : value
        book = nil
    }

    /// Opens the book's division along with it, since a book cannot be open inside a
    /// closed division. Closing the book leaves the division open.
    mutating func toggle(book id: String, in value: Division) {
        book = isOpen(book: id, in: value) ? nil : id
        division = value
    }
}
