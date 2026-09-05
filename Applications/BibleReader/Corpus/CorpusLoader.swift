// Copyright © 2026 Apple Inc.

import Foundation

/// Everything the reader knows how to read.
struct Bible: Sendable {
    let books: [Book]

    func book(_ id: String) -> Book? {
        books.first { $0.id == id }
    }

    func chapter(_ key: ChapterKey) -> Chapter? {
        book(key.bookID)?.chapter(key.chapter)
    }

    /// The books of one division, in canonical order.
    ///
    /// 1 and 2 Machabees are `.historical` but sit at canonical index 45 and 46,
    /// after the prophets, which is where this edition prints them and where Catholic
    /// Bibles put them. Sorting by `canonicalIndex` is what lists them last inside
    /// Historical without disturbing reading order.
    func books(in division: Division) -> [Book] {
        books.filter { $0.division == division }.sorted {
            $0.canonicalIndex < $1.canonicalIndex
        }
    }

    /// Every chapter in reading order, which is what `--show-prompt` walks.
    var chapterKeys: [ChapterKey] {
        books.flatMap { book in
            book.chapters.map { ChapterKey(bookID: book.id, chapter: $0.number) }
        }
    }

    var firstChapter: ChapterKey? { chapterKeys.first }

    /// Resolves a reference to the row index of its first verse, which is what the
    /// reader needs to select it.
    ///
    /// Returns `nil` for a verse this edition does not have, which is the whole point:
    /// `ReferenceCheck` uses exactly this to tell a real citation from an invented one.
    func rowIndex(of reference: ScriptureReference) -> Int? {
        guard let chapter = chapter(reference.chapterKey) else { return nil }
        guard let verse = reference.verse else {
            return chapter.rows.firstIndex { $0.isVerse }
        }
        return chapter.rows.firstIndex { $0.isVerse && $0.number == verse }
    }

    /// The text of a referenced verse, for quoting into the prompt and for
    /// `ReferenceCheck.quotedVerse`.
    func verseText(_ reference: ScriptureReference) -> String? {
        guard let index = rowIndex(of: reference),
            let chapter = chapter(reference.chapterKey)
        else { return nil }
        return chapter.rows[index].text
    }

    /// What to open on launch, given the last recorded position.
    ///
    /// A record is only a hint, and every way it can fail to describe *this* corpus
    /// falls back rather than being handed through: `ContentView.body` renders the
    /// loading spinner forever for a `chapterKey` the corpus cannot resolve, so a book
    /// that was removed or a chapter that vanished has to come back as `firstChapter`.
    /// A corpus whose text changed under a resolvable key keeps the chapter but drops
    /// the selection, since the indices it holds may now point at different rows.
    func opening(
        from record: ReadingProgress?
    ) -> (key: ChapterKey?, selection: VerseSelection?) {
        guard let record, let book = book(record.key.bookID),
            let chapter = chapter(record.key)
        else { return (firstChapter, nil) }

        guard book.source.textSHA256 == record.corpusStamp else { return (record.key, nil) }

        return (record.key, record.selection?.clamped(to: chapter.rows))
    }
}

enum CorpusLoader {
    /// Where `Books/` is.
    ///
    /// `Bundle.main` on both platforms, with no fork, because `Books/` is a *folder
    /// reference* rather than 73 loose files: it is copied whole to
    /// `$(UNLOCALIZED_RESOURCES_FOLDER_PATH)`, which is the `.app` root on iOS and
    /// `Contents/Resources` on macOS, and `Bundle.main.resourceURL` follows exactly the
    /// same rule, so the directory is found the same way on each.
    private static let resources = Bundle.main

    enum Failure: LocalizedError {
        case resourcesMissing
        case noBooks(URL)
        case decode(String, Error)

        var errorDescription: String? {
            switch self {
            case .resourcesMissing:
                // The only way this fires: `Books` dropped out of Copy Bundle
                // Resources, or was added back as a group rather than a folder
                // reference — in which case the JSON is flattened into the resource
                // directory and there is no `Books` to find. The project keeps it
                // nested by listing `BibleReader/Resources/Books` in the Applications
                // group's `explicitFolders`.
                "Could not find the Books resource directory. Check that Books is still "
                    + "a folder reference in the BibleReader target's Copy Bundle "
                    + "Resources phase, and that BibleReader/Resources/Books is still "
                    + "listed in the Applications group's explicitFolders."
            case .noBooks(let url):
                "No book JSON found in \(url.path). Regenerate it with "
                    + "`python3 tools/build_corpus.py --all --out Resources/Books` from "
                    + "Applications/BibleReader."
            case .decode(let name, let error):
                "\(name) could not be decoded: \(error)"
            }
        }
    }

    /// Loads every `*.json` in the bundled `Books` directory.
    ///
    /// Enumerating rather than naming files is why `Books` is copied as a folder
    /// reference. The result is sorted by `canonicalIndex` rather than by filename:
    /// ShakespeareReader could sort by filename because alphabetical order is as good
    /// as any for a shelf of plays, but a Bible has one correct order and it is not
    /// `1-corinthians, 1-esdras, 1-john`.
    static func load() throws -> Bible {
        guard let directory = resources.url(forResource: "Books", withExtension: nil)
        else {
            throw Failure.resourcesMissing
        }

        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        guard !files.isEmpty else { throw Failure.noBooks(directory) }

        let decoder = JSONDecoder()
        let books = try files.map { url in
            do {
                return try decoder.decode(Book.self, from: Data(contentsOf: url))
            } catch {
                throw Failure.decode(url.lastPathComponent, error)
            }
        }
        return Bible(books: books.sorted { $0.canonicalIndex < $1.canonicalIndex })
    }
}
