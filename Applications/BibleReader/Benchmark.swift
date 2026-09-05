// Copyright © 2026 Apple Inc.

import Foundation
import MLXLLM
import MLXLMCommon

/// `book:chapter:firstVerse-lastVerse`, in the citation's verse numbers, as the
/// `--passage` flag takes them.
///
/// Flags speak the citation's language; selections speak the array's. This is the one
/// place that translates. The grammar is simpler than ShakespeareReader's
/// `play:act.scene:first-last` because a chapter needs no act — which is also why
/// `genesis:15:6` reads like an ordinary reference with the colons rearranged.
struct PassageSpec {
    let key: ChapterKey
    let firstVerse: Int
    let lastVerse: Int

    init?(_ spec: String) {
        let parts = spec.split(separator: ":")
        guard parts.count == 3, let chapter = Int(parts[1]) else { return nil }
        let verses = parts[2].split(separator: "-")
        guard let first = Int(verses[0]) else { return nil }
        key = ChapterKey(bookID: String(parts[0]), chapter: chapter)
        firstVerse = first
        lastVerse = verses.count > 1 ? Int(verses[1]) ?? first : first
    }

    /// Resolves against a chapter, or returns nil if those verse numbers do not exist.
    ///
    /// Over `chapter.rows` with the notes in, which is the reader's default
    /// (`showsNotes`) and so is what the benchmark should measure: a passage whose notes
    /// are included is the one that costs the tokens.
    func selection(in chapter: Chapter) -> VerseSelection? {
        guard
            let start = chapter.rows.firstIndex(where: {
                $0.isVerse && $0.number == firstVerse
            }),
            let end = chapter.rows.lastIndex(where: {
                $0.isVerse && $0.number == lastVerse
            }),
            start <= end
        else { return nil }
        return VerseSelection(anchor: start, head: end)
    }
}

/// Passages the headless modes walk.
///
/// Chosen to span what actually matters in this corpus rather than to sample it evenly.
/// Every entry is here for a named reason, and several are here because they are the
/// cases most likely to go wrong.
enum SamplePassages {
    static let specs = [
        // Creation, cold start.
        "genesis:1:1-5",
        // The Protoevangelium. A translation crux — "she shall crush thy head" — with a
        // heavy Challoner note on exactly the disputed word.
        "genesis:3:14-15",
        // One verse, and the Romans/Galatians cross-reference case.
        "genesis:15:6",
        // The Decalogue: a long selection, and Catholic numbering of the commandments.
        "exodus:20:1-17",
        // The shepherd psalm under Vulgate numbering. Here on purpose: this is DRB 22,
        // and a model that "corrects" it to 23 has done the one thing the prompt forbids.
        "psalms:22:1-6",
        // An ALEPH stanza: a section heading and a note inside the selected range.
        "psalms:118:1-8",
        // Poetry rendered as prose — the honest failure case, and what the typography
        // has to carry on its own.
        "job:38:1-7",
        // "A virgin shall conceive", with a heavy Challoner note.
        "isaias:7:14",
        // Deuterocanonical: zero TSK coverage even once the dataset lands, so this is
        // the fallback path.
        "wisdom:2:12-20",
        // Susanna: a chapter the Protestant canon does not have at all.
        "daniel:13:1-9",
        // "Thou art Peter" — the dogmatically loaded case, and the one where a 4B model
        // drifts hardest toward the Protestant commonplace.
        "matthew:16:13-19",
        // The Prologue.
        "john:1:1-5",
        // Deuterocanonical narrative, no cross-references, plain prose.
        "1-machabees:1:1-9",
    ]
}

/// `--benchmark`: runs the real annotation path and reports what it cost.
///
/// This exists because the app's latency budget is an assumption until it is measured,
/// and a prompt edit can quietly spend it. It drives `AnnotationService` exactly as the
/// UI does — same context builder, same prompts, same session reuse — so the numbers are
/// the ones a reader gets, not a synthetic approximation.
///
/// The budget it is measured against is ShakespeareReader's: 864-1,418 prompt tokens and
/// 0.74 s to first token. This prompt adds a preface, an argument, notes and
/// cross-reference verse texts, so a regression is expected and the question is how much.
@MainActor
enum Benchmark {

    private struct Row {
        let citation: String
        var promptTokens = 0
        var timeToFirstToken: TimeInterval = 0
        var promptTokensPerSecond: Double = 0
        var decodeTokensPerSecond: Double = 0
        var followUpPromptTokens = 0
        var followUpCount = 0
        var peakBytes = 0
        var commentaryWords = 0
        /// Which of the four sections the model actually produced. The number that says
        /// whether the format is holding, and the reason this table has a column
        /// ShakespeareReader's does not.
        var sections: [Prompts.Section] = []
        var referenceVerdicts: [CheckedReference.Verdict: Int] = [:]
        var unverifiedCitations = 0
    }

