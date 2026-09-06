// Copyright © 2026 Apple Inc.

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Where a generation is, between a selection and a finished annotation. Every wait
/// here needs a name.
enum Phase: Equatable, Sendable {
    case idle
    case cached
    /// Covers the private-reasoning window too. Qwen3 under
    /// `enable_thinking: false` crosses that in milliseconds; a model that reasons
    /// at length sits here with nothing to show, because the framework withholds
    /// reasoning from the public stream.
    case prefilling
    case streaming
    case listingFollowUps
    case answering
    /// The answer draft is written and is being revised before the reader sees it.
    /// The one turn with an edit channel; see `Prompts.answerRevision`.
    case revising

    /// What the pane says while the reader waits, or `nil` for a state with nothing
    /// to say. The commentary is held back until it is whole, so this is the only
    /// thing on screen for the length of a generation.
    ///
    /// Deliberately not `ContentView.statusStrip`'s copy, which names the machinery
    /// for someone working on the app. This names the work for someone waiting on it,
    /// which is why `.prefilling` and `.streaming` do not read as one stage and
    /// `.answering` and `.revising` do: the reader has no stake in the draft being
    /// rewritten, only in the answer taking a moment.
    var label: String? {
        switch self {
        case .idle, .cached: nil
        case .prefilling: "Reading the passage…"
        case .streaming: "Annotating…"
        case .answering, .revising: "Answering…"
        case .listingFollowUps: "Finding what to ask next…"
        }
    }
}

struct GenerationStats: Sendable, Equatable {
    var promptTokenCount: Int
    var generationTokenCount: Int
    var promptTime: TimeInterval
    var tokensPerSecond: Double
    var peakBytes: Int
    /// Why generation stopped. `.length` on an empty annotation means the budget
    /// went somewhere invisible, which here means reasoning: this app passes no
    /// tools, so a rejected tool call is not a way for it to happen.
    var stopReason: GenerateStopReason

    /// Prefill throughput, the number the plan's shedding list is decided on.
    var promptTokensPerSecond: Double {
        promptTime > 0 ? Double(promptTokenCount) / promptTime : 0
    }
}

enum AnnotationEvent: Sendable {
    /// Served entirely from disk: no model work at all.
    case cached(CachedPassage)
    case phase(Phase)
    case promptTokens(Int)
    case commentary(String)
    case answer(String)
    case followUps([String])
    case stats(GenerationStats)
    /// The follow-up turn's own numbers. Separate from `.stats` because the UI
    /// should keep showing the reader's own request, and because this is the one
    /// measurement that shows KV cache reuse: turn 2 prefills 250-350 tokens
    /// against a 526-1,023-token turn 1, and its cost tracks the length of the
    /// commentary rather than the length of the context.
    case followUpStats(GenerationStats)
    /// Quoted spans the model produced that are not in the selected passage.
    ///
    /// Diagnostic, never a correction: `QuoteCheck` reports and does not strip, and
    /// what the reader sees is a separate decision from knowing the prompt slipped.
    case unsupportedQuotes([String])
    /// Quoted spans that are not anywhere in the Bible. A strictly worse failure than
    /// `unsupportedQuotes`, which includes real scripture from outside the passage.
    case invented([String])
    /// Every scripture reference the model named, with its verdict. **This one does
    /// reach the reader** rather than only the diagnostics strip: a nonexistent citation
    /// is struck through in the pane. See `ReferenceCheck`.
    case references([CheckedReference])
    /// Named Fathers, works, councils or documents with a locator attached.
    case unverifiedCitations([String])
    case failed(String)
}

