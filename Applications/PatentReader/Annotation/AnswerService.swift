// Copyright © 2026 Apple Inc.

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Where an answer is, between a question and finished prose. Every wait needs a name.
enum Phase: Equatable, Sendable {
    case idle
    case cached
    /// Embedding the query and ranking the library. Named separately from prefilling
    /// because on iOS it can include loading 550 MB of embedder, and a reader watching
    /// "Prefilling…" for eight seconds would reasonably think the LLM had hung.
    case retrieving
    /// Covers the private-reasoning window too. Qwen3 under `enable_thinking: false`
    /// crosses that in milliseconds; a model that reasons at length sits here with
    /// nothing to show, because the framework withholds reasoning from the public
    /// stream.
    case prefilling
    case answering
    case listingFollowUps
}

struct GenerationStats: Sendable, Equatable {
    var promptTokenCount: Int
    var generationTokenCount: Int
    var promptTime: TimeInterval
    var tokensPerSecond: Double
    var peakBytes: Int
    /// Why generation stopped. `.length` on a short answer means the budget went
    /// somewhere invisible, which here means reasoning: this app passes no tools, so a
    /// rejected tool call is not a way for it to happen.
    var stopReason: GenerateStopReason

    var promptTokensPerSecond: Double {
        promptTime > 0 ? Double(promptTokenCount) / promptTime : 0
    }
}

enum AnswerEvent: Sendable {
    /// Served entirely from disk: no model work at all.
    case cached(CachedAnswer)
    case phase(Phase)
    case retrieved([RetrievedChunk])
    /// The passages a summary rests on, in document order.
    ///
    /// A summary's counterpart to `retrieved`, and a separate case rather than a reuse of
    /// it: a `RetrievedChunk` carries a dense and a lexical score, nothing searched for
    /// these, and fabricating two scores so the existing case would fit would put invented
    /// numbers into the diagnostics strip. What the reader is owed here is only *which*
    /// passages, which is what the marks and the passage count are drawn from.
    case summarizing([CitationTarget])
    case promptTokens(Int)
    case answer(String)
    case followUps([String])
    case stats(GenerationStats)
    /// Quoted spans the model produced that are in none of the retrieved passages.
    ///
    /// Diagnostic, never a correction: `QuoteCheck` reports and does not strip, and what
    /// the reader sees is a separate decision from knowing the prompt slipped.
    case unsupportedQuotes([String])
    case failed(String)
}

/// Loads Qwen3-4B, retrieves, and streams a cited answer from it.
///
/// The shape is ShakespeareReader's `AnnotationService`, and most of it is ported
/// verbatim because most of it is about MLX and `ChatSession` rather than about the
/// subject: `configuration(for:)`, `downloader`, `hubCacheDirectory()`, `DisplacedWork`,
/// `nonThinking`, `tokenCount` and `stats` are unchanged.
///
/// Two things are new: a retrieval step before generation, and a second model resident.
/// See `tuneMemory(added:)` for the second, which is the one that changed a function
/// rather than adding one.
@MainActor
@Observable
final class AnswerService {

    enum LoadState {
        case idle
        case loading(Progress?)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle

    let modelID: String
    private let presets: Prompts.SamplingPresets
    private let cache: AnswerCache
    private var container: ModelContainer?

    /// One session per question, shared by the answer, the suggested follow-ups, and
    /// every tapped question after it. Turn 1 streams the answer, turn 2 produces the
    /// numbered list, turn 3+ answers taps — all off the same KV cache, so the
    /// 2,000-token context block is prefilled once and a later turn costs a few hundred
    /// tokens rather than the whole prompt.
    private var conversation: Conversation?
    private var activeTask: Task<Void, Never>?

    init(modelID: String = LLMRegistry.qwen3_4b_4bit.name, greedy: Bool = false) {
        self.modelID = modelID
        presets = greedy ? .greedy : .recommended
        cache = AnswerCache(modelID: modelID)
    }

    private final class Conversation {
        let context: AnswerContext
        let session: ChatSession
        /// The retrieved passages as the model was given them, which is what
        /// `QuoteCheck` compares against — not the whole patent, since quoting a
        /// paragraph that was never shown is the defect.
        let passageText: String
        var answer = ""
        var followUpsRaw = ""
        var followUps: [String] = []
        var asked: Set<String> = []
        var promptTokenCount = 0
        /// A cache hit rehydrates lazily, on the first follow-up tap, so a cache hit
        /// itself costs nothing.
        var needsHistoryPrefill: Bool

