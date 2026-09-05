// Copyright © 2026 Apple Inc.

import Foundation

/// One cached annotation.
struct CachedPassage: Codable, Sendable {
    let schemaVersion: Int
    let promptVersion: Int
    let modelID: String
    /// SHA-256 of the selected verse text.
    let passageDigest: String
    /// The model's raw output, markers and all.
    ///
    /// Stored unparsed on purpose. `Annotation.parseSections` is pure and cheap, so
    /// splitting on read costs nothing, and keeping the raw text means a cached
    /// annotation rehydrates byte-identical to what the model actually said — including
    /// a malformed one, which is exactly the case worth being able to look at later.
    let commentary: String
    /// The model's literal numbered list...
    let followUpsRaw: String
    /// ...and the parsed form. Both, so a rehydrated history is byte-identical to what
    /// the model actually said.
    let followUps: [String]
    let generatedAt: Date
    let promptTokenCount: Int
    let tokensPerSecond: Double
}

/// JSON on disk, behind an actor so the file IO stays off the main actor.
///
/// **No synopsis cache**, which is the one structural difference from
/// ShakespeareReader's. There a per-scene synopsis had to be *generated* and cached
/// because nothing in the corpus summarized a scene. Here Challoner already did it:
/// 1,296 of the 1,334 chapters carry an argument he wrote, and `Chapter.argument` is
/// read straight out of the JSON. So the whole prewarm path — the background task, the
/// partial-synopsis state, the `.summarizingScene` phase and this cache's second half —
/// is simply gone, and what replaces it is both free and authored.
actor AnnotationCache {
    static let schemaVersion = 1

    private let root: URL
    private let modelID: String

    /// An unbundled SwiftPM executable has no bundle identifier, so the directory is
    /// named explicitly rather than derived from one.
    init(modelID: String) {
        self.modelID = modelID
        root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BibleReader", isDirectory: true)
    }

    var directory: URL { root }

    /// A hit requires `schemaVersion`, `promptVersion`, `modelID` **and**
    /// `passageDigest` to match. The digest is what stops a re-parsed corpus with
    /// shifted row indices from serving an annotation of different verses.
    func passage(for key: PassageKey, digest: String) -> CachedPassage? {
        guard let entry: CachedPassage = read(url: url(for: key)) else { return nil }
        guard entry.schemaVersion == Self.schemaVersion,
            entry.promptVersion == Prompts.version,
            entry.modelID == modelID,
            entry.passageDigest == digest
        else { return nil }
        return entry
    }

    func store(_ entry: CachedPassage, for key: PassageKey) {
        write(entry, to: url(for: key))
    }

    // MARK: - Paths and IO

    private func url(for key: PassageKey) -> URL {
        root.appendingPathComponent("passages", isDirectory: true)
            .appendingPathComponent("\(key.slug).json")
    }

    private func read<T: Decodable>(url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// Cache writes are best-effort. A full disk should not take down a reader.
    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            print("cache write failed for \(url.lastPathComponent): \(error)")
        }
    }
}