/// Loads Qwen3-4B once and streams annotations from it.
///
/// Ported from ShakespeareReader with one structural cut: **there is no background
/// summarization path**. That app had to generate a synopsis of every scene, because
/// nothing in a Gutenberg play text summarizes one, and the prewarm task, its cancel and
/// retry logic, the `.summarizingScene` phase and half the cache went with it. Here
/// Challoner already wrote a summary of every chapter and it is read straight out of the
/// JSON, so the whole apparatus is gone and what replaces it is free, instant and
/// authored.
///
/// The shape is the conventional one for an on-device streaming service:
/// `@MainActor @Observable`, a `LoadState`,
/// `#hubDownloader()` / `#huggingFaceTokenizerLoader()` to load, and an
/// `AsyncStream` whose `continuation.onTermination` cancels the work `Task`.
///
/// `ChatSession` is a non-`Sendable` `final class`, which shapes the whole API: the
/// session lives inside this main-actor class, work runs in a `Task {}` created
/// from a main-actor method so it inherits that isolation, and the `@Sendable`
/// `onTermination` closure may only `cancel()` — it must never touch the session.
@MainActor
@Observable
final class AnnotationService {

    enum LoadState {
        case idle
        case loading(Progress?)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle

    let modelID: String
    private let presets: Prompts.SamplingPresets
    private let cache: AnnotationCache
    private var container: ModelContainer?

    /// One session per passage, shared by the commentary, the follow-up list, and
    /// every tapped question. Turn 1 streams the commentary, turn 2 produces the
    /// numbered list, turn 3+ answers taps — all off the same KV cache, so the
    /// 600-900 token context block is prefilled once and a later turn costs about
    /// 300 tokens (the re-rendered assistant text) rather than the whole prompt.
    private var passage: PassageSession?

    private var activeTask: Task<Void, Never>?

    init(modelID: String = LLMRegistry.qwen3_4b_4bit.name, greedy: Bool = false) {
        self.modelID = modelID
        presets = greedy ? .greedy : .recommended
        cache = AnnotationCache(modelID: modelID)
    }

    private final class PassageSession {
        let key: PassageKey
        let digest: String
        let session: ChatSession
        /// The selected verses as the model was given them, which is what
        /// `QuoteCheck` has to compare against — not the whole chapter, and not the
        /// BEFORE window, since quoting either of those is the defect.
        let passageText: String
        /// The cross-references the prompt actually handed over, which is what
        /// `ReferenceCheck` needs in order to tell `.ok` from `.ungiven`.
        let supplied: [CrossReference]
        var commentary = ""
        var followUpsRaw = ""
        var followUps: [String] = []
        var asked: Set<String> = []
        var promptTokenCount = 0
        var tokensPerSecond: Double = 0
        /// A cache hit rehydrates lazily, on the first follow-up tap, so a cache hit
        /// itself costs nothing.
        var needsHistoryPrefill: Bool

        init(
            key: PassageKey, digest: String, session: ChatSession,
            passageText: String, supplied: [CrossReference],
            needsHistoryPrefill: Bool = false
        ) {
            self.key = key
            self.digest = digest
            self.session = session
            self.passageText = passageText
            self.supplied = supplied
            self.needsHistoryPrefill = needsHistoryPrefill
        }
    }

    /// Runs all three checks and reports what failed. **Never alters the text.**
    ///
    /// The three are deliberately different questions, and running them together is what
    /// keeps them from being confused for one another:
    ///
    /// - `QuoteCheck` — a quotation that is not in the selected passage. May still be
    ///   real scripture from elsewhere, which is why it is only a diagnostic.
    /// - `ReferenceCheck.quotedVerse` — a quotation that is nowhere in the Bible at all.
    ///   Strictly worse, and the one worth a reader's attention.
    /// - `ReferenceCheck.check` — a named reference, resolved and compared against what
    ///   was supplied. The only one whose result reaches the pane.
    /// - `PatristicCheck` — a named Father, work or document with a number on it.
    private func report(
        _ text: String, against current: PassageSession,
        to continuation: AsyncStream<AnnotationEvent>.Continuation
    ) {
        let unsupported = QuoteCheck.unsupported(in: text, passage: current.passageText)
        if !unsupported.isEmpty {
            continuation.yield(.unsupportedQuotes(unsupported))
        }
        if let corpus = grounding {
            let invented = ReferenceCheck.quotedVerse(text, in: corpus.haystack)
            if !invented.isEmpty {
                continuation.yield(.invented(invented))
            }
            let checked = ReferenceCheck.check(
                text, supplied: current.supplied, bible: corpus.bible,
                table: corpus.table)
            if !checked.isEmpty {
                continuation.yield(.references(checked))
            }
        }
        let citations = PatristicCheck.unverified(in: text)
        if !citations.isEmpty {
            continuation.yield(.unverifiedCitations(citations))
        }
    }

