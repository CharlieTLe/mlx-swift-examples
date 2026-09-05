// Copyright © 2026 Apple Inc.

import Foundation

/// Where the reader was when they last quit.
///
/// One position for the whole app rather than one per book: "where I left off" is a
/// single place, and clicking a book in the navigator still opens its first chapter.
struct ReadingProgress: Codable, Sendable, Equatable {
    let schemaVersion: Int
    var key: ChapterKey
    var selection: VerseSelection?
    /// `Book.source.textSHA256` for `key.bookID`.
    ///
    /// The mirror of `AnnotationCache`'s `passageDigest` gate: a stored selection is a
    /// pair of indices into `Chapter.rows`, so a corpus rebuilt with a different parse
    /// must not restore a highlight over different rows. On mismatch the chapter is
    /// kept and the selection dropped.
    var corpusStamp: String
}

/// `ReadingProgress`, in `UserDefaults`.
///
/// `UserDefaults` rather than JSON beside the annotation cache: the record is one small
/// value, and it belongs with the window frame and `readerFont` rather than with
/// generated model output a reader might reasonably want to delete.
///
/// **Not** `@AppStorage`. Nothing renders from the record: it is read once at launch
/// and written thereafter, so the observation `@AppStorage` provides buys nothing. It
/// would also force a `RawRepresentable where RawValue == String` bridge onto
/// `ReadingProgress`, and the stdlib's own `Codable` conformance for string-backed raw
/// values would then shadow the synthesized one and recurse. `Data` goes in directly.
enum ProgressStore {
    static let schemaVersion = 1

    private static let progressKey = "readingProgress"

    /// `nil` for anything unreadable, whether absent, corrupt, or written by a schema
    /// this build does not know, matching `AnnotationCache.read(url:)`. A position is a
    /// convenience, so a bad one is worth nothing more than starting at the beginning.
    static func progress() -> ReadingProgress? {
        guard let data = UserDefaults.standard.data(forKey: progressKey),
            let record = try? JSONDecoder().decode(ReadingProgress.self, from: data),
            record.schemaVersion == schemaVersion
        else { return nil }
        return record
    }

    static func save(_ record: ReadingProgress) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: progressKey)
    }
}
