// Copyright © 2026 Apple Inc.

import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Embeds text with nomic-embed-text-v1.5, and manages the fact that it is the *second*
/// model this app keeps resident.
///
/// ## The task prefixes, which are a real bug not to inherit
///
/// nomic-embed-text-v1.5 was trained with mandatory task prefixes — `search_document: `
/// on everything indexed and `search_query: ` on everything searched — and it is not a
/// convention, it is part of the input the model was fit to. Omitting both measurably
/// degrades retrieval; omitting one and not the other is worse than omitting both, since
/// it puts queries and documents in different regions of the space.
///
/// `Tools/embedder-tool` applies neither: grepping it for `search_query`, `search_document`,
/// `clustering` and `classification` returns nothing, while `EmbedderTool` defaults to
/// `EmbedderRegistry.nomic_text_v1_5`. That is a retrieval-quality defect in that tool
/// and worth its own small change there; this app must not copy it. The prefixes here
/// are `static let`s so they can be recorded in the index and compared on load —
/// changing one silently would be exactly as damaging as omitting it.
///
/// ## Loading, and why it is not simply held
///
/// See `residencyPolicy`.
@MainActor
@Observable
final class EmbeddingService {

    /// Prepended to everything indexed.
    ///
    /// `nonisolated` so the index file's staleness check and `SelfTest` can read it
    /// without hopping to the main actor. These are compile-time constants; the isolation
    /// this class needs is about the container, not about them.
    nonisolated static let documentPrefix = "search_document: "
    /// Prepended to every query.
    nonisolated static let queryPrefix = "search_query: "

    /// nomic's native training length. Going past it costs quadratically in attention and
    /// buys little, and `Chunker.windowWords` is set so that nothing reaches it.
    ///
    /// Truncation is applied to the *token* array rather than to the string, because a
    /// word count is not a token count and patentese tokenizes badly — chemical names and
    /// reference numerals split more than prose.
    nonisolated static let maximumTokens = 512

    /// How many texts go through one forward pass.
    ///
    /// The batch is padded to its longest member, so a batch of sixteen containing one
    /// long paragraph pays for sixteen long paragraphs. `embed(_:)` sorts by length
    /// before batching for exactly that reason, which on a real patent takes the padding
    /// waste from roughly half to nearly nothing.
    nonisolated static let batchSize = 16

    enum LoadState: Equatable {
        case idle
        case loading(Double?)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    let modelID: String

    private var container: EmbedderModelContainer?
    private var pooling: Pooling.Strategy = .mean
    /// Fires after a period of not being used, on iOS only. See `residencyPolicy`.
    private var evictionTask: Task<Void, Never>?

    init(modelID: String = EmbedderRegistry.nomic_text_v1_5.name) {
        self.modelID = modelID
    }

    var isReady: Bool { loadState == .ready }

    /// **The policy, and the asymmetry is deliberate.**
    ///
    /// nomic-embed-text-v1.5 is ~550 MB of weights next to Qwen3-4B-4bit's ~2.2 GB, so
    /// roughly 2.8 GB resident with both. On a Mac that is nothing against the 48 GB
    /// ceiling `AnswerService.tuneMemory` sets, and evicting would buy a reload and
    /// nothing else — so on macOS it loads lazily and stays.
    ///
    /// On iOS the ceiling is `min(6 GB, physical / 2)` and it is *shared*. On an 8 GB
    /// phone that is 4 GB against a measured 3.31 GB peak for the 4B model plus the
    /// embedder, which leaves the buffer pool no room to breathe; on a 6 GB device the
    /// ceiling is 3 GB and the pair does not fit at all. So on iOS the embedder is a
    /// transient: it loads for an import or a question and is dropped afterwards.
    ///
    /// Dropped *after a delay*, not immediately, and that is the one piece of tuning
    /// here. A query embeds a single short string — one forward pass, milliseconds —
    /// and loading 550 MB of weights to do it is absurd if the reader is about to ask a
    /// second question. Sixty seconds of idle keeps a conversation on one load and gives
    /// the memory back before the reader has finished reading the answer.
    ///
    /// **What this arithmetic is and is not.** It is measured weights and a measured
    /// peak for the LLM alone, added up. It is not a measurement of the two running
    /// together on a device, and the README says so; the 6 GB case in particular should
    /// be expected to fail and to say so rather than to work.
    private static var evictsWhenIdle: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }

    private static let idleTimeout = Duration.seconds(60)

    // MARK: - Loading

    func load() async {
        if isReady { return }
        if case .loading = loadState { return }

        // Before any `Memory` touch, which is what would abort the process on a
        // Simulator rather than fail. See `hasMLXDevice`; the whole reason the app
        // degrades to lexical-only retrieval there is this guard.
        guard hasMLXDevice else {
            loadState = .failed(
                "The iOS Simulator has no Metal device for MLX, so nothing can be "
                    + "embedded here. The library, the reader and keyword search all "
                    + "work; run on a device for meaning-based retrieval.")
            return
        }

        loadState = .loading(nil)
        do {
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: Self.downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: EmbedderRegistry.shared.configuration(id: modelID)
            ) { progress in
                Task { @MainActor in
                    self.loadState = .loading(progress.fractionCompleted)
                }
            }
            self.container = container
            self.pooling = await container.poolingStrategy
            loadState = .ready
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    /// Drops the weights and the buffer pool.
    ///
    /// Idempotent, and safe to call while nothing is loaded, because the iOS memory
    /// warning handler calls it without asking.
    func evict() {
        evictionTask?.cancel()
        evictionTask = nil
        guard container != nil else { return }
        container = nil
        loadState = .idle
        if hasMLXDevice { Memory.clearCache() }
    }

    /// Restarts the idle countdown. Called after every use.
    private func scheduleEviction() {
        guard Self.evictsWhenIdle else { return }
        evictionTask?.cancel()
        evictionTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            evict()
        }
    }

