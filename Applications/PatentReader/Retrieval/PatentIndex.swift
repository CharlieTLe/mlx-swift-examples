// Copyright © 2026 Apple Inc.

import Foundation

/// One patent's embeddings, on disk.
///
/// **One file per patent**, for the same three reasons the library documents are one
/// file per patent: importing writes one file, deleting removes one, and a corrupt index
/// costs one patent's retrieval rather than the library's. Incremental by construction —
/// importing a patent indexes only that patent.
///
/// A ~300-paragraph patent is roughly 350 chunks after windowing and claims, and 350 ×
/// 768 float32 is about 1 MB as raw bytes. It is stored as base64 rather than as a JSON
/// array of numbers, which is the one place this file departs from
/// `Tools/embedder-tool`'s `IndexEntry`: an array of 768 floats is ~9 KB of text against
/// 4 KB of base64, so a fifty-patent library would be 135 MB of JSON to parse at launch
/// instead of 55 MB of base64 to decode. The vectors are not something a human reads, so
/// nothing is lost by making them opaque; everything a human *would* read — the target,
/// the text, the model id — stays plain.
struct PatentIndexFile: Codable, Sendable {
    let schemaVersion: Int
    let patentSlug: String
    /// SHA-256 of the source bytes the patent was parsed from. The mirror of
    /// `AnnotationCache`'s `passageDigest` gate: a re-imported patent whose text changed
    /// must not be searched through vectors built from the old text.
    let patentDigest: String
    let parserVersion: Int
    let chunkerVersion: Int
    let modelID: String
    /// The prefix the documents were embedded with. Recorded because getting it wrong is
    /// silent — see `EmbeddingService` — and because a fix that changed it on one side
    /// only would be worse than the bug.
    let documentPrefix: String
    let dimension: Int
    let builtAt: Date
    let entries: [Entry]

    struct Entry: Codable, Sendable {
        let target: CitationTarget
        let window: Int
        let text: String
        let embeddingText: String
        /// Little-endian float32, base64. Normalized at write, so a search is a dot
        /// product rather than a cosine — `SearchCommand` in the embedder tool takes the
        /// same shortcut.
        let vector: String
    }

    static let schemaVersion = 1
}

extension PatentIndexFile.Entry {
    init(chunk: Chunk, vector: [Float]) {
        self.init(
            target: chunk.target, window: chunk.window, text: chunk.text,
            embeddingText: chunk.embeddingText, vector: Self.encode(vector))
    }

    var floats: [Float] {
        guard let data = Data(base64Encoded: vector) else { return [] }
        return data.withUnsafeBytes { raw in
            let count = raw.count / MemoryLayout<Float>.size
            var out = [Float](repeating: 0, count: count)
            for index in 0 ..< count {
                out[index] = Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(
                            fromByteOffset: index * 4, as: UInt32.self)))
            }
            return out
        }
    }

    static func encode(_ vector: [Float]) -> String {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}

/// A chunk with its vector, in memory, ready to search.
struct IndexedChunk: Sendable {
    let target: CitationTarget
    let window: Int
    let text: String
    let embeddingText: String
    let vector: [Float]

    var chunk: Chunk {
        Chunk(target: target, window: window, text: text, embeddingText: embeddingText)
    }
}

/// The whole library's index, loaded and searched.
///
/// A flat array and a linear scan, deliberately. Fifty patents at 350 chunks each is
/// 17,500 vectors; a `vDSP` dot product over that is single-digit milliseconds, which is
/// three orders of magnitude below the model's time to first token. An approximate index
/// would add a dependency, a build step and a recall question in exchange for a saving
/// nobody could perceive.
@MainActor
@Observable
final class PatentIndex {

    private(set) var chunks: [IndexedChunk] = []
    private(set) var lexical = LexicalIndex(chunks: [])
    /// Which patents have a usable index, so the library row can say so and a question
    /// can name what it could not search.
    private(set) var indexed: Set<PatentKey> = []

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private func url(for key: PatentKey) -> URL {
        directory.appendingPathComponent("\(key.slug).json")
    }

    // MARK: - Loading

    /// Loads the index for every patent in `library`, dropping anything stale.
    ///
    /// Stale is any of: a different schema, a different parser, a different chunker, a
    /// different embedding model, a different document prefix, or a patent whose source
    /// digest has changed. All six are recorded per file rather than globally so that a
    /// bump costs a reindex of the affected patents and not of the library.
    func load(library: [Patent], modelID: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [IndexedChunk] = []
        var ready: Set<PatentKey> = []

        for patent in library {
            guard let data = try? Data(contentsOf: url(for: patent.key)),
                let file = try? decoder.decode(PatentIndexFile.self, from: data),
                isCurrent(file, for: patent, modelID: modelID)
            else { continue }

            for entry in file.entries {
                let vector = entry.floats
                guard vector.count == file.dimension else { continue }
                loaded.append(
                    IndexedChunk(
                        target: entry.target, window: entry.window, text: entry.text,
                        embeddingText: entry.embeddingText, vector: vector))
            }
            ready.insert(patent.key)
        }

        chunks = loaded
        indexed = ready
        // Rebuilt over the whole library rather than merged per patent, because BM25's
        // inverse document frequency is a property of the corpus: a term's weight
        // changes when a patent is added, and a stale lexicon would rank against a
        // library that no longer exists.
        lexical = LexicalIndex(chunks: loaded.map(\.chunk))
    }

    private func isCurrent(
        _ file: PatentIndexFile, for patent: Patent, modelID: String
    ) -> Bool {
        file.schemaVersion == PatentIndexFile.schemaVersion
            && file.patentDigest == patent.source.contentSHA256
            && file.parserVersion == patent.source.parserVersion
            && file.chunkerVersion == Chunker.version
            && file.modelID == modelID
            && file.documentPrefix == EmbeddingService.documentPrefix
    }

    // MARK: - Writing

    func store(_ file: PatentIndexFile, for key: PatentKey) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: url(for: key), options: .atomic)
    }

    func remove(_ key: PatentKey) {
        try? FileManager.default.removeItem(at: url(for: key))
        chunks.removeAll { $0.target.patent == key }
        indexed.remove(key)
        lexical = LexicalIndex(chunks: chunks.map(\.chunk))
    }
}