    static func run(options: AppOptions) async -> Bool {
        guard let bible = try? CorpusLoader.load() else {
            print("could not load the corpus")
            return false
        }
        let table = BookTable(bible)
        let store = CrossReferenceStore(bible: bible, table: table)

        let service = AnnotationService(
            modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
            greedy: options.greedy)
        service.ground(AnnotationService.Grounding(bible: bible, table: table))
        print("loading \(service.modelID)…")
        await service.load()
        guard service.isReady else {
            print("the model did not load")
            return false
        }

        var rows: [Row] = []
        let specs = options.passages.isEmpty ? SamplePassages.specs : options.passages
        for spec in specs {
            guard
                let context = context(spec, bible: bible, store: store)
            else {
                print("could not resolve \(spec)")
                return false
            }

            // `ignoringCache: true` so a second run measures the model rather than the
            // disk.
            var row = Row(citation: context.citation)
            let started = Date()
            var commentary = ""

            for await event in await service.annotate(context, ignoringCache: true) {
                switch event {
                case .promptTokens(let count):
                    row.promptTokens = count
                case .commentary(let chunk):
                    if commentary.isEmpty {
                        row.timeToFirstToken = Date().timeIntervalSince(started)
                    }
                    commentary += chunk
                case .stats(let stats):
                    row.promptTokensPerSecond = stats.promptTokensPerSecond
                    row.decodeTokensPerSecond = stats.tokensPerSecond
                    row.peakBytes = stats.peakBytes
                    print(
                        "  [turn 1] generated \(stats.generationTokenCount) tokens, "
                            + "stop: \(stats.stopReason)")
                case .followUpStats(let stats):
                    row.followUpPromptTokens = stats.promptTokenCount
                case .followUps(let questions):
                    row.followUpCount = questions.count
                case .references(let checked):
                    for verdict in checked.map(\.verdict) {
                        row.referenceVerdicts[verdict, default: 0] += 1
                    }
                case .unverifiedCitations(let citations):
                    row.unverifiedCitations = citations.count
                default:
                    break
                }
            }

            row.commentaryWords = commentary.split(whereSeparator: \.isWhitespace).count
            row.sections = Annotation.parseSections(commentary).present
            rows.append(row)

            print(String(repeating: "=", count: 78))
            print(row.citation)
            print(String(repeating: "-", count: 78))
            print(commentary.trimmingCharacters(in: .whitespacesAndNewlines))
            print(
                String(
                    format: """

                        %d prompt tok · %.0f tok/s prefill · %.2fs to first token · \
                        %.1f tok/s decode · %d words · %d/4 sections · \
                        %d follow-ups · turn-2 prompt %d tok · %.2f GB peak
                        """,
                    row.promptTokens, row.promptTokensPerSecond, row.timeToFirstToken,
                    row.decodeTokensPerSecond, row.commentaryWords, row.sections.count,
                    row.followUpCount, row.followUpPromptTokens,
                    Double(row.peakBytes) / 1_073_741_824))
            if row.sections.count < Prompts.Section.allCases.count {
                let missing = Prompts.Section.allCases.filter { !row.sections.contains($0) }
                print("  missing: \(missing.map(\.rawValue).joined(separator: ", "))")
            }
            print()
        }

        summarize(rows)
        if let spec = specs.first {
            await checkCache(spec, bible: bible, store: store, service: service)
        }
        return !rows.isEmpty
    }

    static func context(_ spec: String, bible: Bible, store: CrossReferenceStore)
        -> PassageContext?
    {
        guard let parsed = PassageSpec(spec),
            let book = bible.book(parsed.key.bookID),
            let chapter = bible.chapter(parsed.key),
            let selection = parsed.selection(in: chapter)
        else { return nil }
        return PassageContext.build(
            book: book, key: parsed.key, chapter: chapter, rows: chapter.rows,
            selection: selection, crossReferences: store)
    }

    /// The path the timing table cannot show: a cache hit.
    ///
    /// Easy to break in a way that still looks fine — a cache that never hits just costs
    /// a regeneration. There is no synopsis half to this any more: Challoner's argument
    /// is read out of the JSON, so there is nothing to prewarm and nothing to wait for.
    private static func checkCache(
        _ spec: String, bible: Bible, store: CrossReferenceStore,
        service: AnnotationService
    ) async {
        guard let context = context(spec, bible: bible, store: store) else { return }

        print(String(repeating: "=", count: 78))

        let started = Date()
        var servedFromCache = false
        var questions = 0
        for await event in await service.annotate(context) {
            if case .cached = event { servedFromCache = true }
            if case .followUps(let list) = event { questions = list.count }
        }
        print(
            String(
                format: "cache: %@ in %.0f ms, %d follow-ups rehydrated",
                servedFromCache ? "hit" : "MISS",
                Date().timeIntervalSince(started) * 1000, questions))
    }