    /// What the checks need to resolve a reference, handed in once by `ContentView`.
    ///
    /// Optional so the service is usable before the corpus loads and in tests, and a
    /// struct rather than three properties so the three can never be half-set — a
    /// `Bible` without its `BookTable` would silently make every reference nonexistent.
    struct Grounding: Sendable {
        var bible: Bible
        var table: BookTable
        var haystack: CorpusHaystack

        init(bible: Bible, table: BookTable) {
            self.bible = bible
            self.table = table
            self.haystack = CorpusHaystack(bible)
        }
    }

    private var grounding: Grounding?

    func ground(_ value: Grounding) { grounding = value }

    // MARK: - Loading

    /// The registered configuration for `modelID`, from whichever registry has it.
    ///
    /// This matters more than it looks. `AbstractModelRegistry.configuration(id:)`
    /// returns a *bare* configuration for an id it does not know, which silently
    /// drops the model's stop tokens, tool-call format and reasoning delimiters —
    /// Qwen3 needs `extraEOSTokens: ["<|im_end|>"]` or it runs past the end of every
    /// turn, and Muse-Glimmer needs its `reasoningConfig` or its private reasoning
    /// arrives as visible text.
    static func configuration(for modelID: String) -> ModelConfiguration {
        if LLMRegistry.shared.contains(id: modelID) {
            return LLMRegistry.shared.configuration(id: modelID)
        }
        if VLMRegistry.shared.contains(id: modelID) {
            return VLMRegistry.shared.configuration(id: modelID)
        }
        return LLMRegistry.shared.configuration(id: modelID)
    }

    /// Sizes the MLX buffer-reuse pool to the weights that were actually loaded.
    ///
    /// 256 MB is the figure `MLXFoundationModels` picks for a ~4B model and is
    /// right for the default. It thrashes badly at 19 GB, where a single forward
    /// pass churns far larger activations — a 30B VLM measured here needed 2 GB.
    /// Deciding after the load, from resident size, means `--model` picks
    /// the right pool without a table of model sizes to keep current.
    ///
    /// The 48 GB ceiling is a Mac number and stays on the Mac. On iOS a ceiling is applied
    /// unconditionally instead, and low, so that MLX applies backpressure — waiting for
    /// buffers to free rather than allocating — instead of the app being jetsam-killed with
    /// no error to report. The `isLarge` branch cannot fire on a phone at 4B, so this is not
    /// a second guess at the same question.
    ///
    /// **Half of physical, and not a constant.** This was a flat 6 GB, on the reasoning that
    /// 6 GB is well over the 4B model's ~3 GB peak but under what iOS will hand one app with
    /// the increased-memory-limit entitlement. The second half of that is false on a 6 GB
    /// device — an iPad Pro 11-inch (2nd generation) is one — where the ceiling *is* the
    /// machine. A limit at total RAM is a limit MLX can never reach, so it never waits, and
    /// the kernel arrives first: measured on an iPad8,10, where loading died with
    /// `MTLCompiler ... XPC_ERROR_CONNECTION_INTERRUPTED` — the shader compiler service
    /// going down with the app — and `ReportMemoryException` running on the device.
    ///
    /// Half of physical means the same thing on every device it ships to, which a constant
    /// cannot: comfortably under the app's jetsam budget, so backpressure engages first. The
    /// `min` pins 8 GB and larger devices to exactly the old 6 GB, so the phone this was
    /// tuned on is unchanged. It does *not* promise the 4B model fits: at 6 GB of RAM the
    /// budget lands near the measured 3.31 GB peak, so the honest outcome there is slow, or
    /// a reported failure, rather than a process that disappears.
    private static func tuneMemory() {
        let resident = Memory.snapshot().activeMemory
        let isLarge = resident > 8 * 1024 * 1024 * 1024
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
    /// macOS takes the default, which resolves to `~/.cache/huggingface/hub` and is
    /// shared with every other MLX tool and with Python's `huggingface_hub`.
    ///
    /// iOS may not. `swift-huggingface`'s location provider picks
    /// `Library/Caches/huggingface/hub` for a sandboxed app, and iOS reclaims `Caches`
    /// under disk pressure whenever it likes, which for a 2.2 GB snapshot means a
    /// silent full re-download on some later launch, with the reader watching a
    /// progress bar they already sat through once. `Application Support` is not
    /// purgeable, and it is already where `AnnotationCache` writes.
    private static var downloader: any Downloader {
        #if os(macOS)
            #hubDownloader()
        #else
            #hubDownloader(HubClient(cache: HubCache(cacheDirectory: hubCacheDirectory())))
        #endif
    }

    #if !os(macOS)
        /// `Application Support/huggingface/hub`, a sibling of the annotation cache's
        /// own `BibleReader` directory rather than a child of it, so the layout
        /// under `huggingface/` stays the Python-compatible one `HubCache` documents.
        ///
        /// Excluded from backup: these are bytes Hugging Face will hand back on
        /// demand, and 2.2 GB of them has no business in anyone's iCloud backup or in
        /// the restore time of their next phone.
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
                    + "annotated here. The reader, the corpus and the layout all work; "
                    + "run on a device to generate.")
            return
        }