    /// Where the weights come from.
    ///
    /// The same fork `AnswerService.downloader` makes, and it matters more here: with
    /// the Mac sandbox off, `~/.cache/huggingface/hub` is shared with
    /// `Tools/embedder-tool`, so a machine that has run that tool has already paid for
    /// these 550 MB. iOS may not use the default — swift-huggingface picks
    /// `Library/Caches` for a sandboxed app and iOS reclaims `Caches` under disk
    /// pressure, which means a silent re-download on some later launch.
    private static var downloader: any Downloader {
        #if os(macOS)
            #hubDownloader()
        #else
            #hubDownloader(HubClient(cache: HubCache(cacheDirectory: hubCacheDirectory())))
        #endif
    }

    #if !os(macOS)
        private static func hubCacheDirectory() -> URL {
            var root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("huggingface", isDirectory: true)
            let hub = root.appendingPathComponent("hub", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: hub, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            return hub
        }
    #endif

    // MARK: - Embedding

    /// Embeds one query.
    ///
    /// Returns `nil` rather than throwing when the embedder is unavailable, because the
    /// caller's correct response is to search lexically and say so, not to fail.
    func embed(query: String) async -> [Float]? {
        guard await loadIfNeeded() else { return nil }
        defer { scheduleEviction() }
        return await embed([Self.queryPrefix + query]).first
    }

    /// Embeds documents, in length-sorted batches, reporting progress per batch.
    ///
    /// The progress is per batch and not a spinner, because this is the one operation in
    /// the app that takes tens of seconds and it happens at the moment the reader is
    /// least invested — they have just typed a number and have nothing yet.
    func embed(
        documents texts: [String], progress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> [[Float]] {
        guard await loadIfNeeded() else { throw EmbeddingError.unavailable }
        defer { scheduleEviction() }

        // Sorted by length so a batch pads to nearly nothing, then restored to the
        // caller's order. Without this one 900-word paragraph makes its whole batch of
        // sixteen cost 900 words each.
        let order = texts.indices.sorted { texts[$0].count < texts[$1].count }
        var out = [[Float]](repeating: [], count: texts.count)
        var done = 0

        for start in stride(from: 0, to: order.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let slice = Array(order[start ..< min(start + Self.batchSize, order.count)])
            let vectors = await embed(slice.map { Self.documentPrefix + texts[$0] })
            for (position, index) in slice.enumerated() where position < vectors.count {
                out[index] = vectors[position]
            }
            done += slice.count
            progress(done, texts.count)
        }
        return out
    }

    private func loadIfNeeded() async -> Bool {
        if isReady { return true }
        if case .failed = loadState { return false }
        await load()
        return isReady
    }

    enum EmbeddingError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "The embedding model is not loaded, so nothing can be indexed."
        }
    }

    /// One forward pass over a batch.
    ///
    /// The body is `Tools/embedder-tool`'s `EmbedderRuntime.embed(texts:)`, reused
    /// because it is already right about the things that are easy to get wrong: the
    /// `[PAD]`-or-EOS fallback for a tokenizer with no pad token, the attention mask as
    /// `padded .!= padToken`, the zeroed token-type ids, and `pooled.eval()` **before
    /// returning**, which is load-bearing rather than tidy — `MLXArray` is not
    /// `Sendable`, so the values have to be realised inside the `perform` closure.
    ///
    /// Two things are added. Token arrays are truncated to `maximumTokens`, which that
    /// version does not do and which turns one long paragraph into a quadratic cost for
    /// its whole batch. And the rank-3 fallback from `PoolingSupport.extractVectors` is
    /// inlined: a pooling configuration that returns per-token embeddings instead of one
    /// vector per text is silent otherwise, and produces garbage rather than an error.
    private func embed(_ texts: [String]) async -> [[Float]] {
        guard let container, !texts.isEmpty else { return [] }
        let pooling = self.pooling

        return await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = texts.map { text -> [Int] in
                let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
                return Array(tokens.prefix(Self.maximumTokens))
            }
            guard let longest = encoded.map(\.count).max(), longest > 0 else { return [] }

            let padToken = tokenizer.convertTokenToId("[PAD]") ?? tokenizer.eosTokenId ?? 0
            let padded = stacked(
                encoded.map {
                    MLXArray($0 + Array(repeating: padToken, count: longest - $0.count))
                })
            let mask = (padded .!= padToken)

            let outputs = context.model(
                padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded),
                attentionMask: mask)

            var pooled = Pooling(strategy: pooling)(
                outputs, mask: mask, normalize: true, applyLayerNorm: false)
            if pooled.shape.count == 3 {
                // A pooling strategy that returned sequence embeddings. Mean over tokens
                // rather than an error, matching `PoolingSupport`'s fallback — the
                // alternative is a crash on a model whose config this app did not
                // anticipate.
                pooled = mean(pooled, axis: 1)
            }
            pooled.eval()
            guard pooled.shape.count == 2 else { return [] }
            // Normalized again on the CPU: the pooler's `normalize` is applied before the
            // rank-3 fallback can run, and `VectorOperations.normalize` additionally
            // zeroes any non-finite component, which is what keeps one bad vector from
            // making every dot product against it NaN.
            return pooled.map { VectorOperations.normalize($0.asArray(Float.self)) }
        }
    }
}
