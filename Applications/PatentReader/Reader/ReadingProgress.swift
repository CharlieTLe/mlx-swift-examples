// Copyright © 2026 Apple Inc.

import Foundation

/// Where the reader was when they last quit.
///
/// One position for the whole app rather than one per patent: "where I left off" is a
/// single place, and opening a patent from the library still starts at its front page.
struct ReadingProgress: Codable, Sendable, Equatable {
    let schemaVersion: Int
    var patent: PatentKey

    /// The passage the reader was last sent to, or `nil`.
    ///
    /// **A `CitationTarget` and deliberately not a page number**, even though what is being
    /// restored is a scroll position in a PDF. A paragraph number survives a re-downloaded
    /// PDF and a page number does not: the office reissues corrected publications, and
    /// `patentimages` is not this app's storage. That is the argument `PatentPDFService.pages`
    /// already makes about *not* persisting the page, and this inherits it rather than
    /// overturning it — the position that is worth keeping is the one addressed the way a
    /// citation is.
    var focus: CitationTarget?

    /// `Patent.source.contentSHA256` for `patent`.
    ///
    /// The mirror of `AnswerCache`'s digest gate, and it keeps its job for a better reason
    /// than the one it had. It used to guard a pair of *row indices*, which a re-import
    /// obviously invalidates. A paragraph number looks stabler and is not: under
    /// `Numbering.synthesized` the numbers are the parser's own count from 1, so a re-parse
    /// of a changed source can renumber every paragraph in the document. On mismatch the
    /// patent is kept and the position dropped.
    var stamp: String
}

/// `ReadingProgress`, in `UserDefaults`.
///
/// `UserDefaults` rather than JSON beside the library: the record is one small value, and
/// it belongs with the window frame and `readerFont` rather than with a corpus a reader
/// might reasonably want to delete on its own.
///
/// **Not** `@AppStorage`. Nothing renders from the record — it is read once at launch and
/// written thereafter — so the observation `@AppStorage` provides buys nothing, and it
/// would force a `RawRepresentable where RawValue == String` bridge onto
/// `ReadingProgress` whose synthesized `Codable` would then shadow the stdlib's and
/// recurse. `Data` goes in directly.
enum ProgressStore {
    /// 2: `selection`, a pair of row indices into the deleted text reader, became `focus`,
    /// a `CitationTarget`.
    ///
    /// **No migration**, and none is wanted. `progress()` already returns `nil` for a
    /// version it does not know, and what is thrown away is one restored scroll position:
    /// the first launch after the upgrade opens the same patent at the top instead of where
    /// the reader was. Writing a migration for that would be more code than the thing is
    /// worth, and code that runs once.
    static let schemaVersion = 2

    private static let progressKey = "readingProgress"

    /// `nil` for anything unreadable, whether absent, corrupt, or written by a schema
    /// this build does not know. A position is a convenience, so a bad one is worth
    /// nothing more than starting at the top.
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

    /// What to open on launch, given the last recorded position.
    ///
    /// A record is only a hint, and every way it can fail to describe *this* library
    /// falls back rather than being handed through: a patent that was deleted comes back
    /// as the first one in the library, a patent whose source changed keeps the document
    /// and drops the position, and a passage the patent no longer has is dropped too — a
    /// re-parse can renumber, and restoring `[0042]` onto whatever is now the forty-second
    /// paragraph is the failure the stamp exists to prevent.
    static func opening(from record: ReadingProgress?, in library: [Patent])
        -> (patent: PatentKey?, focus: CitationTarget?)
    {
        guard let record, let patent = library.first(where: { $0.key == record.patent })
        else { return (library.first?.key, nil) }

        guard patent.source.contentSHA256 == record.stamp else {
            return (record.patent, nil)
        }
        guard let focus = record.focus,
            CitationCheck.exists(focus, in: [patent.key: patent])
        else { return (record.patent, nil) }
        return (record.patent, focus)
    }
}

/// Where the reader has been, so a citation jump can be undone.
///
/// A citation chip can move the reader to another paragraph, and across patents — which
/// is the whole feature, and also the one interaction in the app that can lose somebody's
/// place. ⌘[ is the way back.
///
/// A plain stack rather than anything cleverer, and capped, because the only operations
/// are push, pop and clear. The cap exists so that a reader who clicks forty chips does
/// not accumulate forty entries they would have to press ⌘[ forty times to unwind; thirty
/// two is far more than anybody unwinds and small enough to be free.
struct NavigationHistory: Equatable, Sendable {
    /// One place in the library: a document, and which passage in it.
    ///
    /// A `CitationTarget` and not a page, for `ReadingProgress.focus`'s reason — and one
    /// this adds: the back stack outlives a re-download of the PDF, and a page number would
    /// send ⌘[ to a page that is no longer the one the reader left.
    struct Position: Equatable, Sendable {
        var patent: PatentKey
        var target: CitationTarget?
    }

    private(set) var back: [Position] = []
    private(set) var forward: [Position] = []

    private static let limit = 32

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records where the reader is, before moving them somewhere else.
    ///
    /// Pushing clears the forward stack, which is the standard rule and the right one: a
    /// new jump from the middle of an undone history makes the undone part unreachable
    /// by any route the reader could describe.
    mutating func push(_ position: Position) {
        back.append(position)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// Pops the back stack, given where the reader is now so it can be pushed forward.
    mutating func goBack(from current: Position) -> Position? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        return previous
    }

    mutating func goForward(from current: Position) -> Position? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        return next
    }

    /// Drops every entry naming a patent that is no longer in the library.
    ///
    /// Called after a delete. Without it ⌘[ eventually lands on a document that does not
    /// exist, and the reader is left looking at an empty pane with no way to explain it.
    mutating func prune(to library: Set<PatentKey>) {
        back.removeAll { !library.contains($0.patent) }
        forward.removeAll { !library.contains($0.patent) }
    }
}