        Memory.cacheLimit = 256 * 1024 * 1024
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
            Self.tuneMemory()
            loadState = .ready
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    // MARK: - Annotation

    /// Streams the commentary for `context`, then the follow-up questions.
    ///
    /// `async` because the previous generation has to be cancelled and waited out
    /// *before* the new task exists. Doing it inside the new task would mean either
    /// awaiting itself or capturing the old `ChatSession` in a `@Sendable` closure,
    /// and `ChatSession` is not `Sendable`.
    ///
    /// - Parameter ignoringCache: ⌘R, which regenerates rather than re-reading.
    func annotate(_ context: PassageContext, ignoringCache: Bool = false) async
        -> AsyncStream<AnnotationEvent>
    {
        await displaceActiveWork().finish()

        let (stream, continuation) = AsyncStream<AnnotationEvent>.makeStream()

        let work = Task { @MainActor in
            guard let container else {
                continuation.yield(.failed(AnnotationError.notLoaded.localizedDescription))
                continuation.finish()
                return
            }

            if !ignoringCache,
                let entry = await cache.passage(for: context.key, digest: context.digest)
            {
                continuation.yield(.phase(.cached))
                // The text is restored now; the session is built but not prefilled
                // until the first follow-up tap, so a cache hit itself costs nothing.
                let restored = PassageSession(
                    key: context.key, digest: context.digest,
                    session: rehydratedSession(container, context: context, entry: entry),
                    passageText: Prompts.render(context.selected),
                    supplied: context.crossReferences, needsHistoryPrefill: true)
                restored.commentary = entry.commentary
                restored.followUpsRaw = entry.followUpsRaw
                restored.followUps = entry.followUps
                restored.asked = Set(entry.followUps.map(Prompts.FollowUps.normalized))
                passage = restored
                // The four checks run again over the restored text, and before it is
                // handed over, so a cache hit renders exactly as the run that produced
                // it did. **Not cached with the annotation**: they are pure functions of
                // the text and this corpus, they cost no model and no measurable time,
                // and a verdict written to disk would go stale the moment the reference
                // harvester or the book table changed. Without this the pane fell back
                // to rendering the model's own `SEE ALSO` prose, which resolves on
                // existence and knows nothing of what Challoner supplied — the one path
                // in the app where a nonexistent reference and an unchecked one looked
                // alike.
                report(entry.commentary, against: restored, to: continuation)
                continuation.yield(.cached(entry))
                continuation.yield(.followUps(entry.followUps))
                continuation.finish()
                return
            }

            let session = ChatSession(
                container,
                instructions: Prompts.annotatorInstructions,
                generateParameters: presets.commentary,
                additionalContext: Self.nonThinking)
            let current = PassageSession(
                key: context.key, digest: context.digest, session: session,
                passageText: Prompts.render(context.selected),
                supplied: context.crossReferences)
            passage = current

            let request = Prompts.annotationRequest(context)
            current.promptTokenCount = await Self.tokenCount(
                container: container,
                instructions: Prompts.annotatorInstructions,
                user: request)
            continuation.yield(.promptTokens(current.promptTokenCount))
            continuation.yield(.phase(.prefilling))

            do {
                var stopReason: GenerateStopReason?
                for try await item in session.streamDetails(to: request) {
                    if let chunk = item.chunk {
                        continuation.yield(.phase(.streaming))
                        current.commentary += chunk
                        continuation.yield(.commentary(chunk))
                    }
                    if let info = item.info {
                        stopReason = info.stopReason
                        current.tokensPerSecond = info.tokensPerSecond
                        continuation.yield(.stats(Self.stats(info)))
                    }
                }

                // Partial output is never cached: only a stream that reached `.info`
                // with a stop reason other than `.cancelled` produced a whole
                // annotation.
                guard stopReason != nil, stopReason != .cancelled, !Task.isCancelled
                else {
                    continuation.finish()
                    return
                }

                report(current.commentary, against: current, to: continuation)

                continuation.yield(.phase(.listingFollowUps))
                let followUps = try await requestFollowUps(
                    current, stats: { continuation.yield(.followUpStats($0)) })
                continuation.yield(.followUps(followUps))

                await cache.store(
                    CachedPassage(
                        schemaVersion: AnnotationCache.schemaVersion,
                        promptVersion: Prompts.version,
                        modelID: modelID,
                        passageDigest: current.digest,
                        commentary: current.commentary,
                        followUpsRaw: current.followUpsRaw,
                        followUps: followUps,
                        generatedAt: Date(),
                        promptTokenCount: current.promptTokenCount,
                        tokensPerSecond: current.tokensPerSecond),
                    for: current.key)
            } catch is CancellationError {
                // Stopped by the reader; whatever was written before the stop is still
                // revealed, by the fallback at the end of `ContentView.start(_:)`'s loop.
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }

            continuation.yield(.phase(.idle))
            continuation.finish()
        }

        // Cancelling the consumer has to cancel the generation. This closure is
        // `@Sendable` and runs off the main actor, so it may only cancel — it must
        // not touch the session.
        continuation.onTermination = { _ in work.cancel() }
        activeTask = work
        return stream
    }

