// Copyright © 2026 Apple Inc.

import Foundation

/// Everything the reader has imported.
///
/// `Corpus` next door is a bundled constant; this is not. The library is built by the
/// reader one patent at a time, lives in `Application Support`, and changes while the
/// app is running — so where `CorpusLoader` was an `enum` with one `load()`, this is an
/// observable object that owns writes as well as reads.
///
/// **One JSON file per patent**, and the raw source beside it. Per file rather than one
/// library document so that importing writes one file, deleting removes one, and a
/// single corrupt patent does not take the library down with it; the raw source so that
/// bumping `GooglePatentsParser.version` is a re-parse rather than a re-fetch, which
/// matters both for the reader's time and for not asking somebody else's server for
/// bytes twice.
@MainActor
@Observable
final class LibraryStore {

    private(set) var patents: [Patent] = []
    /// Set when a read failed in a way the reader should see. A patent that fails to
    /// decode is skipped rather than fatal — one bad file must not empty the library —
    /// but it is named, because a patent silently missing from a list the reader built
    /// themselves is the worst possible failure here.
    private(set) var loadWarnings: [String] = []

    private let root: URL

    /// An unbundled build has no bundle identifier, so the directory is named explicitly
    /// rather than derived from one — `AnnotationCache`'s reasoning, and it puts the
    /// library, the index and the answer cache under one root a reader can delete.
    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PatentReader", isDirectory: true)
    }

    var libraryDirectory: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var indexDirectory: URL { root.appendingPathComponent("Index", isDirectory: true) }
    var answerDirectory: URL { root.appendingPathComponent("Answers", isDirectory: true) }

    private func documentURL(_ key: PatentKey) -> URL {
        libraryDirectory.appendingPathComponent("\(key.slug).json")
    }

    private func sourceURL(_ key: PatentKey) -> URL {
        libraryDirectory.appendingPathComponent("\(key.slug).source.html")
    }

    // MARK: - Reading

    func patent(_ key: PatentKey) -> Patent? {
        patents.first { $0.key == key }
    }

    /// Loads every patent in the library directory.
    ///
    /// Sorted by title so the list does not reshuffle between launches — `CorpusLoader`
    /// sorts by filename for the same reason, and here the filename is a number nobody
    /// browses by.
    func load() {
        loadWarnings = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: libraryDirectory, includingPropertiesForKeys: nil)) ?? []

        var loaded: [Patent] = []
        for url in files where url.pathExtension == "json" {
            do {
                loaded.append(try decoder.decode(Patent.self, from: Data(contentsOf: url)))
            } catch {
                // Named and skipped. A schema bump or a half-written file should cost
                // one patent, not the library — but silently, and the reader would think
                // they had never imported it.
                loadWarnings.append("\(url.lastPathComponent) could not be read: \(error)")
            }
        }
        patents = loaded.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: - Writing

    enum StoreError: LocalizedError {
        case alreadyPresent(PatentKey)

        var errorDescription: String? {
            switch self {
            case .alreadyPresent(let key):
                "\(key.display) is already in the library."
            }
        }
    }

    /// Writes a patent and its source bytes, and adds it to the list.
    ///
    /// `replacing: false` is the import path and refuses a duplicate rather than
    /// silently overwriting, because an import is usually a mistake at that point — the
    /// reader typed a number they already have — and because overwriting throws away an
    /// index. `replacing: true` is the re-parse path, which is a deliberate act.
    @discardableResult
    func store(_ patent: Patent, sourceHTML: String? = nil, replacing: Bool = false) throws
        -> Patent
    {
        if !replacing, patents.contains(where: { $0.key == patent.key }) {
            throw StoreError.alreadyPresent(patent.key)
        }

        try FileManager.default.createDirectory(
            at: libraryDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(patent).write(to: documentURL(patent.key), options: .atomic)

        if let sourceHTML {
            // Best-effort: the document is what matters and the source is a convenience
            // for re-parsing. A full disk should cost the convenience, not the import.
            try? Data(sourceHTML.utf8).write(to: sourceURL(patent.key), options: .atomic)
        }

        patents.removeAll { $0.key == patent.key }
        patents.append(patent)
        patents.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        writeNotice()
        return patent
    }

    /// Removes a patent, its source, and its index together.
    ///
    /// Together is the point. An index left behind for a deleted patent is entries that
    /// resolve to nothing — every one of them a `.nonexistent` citation waiting to
    /// happen — and it is invisible, because nothing lists index files.
    func remove(_ key: PatentKey) {
        let manager = FileManager.default
        try? manager.removeItem(at: documentURL(key))
        try? manager.removeItem(at: sourceURL(key))
        try? manager.removeItem(
            at: indexDirectory.appendingPathComponent("\(key.slug).json"))
        patents.removeAll { $0.key == key }
        writeNotice()
    }

    /// The stored source bytes, for a re-parse after a `parserVersion` bump.
    func storedSource(_ key: PatentKey) -> String? {
        try? String(contentsOf: sourceURL(key), encoding: .utf8)
    }

    // MARK: - Provenance

    /// `NOTICE.md` beside the library, rewritten on every change.
    ///
    /// The `Resources/Plays/NOTICE.md` idea, moved to a directory the reader owns. It
    /// exists because a folder of patent text with no statement of where it came from is
    /// exactly the thing somebody later has to reconstruct, and because the source here
    /// is an unofficial one — a fact that belongs in writing next to the files rather
    /// than only in a doc comment in this repo.
    private func writeNotice() {
        var lines = [
            "# Patent Reader library",
            "",
            "Everything in this directory was imported by Patent Reader on this Mac.",
            "One `<number>.json` per patent, with the bytes it was parsed from beside it",
            "as `<number>.source.html`, so a parser change can re-read them without",
            "asking the source for them again.",
            "",
            "## Provenance",
            "",
            "US patent text is a public record and is not subject to copyright. The page",
            "markup these were parsed from, and the OCR in older documents, are Google's.",
            "This app fetches one page per patent, on request, and does not crawl. Terms",
            "of service for programmatic access to patents.google.com have not been",
            "cleared by this project; read them before relying on this beyond personal",
            "use. `Ingest/PatentSource.swift` is the seam where another source goes.",
            "",
            "## Contents",
            "",
            "| Number | Title | Source | Retrieved | Parser | Numbering |",
            "|---|---|---|---|---|---|",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for patent in patents {
            lines.append(
                "| \(patent.key.display) | \(patent.title) | \(patent.source.kind.rawValue) "
                    + "| \(formatter.string(from: patent.source.retrieved)) "
                    + "| \(patent.source.parserVersion) | \(patent.numbering.rawValue) |")
        }
        lines.append("")

        try? FileManager.default.createDirectory(
            at: libraryDirectory, withIntermediateDirectories: true)
        try? Data(lines.joined(separator: "\n").utf8)
            .write(
                to: libraryDirectory.appendingPathComponent("NOTICE.md"), options: .atomic)
    }
}