        init(
            context: AnswerContext, session: ChatSession, needsHistoryPrefill: Bool = false
        ) {
            self.context = context
            self.session = session
            self.passageText = context.passages.map(\.text).joined(separator: "\n")
            self.needsHistoryPrefill = needsHistoryPrefill
        }
    }

    // MARK: - Loading

    /// The registered configuration for `modelID`, from whichever registry has it.
    ///
    /// This matters more than it looks. `AbstractModelRegistry.configuration(id:)`
    /// returns a *bare* configuration for an id it does not know, which silently drops
    /// the model's stop tokens, tool-call format and reasoning delimiters — Qwen3 needs
    /// `extraEOSTokens: ["<|im_end|>"]` or it runs past the end of every turn.
    static func configuration(for modelID: String) -> ModelConfiguration {
        if LLMRegistry.shared.contains(id: modelID) {
            return LLMRegistry.shared.configuration(id: modelID)
        }
        if VLMRegistry.shared.contains(id: modelID) {
            return VLMRegistry.shared.configuration(id: modelID)
        }
        return LLMRegistry.shared.configuration(id: modelID)
    }

    /// Sizes the MLX buffer-reuse pool to the weights **this load added**.
    ///
    /// ShakespeareReader's version read `Memory.snapshot().activeMemory` straight after
    /// loading and branched on whether it exceeded 8 GB. That worked precisely because
    /// exactly one model was ever resident: resident size *was* the model's size, so an
    /// absolute reading was a valid proxy for "how big is the thing that just loaded".
    ///
    /// This app holds an embedder as well, so the proxy now measures the sum. It does
    /// not misfire today — 550 MB does not push a 4B model over 8 GB — and that is
    /// exactly why it is worth fixing now rather than after it does: a proxy that has
    /// quietly stopped measuring what it names is a bug waiting for the next model. A
    /// delta against a baseline taken before the load measures the thing the pool is
    /// actually sized for.
    ///
    /// **The iOS ceiling is unchanged and is now shared between two models**, which is
    /// the part to be honest about. `min(6 GB, physical / 2)` was tuned for one 4B model
    /// with a measured 3.31 GB peak. On an 8 GB device that leaves roughly 700 MB for a
    /// 550 MB embedder — inside the budget with nothing spare — and on a 6 GB device the
    /// ceiling is 3 GB and the pair does not fit at all. `EmbeddingService` evicts on
    /// iOS for this reason, so the two are rarely resident together; when they are, the
    /// honest outcome on a small device is backpressure and slowness, or a reported
    /// failure, rather than a process that disappears. That is arithmetic over measured
    /// parts, not a measurement of the pair — see the README.
    private static func tuneMemory(added bytes: Int) {
        let isLarge = bytes > 8 * 1024 * 1024 * 1024
        Memory.cacheLimit = isLarge ? 2 * 1024 * 1024 * 1024 : 256 * 1024 * 1024
        #if os(macOS)
            if isLarge {
                Memory.memoryLimit = 48 * 1024 * 1024 * 1024
            }
        #else
            Memory.memoryLimit = min(
                6 * 1024 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory) / 2)
        #endif
    }

    /// Where the weights come from.
    ///
    /// macOS takes the default, `~/.cache/huggingface/hub`, shared with every other MLX
    /// tool and with Python's `huggingface_hub` — which with the sandbox off means this
    /// app and ShakespeareReader share one copy of Qwen3, so the second of them to be
    /// installed costs only the embedder download.
    ///
    /// iOS may not. swift-huggingface picks `Library/Caches/huggingface/hub` for a
    /// sandboxed app, and iOS reclaims `Caches` under disk pressure whenever it likes,
    /// which for a 2.2 GB snapshot means a silent full re-download on some later launch.
    /// `Application Support` is not purgeable, and it is already where the library is.
    private static var downloader: any Downloader {
        #if os(macOS)
            #hubDownloader()
        #else
            #hubDownloader(HubClient(cache: HubCache(cacheDirectory: hubCacheDirectory())))
        #endif
    }

    #if !os(macOS)
        /// `Application Support/huggingface/hub`, a sibling of `PatentReader/` rather
        /// than a child, so the layout under `huggingface/` stays the Python-compatible
        /// one `HubCache` documents — and so it is shared with the embedder, which uses
        /// the same directory for the same reason.
        ///
        /// Excluded from backup: these are bytes Hugging Face will hand back on demand,
        /// and 2.75 GB of them has no business in anyone's iCloud backup.
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

