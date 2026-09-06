// Copyright © 2026 Apple Inc.

import Foundation

/// Importing patents and keeping their indexes current.
///
/// The one place that owns the order of operations, and the order is the interesting
/// part: **a patent becomes readable before it becomes searchable.** Parsing takes
/// milliseconds and indexing takes tens of seconds, so the document is written and
/// listed first and the embedding runs behind it. A reader who has just typed a number
/// gets a patent to read immediately and a progress figure for the part that is slow,
/// rather than a spinner over an empty library.
@MainActor
@Observable
final class LibraryService {

    /// Where a patent is, between arriving and being searchable.
    enum IndexState: Equatable, Sendable {
        case notIndexed
        /// `done` of `total` chunks embedded.
        case indexing(done: Int, total: Int)
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notIndexed: "not indexed"
            case .indexing(let done, let total): "indexing \(done)/\(total)"
            case .ready: "ready"
            case .failed: "index failed"
            }
        }
    }

    let store: LibraryStore
    let index: PatentIndex
    let embedder: EmbeddingService

    private(set) var indexStates: [PatentKey: IndexState] = [:]
    /// Set while a fetch or a file import is in flight, so the library's `+` can show it
    /// and refuse a second one.
    private(set) var importing: String?
    private(set) var importError: String?

    private var indexTask: Task<Void, Never>?
    /// Patents waiting to be indexed. Serialized rather than run in parallel because
    /// they contend for one GPU, and because two imports at once would each report
    /// progress against a machine doing half the work.
    private var queue: [PatentKey] = []

    private let source: any PatentSource

    init(
        store: LibraryStore? = nil, embedder: EmbeddingService? = nil,
        source: any PatentSource = GooglePatentsSource()
    ) {
        let store = store ?? LibraryStore()
        self.store = store
        self.index = PatentIndex(directory: store.indexDirectory)
        self.embedder = embedder ?? EmbeddingService()
        self.source = source
    }

    var patents: [Patent] { store.patents }

    func state(of key: PatentKey) -> IndexState {
        indexStates[key] ?? (index.indexed.contains(key) ? .ready : .notIndexed)
    }

    // MARK: - Startup

    func load() {
        store.load()
        index.load(library: store.patents, modelID: embedder.modelID)
        for patent in store.patents where !index.indexed.contains(patent.key) {
            indexStates[patent.key] = .notIndexed
        }
    }

    // MARK: - Import

    func fetch(_ key: PatentKey) async {
        guard importing == nil else { return }
        importing = key.display
        importError = nil
        defer { importing = nil }

        do {
            // The HTML is kept alongside the document when the source can hand it over,
            // so a `parserVersion` bump is a re-parse rather than another request to
            // somebody else's server. A source that cannot — a future API — just returns
            // the patent, and the re-parse path is unavailable for it, which is correct:
            // there would be nothing to re-parse.
            let patent: Patent
            var html: String?
            if let google = source as? GooglePatentsSource {
                let fetched = try await google.fetchSource(key)
                html = fetched.html
                patent = try GooglePatentsParser.parse(
                    fetched.html, requested: key, url: fetched.url.absoluteString)
            } else {
                patent = try await source.fetch(key)
            }
            try store.store(patent, sourceHTML: html)
            enqueue(patent.key)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// A PDF or a plain-text file the reader dropped or picked.
    ///
    /// Security-scoped access is requested unconditionally rather than under an `#if`:
    /// on macOS with the sandbox off it is a no-op that returns `false`, and on iOS a
    /// document-picker URL genuinely needs it. Branching would be a platform check
    /// standing in for a question about the URL.
    func importFile(at url: URL) async {
        guard importing == nil else { return }
        importing = url.lastPathComponent
        importError = nil
        defer { importing = nil }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let patent = try PatentPDFImporter.load(url)
            try store.store(patent)
            enqueue(patent.key)
        } catch {
            importError = error.localizedDescription
        }
    }

    func remove(_ key: PatentKey) {
        queue.removeAll { $0 == key }
        index.remove(key)
        store.remove(key)
        indexStates[key] = nil
    }

    // MARK: - Indexing

    /// Queues a patent and starts the worker if it is not already running.
    func enqueue(_ key: PatentKey) {
        guard !queue.contains(key) else { return }
        queue.append(key)
        indexStates[key] = .indexing(done: 0, total: 0)
        startWorker()
    }

    /// Indexes every patent that has no current index. The library view's "index all"
    /// and what a launch offers after a `parserVersion` bump.
    func indexAll() {
        for patent in store.patents where !index.indexed.contains(patent.key) {
            enqueue(patent.key)
        }
    }

    private func startWorker() {
        guard indexTask == nil else { return }
        indexTask = Task { @MainActor in
            defer { indexTask = nil }
            while !queue.isEmpty {
                let key = queue.removeFirst()
                await build(key)
            }
            // On iOS the embedder is dropped once the queue drains rather than after the
            // idle timeout, because an import is the one operation that is definitely
            // finished when it is finished — where a question might be followed by
            // another.
            embedder.evict()
        }
    }

    /// Waits for the queue to drain.
    ///
    /// For the terminal commands only. The app never waits: a patent is readable the
    /// moment it is parsed and indexing runs behind it, which is the whole sequencing
    /// decision this type exists to make. A command-line `--fetch` that returned before
    /// its patent was searchable would be a different kind of lie — there is no UI there
    /// to show progress in, so "done" has to mean done.
    func waitForIndexing() async {
        while let task = indexTask {
            await task.value
        }
    }

    private func build(_ key: PatentKey) async {
        guard let patent = store.patent(key) else { return }
        let chunks = Chunker.chunks(for: patent)
        guard !chunks.isEmpty else {
            indexStates[key] = .failed("There is nothing in this patent to index.")
            return
        }
        indexStates[key] = .indexing(done: 0, total: chunks.count)

        do {
            let vectors = try await embedder.embed(
                documents: chunks.map(\.embeddingText),
                progress: { done, total in
                    self.indexStates[key] = .indexing(done: done, total: total)
                })
            guard vectors.count == chunks.count, let dimension = vectors.first?.count,
                dimension > 0
            else {
                indexStates[key] = .failed("The embedder returned nothing usable.")
                return
            }

            let file = PatentIndexFile(
                schemaVersion: PatentIndexFile.schemaVersion,
                patentSlug: key.slug,
                patentDigest: patent.source.contentSHA256,
                parserVersion: patent.source.parserVersion,
                chunkerVersion: Chunker.version,
                modelID: embedder.modelID,
                documentPrefix: EmbeddingService.documentPrefix,
                dimension: dimension,
                builtAt: Date(),
                entries: zip(chunks, vectors).map(PatentIndexFile.Entry.init))
            try index.store(file, for: key)
            // Reloaded rather than appended, so the BM25 lexicon is rebuilt over the
            // whole library — inverse document frequency is a corpus property and a
            // merged index would rank against a library that no longer exists.
            index.load(library: store.patents, modelID: embedder.modelID)
            indexStates[key] = .ready
        } catch is CancellationError {
            indexStates[key] = .notIndexed
        } catch {
            indexStates[key] = .failed(error.localizedDescription)
        }
    }
}
