// Copyright © 2026 Apple Inc.

import Foundation

/// One cached answer.
struct CachedAnswer: Codable, Sendable {
    let schemaVersion: Int
    let promptVersion: Int
    let modelID: String
    /// SHA-256 of the question and the retrieved passages. Both halves matter: the same
    /// question over a different retrieved set is a different answer, and serving the
    /// old one would attach its citations to passages the model was not shown — which is
    /// exactly the `.unretrieved` failure this app exists to make visible, manufactured
    /// by the cache.
    let contextDigest: String
    let question: String
    let answer: String
    /// The model's literal numbered list...
    let followUpsRaw: String
    /// ...and the parsed form. Both, so a rehydrated history is byte-identical to what
    /// the model actually said.
    let followUps: [String]
    let generatedAt: Date
    let promptTokenCount: Int
}

/// JSON on disk, behind an actor so the file IO stays off the main actor.
///
/// `AnnotationCache` next door keys its files on a passage, which is a place in a play
/// and so a short slug. A question is not a place, so these are keyed on the digest
/// itself — the filename is the hash. That loses the ability to look at the directory
/// and see what is cached, which is why `question` is stored inside the entry.
actor AnswerCache {
    static let schemaVersion = 1

    private let root: URL
    private let modelID: String

    init(modelID: String, root: URL? = nil) {
        self.modelID = modelID
        self.root =
            (root
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PatentReader", isDirectory: true))
            .appendingPathComponent("Answers", isDirectory: true)
    }

    /// A hit requires `schemaVersion`, `promptVersion`, `modelID` **and** the context
    /// digest to match. The digest is checked twice over — it is the filename and it is
    /// in the entry — so a hash collision or a hand-copied file cannot serve an answer
    /// about different passages.
    func answer(for digest: String) -> CachedAnswer? {
        guard let entry: CachedAnswer = read(url: url(for: digest)) else { return nil }
        guard entry.schemaVersion == Self.schemaVersion,
            entry.promptVersion == Prompts.version,
            entry.modelID == modelID,
            entry.contextDigest == digest
        else { return nil }
        return entry
    }

    func store(_ entry: CachedAnswer) {
        write(entry, to: url(for: entry.contextDigest))
    }

    private func url(for digest: String) -> URL {
        root.appendingPathComponent("\(digest.prefix(32)).json")
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