    /// Answers a tapped question on the same session, then refreshes the ask rows.
    func answer(_ question: String) -> AsyncStream<AnnotationEvent> {
        let (stream, continuation) = AsyncStream<AnnotationEvent>.makeStream()

        let work = Task { @MainActor in
            guard let current = passage else {
                continuation.finish()
                return
            }

            current.asked.insert(Prompts.FollowUps.normalized(question))
            // Only `maxTokens` changes between turns. Mutating `kvCache`,
            // `maxKVSize`, or `kvBits` on a live session throws
            // `kvCacheConfigurationChanged`, and `instructions` is never touched
            // mid-session.
            current.session.generateParameters = presets.answer
            if current.needsHistoryPrefill {
                // A rehydrated session prefills the whole recorded transcript —
                // context, commentary and question list, so roughly 1.2-1.5k tokens
                // or about a second. Paid here, on the first tap, rather than on
                // every cache hit.
                continuation.yield(.phase(.prefilling))
                current.needsHistoryPrefill = false
            }
            continuation.yield(.phase(.answering))

            do {
                // The draft is withheld rather than streamed, because the revision
                // below can only be a revision if nothing has been shown yet. This is
                // the whole cost of the edit channel: roughly a second of silence
                // before the first visible token, paid on the answer turn only.
                var draft = ""
                for try await item in current.session.streamDetails(
                    to: Prompts.answerRequest(question))
                {
                    if let chunk = item.chunk { draft += chunk }
                    if let info = item.info {
                        continuation.yield(.stats(Self.stats(info)))
                    }
                }

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                continuation.yield(.phase(.revising))
                var answer = ""
                for try await item in current.session.streamDetails(
                    to: Prompts.answerRevision)
                {
                    if let chunk = item.chunk {
                        answer += chunk
                        continuation.yield(.answer(chunk))
                    }
                    if let info = item.info {
                        continuation.yield(.stats(Self.stats(info)))
                    }
                }

                // A revision that came back empty is worse than an unrevised draft.
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.yield(.answer(draft))
                    answer = draft
                }
                report(answer, against: current, to: continuation)

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                // Sustain the loop: ask for five, keep the first four that are not
                // already in `asked`.
                //
                // Same floor as turn 1, and for the same reason — one question the
                // reader has not seen is worth a row, and none is not. This is the path
                // where the dedupe bites: by the second answer `asked` holds every
                // question already offered, so a repetitive list is filtered down to one
                // survivor, and under the old floor of two that survivor was thrown away
                // and the block went with it.
                continuation.yield(.phase(.listingFollowUps))
                current.session.generateParameters = presets.followUp
                var fresh = Prompts.FollowUps.parse(
                    try await collect(
                        current.session.streamDetails(to: Prompts.moreFollowUpsRequest)),
                    asked: current.asked)
                // The retry still fires below two, because a fuller list is worth one
                // short generation — but it can only improve on what it found, so a lone
                // question is never spent chasing a second and coming back with nothing.
                if fresh.count < 2 {
                    let retried = Prompts.FollowUps.parse(
                        try await collect(
                            current.session.streamDetails(to: Prompts.followUpRetry)),
                        asked: current.asked)
                    if retried.count > fresh.count { fresh = retried }
                }
                if !fresh.isEmpty {
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
    private func requestFollowUps(
        _ current: PassageSession,
        stats report: (GenerationStats) -> Void = { _ in }
    ) async throws -> [String] {
        current.session.generateParameters = presets.followUp

        var raw = try await collect(
            current.session.streamDetails(to: Prompts.followUpRequest), stats: report)
        var parsed = Prompts.FollowUps.parse(raw, asked: current.asked)

        // One question the reader has not seen is a row worth showing; none is not.
        //
        // The floor used to be two — "one lonely chip looks broken" — and the cost of
        // that turned out to be paid somewhere else entirely: the Ask Anything field used
        // to live inside the same block, so discarding a lone survivor took away the
        // reader's own way in as well. The field is now unconditional, and a single
        // suggestion is better than an empty space where four used to be.
        //
        // The retry still fires below two, because a fuller list is worth one short
        // generation. It can only improve on what it found: replacing `parsed` outright
        // meant a first attempt that yielded one question could be spent chasing a second
        // and come back with none.
        if parsed.count < 2 {
            let retryRaw = try await collect(
                current.session.streamDetails(to: Prompts.followUpRetry), stats: report)
            let retried = Prompts.FollowUps.parse(retryRaw, asked: current.asked)
            if retried.count > parsed.count {
                raw = retryRaw
                parsed = retried
            }
        }

        // `raw` and `parsed` are kept together on purpose: the raw text is what
        // `rehydrate` replays into the session as the assistant's turn, so storing one
        // attempt's text beside another attempt's questions would give a resumed session
        // a history that never happened.
        current.followUpsRaw = raw
        current.followUps = parsed
        current.asked.formUnion(current.followUps.map(Prompts.FollowUps.normalized))
        return current.followUps
    }

    /// Drains a stream to a string, reporting the turn's own statistics.
    private func collect(
        _ stream: AsyncThrowingStream<Generation, Error>,
        stats report: (GenerationStats) -> Void = { _ in }
    ) async throws -> String {
        var text = ""
        for try await item in stream {
            if let chunk = item.chunk { text += chunk }
            if let info = item.info { report(Self.stats(info)) }
        }
        return text
    }

    /// Rebuilds a session from a cache entry's recorded text.
    ///
    /// `followUpsRaw` rather than the parsed list, so the rehydrated history is
    /// byte-identical to what the model actually said.
    ///
    /// The user turn is reconstructed rather than stored, and here it reconstructs
    /// **exactly**, which it could not in ShakespeareReader: everything in the prompt
    /// comes from the checked-in corpus, so there is no generated block that could have
    /// changed between the annotation and the replay. That app had to record whether its
    /// background scene summary had landed in time; Challoner's argument was written in
    /// 1750 and is not going to arrive late.
    private func rehydratedSession(
        _ container: ModelContainer, context: PassageContext, entry: CachedPassage
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: Prompts.annotatorInstructions,
            history: [
                .user(Prompts.annotationRequest(context)),
                .assistant(entry.commentary),
                .user(Prompts.followUpRequest),
                .assistant(entry.followUpsRaw),
            ],
            generateParameters: presets.answer,
            additionalContext: Self.nonThinking)
    }

    // MARK: - Cancellation

    /// In-flight work, detached from the service so it can be waited out from the
    /// task that replaces it.
    ///
    /// `@unchecked Sendable`, with a specific reason rather than to quiet the
    /// checker. `ChatSession.synchronize()` is a `@concurrent` `async` method on a
    /// non-`Sendable` class, so awaiting it from the main actor is "sending" the
    /// session off its actor. That is safe *here* because by construction this box
    /// holds the only remaining reference: `displaceActiveWork()` clears `passage`
    /// before the box exists, and `finish()` awaits the task that was using the
    /// session before touching it. The box is dropped immediately after. The
    /// alternative — skipping `synchronize()` — reintroduces the stall this path
    /// exists to remove.
    private struct DisplacedWork: @unchecked Sendable {
        let task: Task<Void, Never>?
        let session: ChatSession?

        /// Cancel, then wait, then wait again for exclusive cache access. All three
        /// steps matter. `cancel()` alone returns while the forward pass is still
        /// resident. `await task.value` alone returns while `ChatSession`'s own
        /// unstructured generation task may still be winding down and holding the
        /// cache lock — which is exactly what `synchronize()` waits for.
        func finish() async {
            task?.cancel()
            await task?.value
            await session?.synchronize()
        }
    }

    /// Takes ownership of whatever is running and clears the service's references.
    ///
    /// The session goes with it: a cancelled generation invalidates
    /// `ChatSession`'s token ledger, so a cancelled session must never be reused.
    private func displaceActiveWork() -> DisplacedWork {
        let work = DisplacedWork(task: activeTask, session: passage?.session)
        activeTask?.cancel()
        activeTask = nil
        passage = nil
        return work
    }

    /// Cancels in-flight work and discards the session. Bound to Esc.
    func stopActiveWork() async {
        await displaceActiveWork().finish()
    }

    // MARK: - Helpers

    /// Template variables that ask a model not to think at length before answering.
    ///
    /// Both keys are sent to every model because a chat template simply ignores a
    /// variable it does not reference, and the two families spell this differently:
    ///
    /// - `enable_thinking` is Qwen3's. Without it Qwen3 reasons before the first
    ///   visible token, a silent window with nothing on screen to account for it. The
    ///   pattern is `IntegrationTestHelpers.structuredToolContinuation`.
    /// - `reasoning_strength` is Muse-Glimmer's, from its own
    ///   `chat_template.jinja`: `render_reasoning()` writes "Reasoning strength:
    ///   <value>." into the system block and **defaults to `high`**. At `high` it
    ///   spent all 960 available tokens reasoning about four verses and
    ///   produced no visible answer at all, because reasoning tokens count against
    ///   `maxTokens` while being withheld from the stream.
    static let nonThinking: [String: any Sendable] = [
        "enable_thinking": false,
        "reasoning_strength": "low",
    ]

    /// The exact prompt length, without generating anything. Used by
    /// `--show-prompt`.
    func promptTokenCount(for request: String) async -> Int {
        guard let container else { return 0 }
        return await Self.tokenCount(
            container: container, instructions: Prompts.annotatorInstructions,
            user: request)
    }

    /// The exact prompt length, without generating anything.
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

enum AnnotationError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The model is not loaded yet."
        }
    }
}