    func load() async {
        if case .ready = loadState { return }
        if case .loading = loadState { return }

        // Before the first `Memory` touch below, which is what would abort the process
        // on a Simulator rather than fail. See `hasMLXDevice`.
        guard hasMLXDevice else {
            loadState = .failed(
                "The iOS Simulator has no Metal device for MLX, so nothing can be "
                    + "answered here. The library, the reader and keyword search all "
                    + "work; run on a device to generate.")
            return
        }

        Memory.cacheLimit = 256 * 1024 * 1024
        let before = Memory.snapshot().activeMemory
        loadState = .loading(nil)
        do {
            let container = try await loadModelContainer(
                from: Self.downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: Self.configuration(for: modelID)
            ) { progress in
                Task { @MainActor in
                    self.loadState = .loading(progress)
                }
            }
            self.container = container
            Self.tuneMemory(added: Memory.snapshot().activeMemory - before)
            loadState = .ready
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    // MARK: - Answering

    /// Retrieves, then streams a cited answer, then the questions to offer next.
    ///
    /// `async` because the previous generation has to be cancelled and waited out
    /// *before* the new task exists. Doing it inside the new task would mean either
    /// awaiting itself or capturing the old `ChatSession` in a `@Sendable` closure, and
    /// `ChatSession` is not `Sendable`.
    func answer(
        question: String,
        library: LibraryService,
        scope: Set<PatentKey>? = nil,
        ignoringCache: Bool = false
    ) async -> AsyncStream<AnswerEvent> {
        await displaceActiveWork().finish()

        let (stream, continuation) = AsyncStream<AnswerEvent>.makeStream()

        let work = Task { @MainActor in
            guard let container else {
                continuation.yield(.failed(AnswerError.notLoaded.localizedDescription))
                continuation.finish()
                return
            }

            continuation.yield(.phase(.retrieving))
            // `nil` is a real answer here and not a failure: the embedder is unavailable
            // on the Simulator and may be mid-load on a phone, and BM25 alone answers
            // reference-numeral and term-of-art questions well. The context records it
            // so the pane can say the search was keyword-only rather than letting a
            // thinner answer look like a normal one.
            let vector = await library.embedder.embed(query: question)
            let chunks = Retriever.retrieve(
                question: question, queryVector: vector, index: library.index, scope: scope)
            continuation.yield(.retrieved(chunks))

            guard
                let context = AnswerContext.build(
                    question: question, retrieved: chunks, library: library.patents,
                    isLexicalOnly: vector == nil)
            else {
                continuation.yield(
                    .failed(
                        library.index.chunks.isEmpty
                            ? "Nothing is indexed yet, so there is nothing to search. "
                                + "Import a patent, or wait for indexing to finish."
                            : "No passage in the library matched that question."))
                continuation.yield(.phase(.idle))
                continuation.finish()
                return
            }

            await respond(
                with: context, container: container, ignoringCache: ignoringCache,
                to: continuation)
        }

        // Cancelling the consumer has to cancel the generation. This closure is
        // `@Sendable` and runs off the main actor, so it may only cancel — it must not
        // touch the session.
        continuation.onTermination = { _ in work.cancel() }
        activeTask = work
        return stream
    }

    // MARK: - Summarizing

    /// Streams a cited summary of the passages the reader selected in the document.
    ///
    /// **There is no retrieval leg, and that is the feature rather than an optimization.**
    /// `Retriever`'s header carries the argument that a patent's own hierarchy is useless
    /// for finding an answer because "the reader asks a question and does not know where the
    /// answer is". A selection is the case where they do know: nothing has to be found,
    /// nothing has to be ranked, no embedder has to load, and the summary is grounded in
    /// exactly what the reader pointed at. It is `PassageContext` next door, arriving here
    /// by a different route.
    ///
    /// Everything after the context is `answer`'s, unchanged — see `respond`.
    func summarize(
        _ targets: [CitationTarget], in patent: Patent, ignoringCache: Bool = false
    ) async -> AsyncStream<AnswerEvent> {
        await displaceActiveWork().finish()

        let (stream, continuation) = AsyncStream<AnswerEvent>.makeStream()

        let work = Task { @MainActor in
            guard let container else {
                continuation.yield(.failed(AnswerError.notLoaded.localizedDescription))
                continuation.finish()
                return
            }

            // Refused rather than summarized from the raw selection, which is the one place
            // this path can fail and the reason it fails loudly. A summary this app cannot
            // cite is a summary nobody can check against the document, and making checking
            // cheap is what the whole design is for.
            guard let context = AnswerContext.selection(targets, in: patent) else {
                continuation.yield(
                    .failed(
                        "None of that selection could be placed in a passage of "
                            + "\(patent.key.display), so there is nothing to summarize "
                            + "that could be cited."))
                continuation.yield(.phase(.idle))
                continuation.finish()
                return
            }
            continuation.yield(.summarizing(context.passages.map(\.target)))

            await respond(
                with: context, container: container, ignoringCache: ignoringCache,
                to: continuation)
        }

        continuation.onTermination = { _ in work.cancel() }
        activeTask = work
        return stream
    }

    // MARK: - The generation both paths share

    /// Everything that happens once a context exists: the cache, the session, the stream,
    /// the quote check and the follow-ups.
    ///
    /// Extracted so `answer` and `summarize` differ *only* in how they arrive at a context —
    /// one searches for it, the other is handed a selection — and share every line after it.
    /// Three things in here are load-bearing and each is easy to get subtly wrong in a
    /// second copy: the cache's four-way key, the guard that never stores a partial answer,
    /// and the rule that a cancelled `ChatSession` is never reused.
    ///
    /// Which prompt gets rendered is read off `context.purpose` rather than passed in, so a
    /// summary context cannot be handed the answering request or the other way about.
    private func respond(
        with context: AnswerContext,
        container: ModelContainer,
        ignoringCache: Bool,
        to continuation: AsyncStream<AnswerEvent>.Continuation
    ) async {
        if !ignoringCache,
            let entry = await cache.answer(for: context.digest)
        {
            continuation.yield(.phase(.cached))
            continuation.yield(.cached(entry))
            let restored = Conversation(
                context: context,
                session: rehydratedSession(container, context: context, entry: entry),
                needsHistoryPrefill: true)
            restored.answer = entry.answer
            restored.followUpsRaw = entry.followUpsRaw
            restored.followUps = entry.followUps
            restored.asked = Set(entry.followUps.map(Prompts.FollowUps.normalized))
            conversation = restored
            continuation.yield(.followUps(entry.followUps))
            continuation.finish()
            return
        }

        let session = ChatSession(
            container,
            instructions: Prompts.answererInstructions,
            generateParameters: presets.answer,
            additionalContext: Self.nonThinking)
        let current = Conversation(context: context, session: session)
        conversation = current

        let request =
            switch context.purpose {
            case .question: Prompts.answerRequest(context)
            case .summary: Prompts.summaryRequest(context)
            }
        current.promptTokenCount = await Self.tokenCount(
            container: container,
            instructions: Prompts.answererInstructions,
            user: request)
        continuation.yield(.promptTokens(current.promptTokenCount))
        continuation.yield(.phase(.prefilling))

        do {
            var stopReason: GenerateStopReason?
            for try await item in session.streamDetails(to: request) {
                if let chunk = item.chunk {
                    continuation.yield(.phase(.answering))
                    current.answer += chunk
                    continuation.yield(.answer(chunk))
                }
                if let info = item.info {
                    stopReason = info.stopReason
                    continuation.yield(.stats(Self.stats(info)))
                }
            }

            // Partial output is never cached: only a stream that reached `.info`
            // with a stop reason other than `.cancelled` produced a whole answer.
            guard stopReason != nil, stopReason != .cancelled, !Task.isCancelled
            else {
                continuation.finish()
                return
            }

            report(quotesIn: current.answer, against: current, to: continuation)

            continuation.yield(.phase(.listingFollowUps))
            let followUps = try await requestFollowUps(current)
            continuation.yield(.followUps(followUps))

            await cache.store(
                CachedAnswer(
                    schemaVersion: AnswerCache.schemaVersion,
                    promptVersion: Prompts.version,
                    modelID: modelID,
                    contextDigest: context.digest,
                    question: context.question,
                    answer: current.answer,
                    followUpsRaw: current.followUpsRaw,
                    followUps: followUps,
                    generatedAt: Date(),
                    promptTokenCount: current.promptTokenCount))
        } catch is CancellationError {
            // Stopped by the reader; whatever streamed already stays on screen.
        } catch {
            continuation.yield(.failed(String(describing: error)))
        }

        continuation.yield(.phase(.idle))
        continuation.finish()
    }

    /// A follow-up on the same session, against the same retrieved passages.
    ///
    /// Deliberately **not** a fresh retrieval. A tapped follow-up is a question about
    /// what was just answered, so re-retrieving would move the passages out from under
    /// the answer the reader is looking at — and a citation in the follow-up would refer
    /// to a set the first answer's chips do not. Same passages, same session, same KV
    /// cache: a few hundred tokens instead of the whole prompt. A question that genuinely
    /// needs different passages is a new question, and the Ask field is how it is asked.
    func followUp(_ question: String) -> AsyncStream<AnswerEvent> {
        let (stream, continuation) = AsyncStream<AnswerEvent>.makeStream()

        let work = Task { @MainActor in
            guard let current = conversation else {
                continuation.finish()
                return
            }

            current.asked.insert(Prompts.FollowUps.normalized(question))
            // Only `maxTokens` changes between turns. Mutating `kvCache`, `maxKVSize` or
            // `kvBits` on a live session throws `kvCacheConfigurationChanged`, and
            // `instructions` is never touched mid-session.
            current.session.generateParameters = presets.answer
            if current.needsHistoryPrefill {
                // A rehydrated session prefills the whole recorded transcript — context,
                // answer and question list — so roughly 2.5k tokens or about a second.
                // Paid here, on the first tap, rather than on every cache hit.
                continuation.yield(.phase(.prefilling))
                current.needsHistoryPrefill = false
            }
            continuation.yield(.phase(.answering))

            do {
                var answer = ""
                for try await item in current.session.streamDetails(
                    to: Prompts.followUpRequest(question))
                {
                    if let chunk = item.chunk {
                        answer += chunk
                        continuation.yield(.answer(chunk))
                    }
                    if let info = item.info {
                        continuation.yield(.stats(Self.stats(info)))
                    }
                }
                report(quotesIn: answer, against: current, to: continuation)

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                // Sustain the loop: ask for more, keep what is not already asked. Same
                // two-survivor floor as turn 2 and for the same reason — one lonely chip
                // looks broken.
                continuation.yield(.phase(.listingFollowUps))
                current.session.generateParameters = presets.followUp
                let raw = try await collect(
                    current.session.streamDetails(to: Prompts.questionSuggestionRequest))
                let fresh = Prompts.FollowUps.parse(raw, asked: current.asked)
                if fresh.count >= 2 {
                    current.followUps = fresh
                    current.asked.formUnion(fresh.map(Prompts.FollowUps.normalized))
                    continuation.yield(.followUps(fresh))
                }
            } catch is CancellationError {
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }

            continuation.yield(.phase(.idle))
            continuation.finish()
        }

        continuation.onTermination = { _ in work.cancel() }
        activeTask = work
        return stream
    }

    /// Turn 2: the numbered list.
    private func requestFollowUps(_ current: Conversation) async throws -> [String] {
        current.session.generateParameters = presets.followUp

        var raw = try await collect(
            current.session.streamDetails(to: Prompts.questionSuggestionRequest))
        var parsed = Prompts.FollowUps.parse(raw, asked: current.asked)

        // Fewer than two survivors gets one retry, then the row is hidden — one lonely
        // chip looks broken.
        if parsed.count < 2 {
            raw = try await collect(
                current.session.streamDetails(to: Prompts.questionRetry))
            parsed = Prompts.FollowUps.parse(raw, asked: current.asked)
        }

        current.followUpsRaw = raw
        current.followUps = parsed.count < 2 ? [] : parsed
        current.asked.formUnion(current.followUps.map(Prompts.FollowUps.normalized))
        return current.followUps
    }

    private func collect(_ stream: AsyncThrowingStream<Generation, Error>) async throws
        -> String
    {
        var text = ""
        for try await item in stream {
            if let chunk = item.chunk { text += chunk }
        }
        return text
    }

    /// Runs the quote check and reports what failed. Never alters the text.
    private func report(
        quotesIn text: String, against current: Conversation,
        to continuation: AsyncStream<AnswerEvent>.Continuation
    ) {
        let unsupported = QuoteCheck.unsupported(in: text, passage: current.passageText)
        guard !unsupported.isEmpty else { return }
        continuation.yield(.unsupportedQuotes(unsupported))
    }

    /// Rebuilds a session from a cache entry's recorded text.
    ///
    /// `followUpsRaw` rather than the parsed list, so the rehydrated history is
    /// byte-identical to what the model actually said. The user turn is reconstructed
    /// from the context, which is safe here in a way it was not next door: the context
    /// is keyed by digest, so a hit means the passages are the same bytes.
    private func rehydratedSession(
        _ container: ModelContainer, context: AnswerContext, entry: CachedAnswer
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: Prompts.answererInstructions,
            history: [
                .user(Prompts.answerRequest(context)),
                .assistant(entry.answer),
                .user(Prompts.questionSuggestionRequest),
                .assistant(entry.followUpsRaw),
            ],
            generateParameters: presets.answer,
            additionalContext: Self.nonThinking)
    }

    // MARK: - Cancellation

    /// In-flight work, detached from the service so it can be waited out from the task
    /// that replaces it.
    ///
    /// `@unchecked Sendable`, with a specific reason rather than to quiet the checker.
    /// `ChatSession.synchronize()` is a `@concurrent` `async` method on a non-`Sendable`
    /// class, so awaiting it from the main actor is "sending" the session off its actor.
    /// That is safe *here* because by construction this box holds the only remaining
    /// reference: `displaceActiveWork()` clears `conversation` before the box exists, and
    /// `finish()` awaits the task that was using the session before touching it. The box
    /// is dropped immediately after.
    private struct DisplacedWork: @unchecked Sendable {
        let task: Task<Void, Never>?
        let session: ChatSession?

        /// Cancel, then wait, then wait again for exclusive cache access. All three
        /// steps matter. `cancel()` alone returns while the forward pass is still
        /// resident. `await task.value` alone returns while `ChatSession`'s own
        /// unstructured generation task may still be winding down and holding the cache
        /// lock — which is exactly what `synchronize()` waits for.
        func finish() async {
            task?.cancel()
            await task?.value
            await session?.synchronize()
        }
    }

    /// Takes ownership of whatever is running and clears the service's references.
    ///
    /// The session goes with it: a cancelled generation invalidates `ChatSession`'s
    /// token ledger, so a cancelled session must never be reused.
    private func displaceActiveWork() -> DisplacedWork {
        let work = DisplacedWork(task: activeTask, session: conversation?.session)
        activeTask?.cancel()
        activeTask = nil
        conversation = nil
        return work
    }

    /// Cancels in-flight work and discards the session. Bound to Esc.
    func stopActiveWork() async {
        await displaceActiveWork().finish()
    }

    var context: AnswerContext? { conversation?.context }

    // MARK: - Helpers

    /// Template variables that ask a model not to think at length before answering.
    ///
    /// Both keys are sent to every model because a chat template simply ignores a
    /// variable it does not reference. `enable_thinking` is Qwen3's: without it Qwen3
    /// reasons before the first visible token, a silent window with nothing on screen to
    /// account for it. `reasoning_strength` is Muse-Glimmer's, whose template defaults to
    /// `high` and which at `high` spends the whole budget reasoning and produces no
    /// visible answer at all, because reasoning tokens count against `maxTokens` while
    /// being withheld from the stream.
    static let nonThinking: [String: any Sendable] = [
        "enable_thinking": false,
        "reasoning_strength": "low",
    ]

    /// The exact prompt length, without generating anything. Used by `--show-prompt`.
    func promptTokenCount(for request: String) async -> Int {
        guard let container else { return 0 }
        return await Self.tokenCount(
            container: container, instructions: Prompts.answererInstructions,
            user: request)
    }

    private static func tokenCount(
        container: ModelContainer, instructions: String, user: String
    ) async -> Int {
        let tokenizer = await container.tokenizer
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": instructions],
            ["role": "user", "content": user],
        ]
        return
            (try? tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nonThinking))?.count ?? 0
    }

    private static func stats(_ info: GenerateCompletionInfo) -> GenerationStats {
        GenerationStats(
            promptTokenCount: info.promptTokenCount,
            generationTokenCount: info.generationTokenCount,
            promptTime: info.promptTime,
            tokensPerSecond: info.tokensPerSecond,
            peakBytes: Memory.snapshot().peakMemory,
            stopReason: info.stopReason)
    }
}

enum AnswerError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The model is not loaded yet."
        }
    }
}