    private static func summarize(_ rows: [Row]) {
        print(String(repeating: "=", count: 78))
        print(
            "| passage | prompt tok | prefill tok/s | TTFT | decode tok/s | words | "
                + "sections |")
        print("|---|---|---|---|---|---|---|")
        for row in rows {
            print(
                String(
                    format: "| %@ | %d | %.0f | %.2f s | %.1f | %d | %d/4 |",
                    row.citation.replacingOccurrences(
                        of: " · " + Citation.edition, with: ""),
                    row.promptTokens, row.promptTokensPerSecond, row.timeToFirstToken,
                    row.decodeTokensPerSecond, row.commentaryWords, row.sections.count))
        }

        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        print()
        print(
            String(
                format: """
                    mean: %.0f prompt tok · %.0f tok/s prefill · %.2fs to first token · \
                    %.1f tok/s decode · %.0f words
                    """,
                mean(rows.map { Double($0.promptTokens) }),
                mean(rows.map(\.promptTokensPerSecond)),
                mean(rows.map(\.timeToFirstToken)),
                mean(rows.map(\.decodeTokensPerSecond)),
                mean(rows.map { Double($0.commentaryWords) })))

        // Per-section completeness, which is the whole reason the four-marker format was
        // chosen over one paragraph: a section the model silently dropped is invisible in
        // the prose and obvious here.
        for section in Prompts.Section.allCases {
            let present = rows.count { $0.sections.contains(section) }
            print("  \(section.rawValue): \(present)/\(rows.count)")
        }

        let verdicts = rows.reduce(into: [CheckedReference.Verdict: Int]()) {
            for (verdict, count) in $1.referenceVerdicts { $0[verdict, default: 0] += count }
        }
        if !verdicts.isEmpty {
            let parts = [CheckedReference.Verdict.ok, .ungiven, .nonexistent]
                .compactMap { verdict -> String? in
                    guard let count = verdicts[verdict] else { return nil }
                    return "\(count) \(verdict.rawValue)"
                }
            print("  references: " + parts.joined(separator: " · "))
        }
        let citations = rows.reduce(0) { $0 + $1.unverifiedCitations }
        if citations > 0 {
            print("  unverified patristic/magisterial citations: \(citations)")
        }

        print(
            String(
                format: """
                    turn 2 prefills %.0f tokens on average against a %.0f-token turn 1 \
                    — the KV cache is being reused across turns
                    """,
                mean(rows.map { Double($0.followUpPromptTokens) }),
                mean(rows.map { Double($0.promptTokens) })))
        let peak = rows.map(\.peakBytes).max() ?? 0
        print(String(format: "peak memory %.2f GB", Double(peak) / 1_073_741_824))
    }
}

/// `--show-prompt`: the assembled prompt and its exact token count, per passage.
///
/// The flag Phase 3 exists to run. A blown token budget is much cheaper to fix before the
/// cross-reference dataset lands than after, and this is the only thing that measures it
/// without generating anything.
@MainActor
enum PromptDump {

    static func run(options: AppOptions) async -> Bool {
        guard let bible = try? CorpusLoader.load() else {
            print("could not load the corpus")
            return false
        }
        let store = CrossReferenceStore(bible: bible, table: BookTable(bible))

        let service = AnnotationService(
            modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
            greedy: options.greedy)
        await service.load()
        guard service.isReady else {
            print("the model did not load; cannot report exact token counts")
            return false
        }

        let specs = options.passages.isEmpty ? SamplePassages.specs : options.passages
        var counted: [(String, Int)] = []

        for spec in specs {
            guard let context = Benchmark.context(spec, bible: bible, store: store) else {
                print("could not resolve \(spec)")
                return false
            }

            let request = Prompts.annotationRequest(context)
            let tokens = await service.promptTokenCount(for: request)
            counted.append((context.citation, tokens))

            print(String(repeating: "=", count: 78))
            print("\(spec) \u{2192} \(context.citation) — \(tokens) prompt tokens")
            print(String(repeating: "-", count: 78))
            print(request)
            print()
        }

        print(String(repeating: "=", count: 78))
        print("prompt token counts (system instructions and chat template included)")
        for (citation, tokens) in counted {
            print(String(format: "  %5d  %@", tokens, citation))
        }
        let counts = counted.map(\.1)
        if let low = counts.min(), let high = counts.max(), !counts.isEmpty {
            print("  min \(low) · max \(high) · mean \(counts.reduce(0, +) / counts.count)")
        }
        return true
    }
}
