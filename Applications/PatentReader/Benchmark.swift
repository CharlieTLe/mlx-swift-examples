// Copyright © 2026 Apple Inc.

import Foundation
import MLXLLM
import MLXLMCommon

/// Questions the headless modes walk, chosen to span the range that matters.
///
/// `SamplePassages` next door picked passages that were structurally different — a cold
/// scene opening, the longest scene, prose, a chorus. These pick questions that are
/// *retrievally* different, because retrieval is the half of this app that can quietly
/// stop working:
///
/// - one answerable from a single obvious paragraph, which is the case everything should
///   get right;
/// - one answerable only from the claims, which is what the parent-prepending in
///   `Chunker.resolvedText` exists for;
/// - a bare reference numeral, which is the lexical leg's reason to exist and which
///   dense retrieval alone fumbles;
/// - a term-of-art question, where `comprising` and `consisting of` are different
///   scopes;
/// - a question about what a claim covers rather than what the description says, which
///   is the distinction the instructions ask the model to keep;
/// - **and one the library cannot answer.** That last is the most important row here.
///   The right answer is one sentence and zero citations, and a 4B model will usually
///   cite something anyway. It is the honest measure of the whole design, so it is in
///   the sample rather than in a note somewhere.
enum SampleQuestions {
    static let all = [
        "how is the internal matrix formed?",
        "what does claim 7 require that claim 1 does not?",
        "what is 100?",
        "is the heat sink claimed as comprising a matrix, or consisting of one?",
        "does the patent claim the missile, or only the heat sink?",
        "what does this patent say about lithium-ion battery chemistry?",
    ]
}

/// `--benchmark`: runs the real answer path and reports what it cost.
///
/// This exists because the app's latency budget was an assumption until it was measured,
/// and a prompt edit or a retrieval change can quietly spend it. It drives `AnswerService`
/// exactly as the UI does — same retriever, same context builder, same prompts, same
/// session reuse — so the numbers are the ones a reader gets, not a synthetic
/// approximation.
///
/// Beyond the latency columns it reports **citations by verdict**, which is the number
/// this app is actually about: a prompt change that speeds things up and doubles the
/// invented citations is a regression, and the timing table alone would call it a win.
@MainActor
enum Benchmark {

    private struct Row {
        let question: String
        var retrievalMilliseconds: Double = 0
        var chunks = 0
        var promptTokens = 0
        var timeToFirstToken: TimeInterval = 0
        var promptTokensPerSecond: Double = 0
        var decodeTokensPerSecond: Double = 0
        var peakBytes = 0
        var words = 0
        var supported = 0
        var unretrieved = 0
        var nonexistent = 0
        var unsupportedQuotes = 0
        var lexicalOnly = false
    }

    static func run(options: AppOptions) async -> Bool {
        let library = LibraryService()
        library.load()
        guard !library.patents.isEmpty else {
            print(
                "the library is empty. Import a patent first — the benchmark runs against "
                    + "whatever is in ~/Library/Application Support/PatentReader/Library.")
            return false
        }
        print("library: \(library.patents.count) patents, \(library.index.chunks.count) chunks")

        let service = AnswerService(
            modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
            greedy: options.greedy)
        print("loading \(service.modelID)…")
        await service.load()
        guard service.isReady else {
            print("the model did not load")
            return false
        }

        let scope = PromptDump.scope(options, in: library)
        var rows: [Row] = []

        for question in options.questions.isEmpty ? SampleQuestions.all : options.questions {
            var row = Row(question: question)
            var scanner: CitationScanner?
            var text = ""
            let started = Date()
            var retrievalStarted = Date()

            // `ignoringCache: true` so a second run measures the model rather than the
            // disk.
            for await event in await service.answer(
                question: question, library: library, scope: scope, ignoringCache: true)
            {
                switch event {
                case .phase(.retrieving):
                    retrievalStarted = Date()
                case .retrieved(let chunks):
                    row.retrievalMilliseconds =
                        Date().timeIntervalSince(retrievalStarted) * 1000
                    row.chunks = chunks.count
                    row.lexicalOnly = service.context?.isLexicalOnly ?? false
                    if let context = service.context {
                        scanner = CitationScanner(
                            context: context, library: library.patents)
                    }
                case .promptTokens(let count):
                    row.promptTokens = count
                case .answer(let chunk):
                    if text.isEmpty {
                        row.timeToFirstToken = Date().timeIntervalSince(started)
                    }
                    text += chunk
                    scanner?.consume(chunk)
                case .stats(let stats):
                    row.promptTokensPerSecond = stats.promptTokensPerSecond
                    row.decodeTokensPerSecond = stats.tokensPerSecond
                    row.peakBytes = stats.peakBytes
                case .unsupportedQuotes(let spans):
                    row.unsupportedQuotes = spans.count
                case .failed(let message):
                    print("  FAILED: \(message)")
                default:
                    break
                }
            }

            scanner?.finish()
            let tally = CitationCheck.tally(scanner?.runs ?? [])
            row.supported = tally[.supported]?.count ?? 0
            row.unretrieved = tally[.unretrieved]?.count ?? 0
            row.nonexistent = tally[.nonexistent]?.count ?? 0
            row.words = text.split(whereSeparator: \.isWhitespace).count
            rows.append(row)

            print(String(repeating: "=", count: 78))
            print(question + (row.lexicalOnly ? "  (lexical only)" : ""))
            print(String(repeating: "-", count: 78))
            print(text.trimmingCharacters(in: .whitespacesAndNewlines))
            print(
                String(
                    format: """

                        %d chunks in %.0f ms · %d prompt tok · %.0f tok/s prefill · \
                        %.2fs to first token · %.1f tok/s decode · %d words
                        citations: %d supported · %d unretrieved · %d nonexistent · \
                        %d unsupported quotes · %.2f GB peak
                        """,
                    row.chunks, row.retrievalMilliseconds, row.promptTokens,
                    row.promptTokensPerSecond, row.timeToFirstToken,
                    row.decodeTokensPerSecond, row.words,
                    row.supported, row.unretrieved, row.nonexistent, row.unsupportedQuotes,
                    Double(row.peakBytes) / 1_073_741_824))
            print()
        }

        summarize(rows)
        return !rows.isEmpty
    }

    private static func summarize(_ rows: [Row]) {
        print(String(repeating: "=", count: 78))
        print(
            "| question | chunks | retrieval | prompt tok | TTFT | decode tok/s | words | "
                + "cited ✓/?/✗ |")
        print("|---|---|---|---|---|---|---|---|")
        for row in rows {
            print(
                String(
                    format: "| %@ | %d | %.0f ms | %d | %.2f s | %.1f | %d | %d/%d/%d |",
                    row.question, row.chunks, row.retrievalMilliseconds, row.promptTokens,
                    row.timeToFirstToken, row.decodeTokensPerSecond, row.words,
                    row.supported, row.unretrieved, row.nonexistent))
        }

        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        print()
        print(
            String(
                format: """
                    mean: %.0f ms retrieval · %.0f prompt tok · %.0f tok/s prefill · \
                    %.2fs to first token · %.1f tok/s decode · %.0f words
                    """,
                mean(rows.map(\.retrievalMilliseconds)),
                mean(rows.map { Double($0.promptTokens) }),
                mean(rows.map(\.promptTokensPerSecond)),
                mean(rows.map(\.timeToFirstToken)),
                mean(rows.map(\.decodeTokensPerSecond)),
                mean(rows.map { Double($0.words) })))

        // The citation totals, last and on their own line, because they are the number
        // this app is about. A change that halves the latency and doubles the last column
        // is a regression, and the timing table above would call it a win.
        let supported = rows.reduce(0) { $0 + $1.supported }
        let unretrieved = rows.reduce(0) { $0 + $1.unretrieved }
        let nonexistent = rows.reduce(0) { $0 + $1.nonexistent }
        let total = supported + unretrieved + nonexistent
        print(
            String(
                format: """
                    citations: %d total — %d supported (%.0f%%), %d real but unretrieved, \
                    %d invented
                    """,
                total, supported,
                total > 0 ? Double(supported) / Double(total) * 100 : 0,
                unretrieved, nonexistent))
        print(
            "note: `supported` means the model was shown the paragraph, never that the "
                + "paragraph says what the sentence claims. Nothing here measures that.")
        let peak = rows.map(\.peakBytes).max() ?? 0
        print(String(format: "peak memory %.2f GB", Double(peak) / 1_073_741_824))
    }
}

/// `--summarize --patent US10123456B2 --paragraph 19 --paragraph 20`, the summary path's
/// terminal probe.
///
/// **What it cannot cover is the one thing it exists beside.** A summary starts from a
/// `PDFSelection`, and a terminal has no drag — so the named passages stand in for what
/// `PatentPDFMap.targets(spanning:)` would have resolved, and everything downstream of that
/// is the real path: the same context builder, the same prompt, the same session, the same
/// citation verdicts. The selection-to-passages leg is `--anchor`'s neighbour on the manual
/// checklist for the same reason `--anchor` exists at all: `--selftest` is PDFKit-free by
/// policy and there is no PDF in this repository.
///
/// With `--show-prompt` it prints the assembled prompt and its exact token count and stops,
/// which is how a change to `Prompts.summaryRequest` gets read before it is generated from.
@MainActor
enum SummaryProbe {

    static func run(options: AppOptions) async -> Bool {
        let library = LibraryService()
        library.load()

        guard let spelling = options.patents.first,
            let requested = PatentNumberParser.parse(spelling)
        else {
            print("--summarize needs a --patent")
            return false
        }
        guard
            let patent = library.patents.first(where: {
                $0.key.country == requested.country && $0.key.serial == requested.serial
            })
        else {
            print("\(requested.display) is not in the library — fetch it first with --fetch")
            return false
        }

        let targets =
            options.paragraphs.map {
                CitationTarget.paragraph(ParagraphKey(patent: patent.key, number: $0))
            }
            + options.claims.map {
                CitationTarget.claim(ClaimKey(patent: patent.key, number: $0))
            }
        guard !targets.isEmpty else {
            print(
                "--summarize needs a --paragraph or a --claim, which stands in for the "
                    + "reader's selection")
            return false
        }

        // The refusal the app makes, made here too: a summary with nothing citable under it
        // is one nobody can check against the document.
        guard let context = AnswerContext.selection(targets, in: patent) else {
            print("none of those passages exist in \(patent.key.display)")
            return false
        }
        let span =
            Citation.spanLabel(
                context.passages.map(\.target), numbering: patent.numbering) ?? "?"
        print(
            "\(patent.key.display) — summarizing \(context.passages.count) passage(s): \(span)")
        if context.passages.count < targets.count {
            // Said rather than silently dropped, which is the standing rule: a target that
            // does not exist, and the cap, both land here.
            print(
                "  note: \(targets.count - context.passages.count) of \(targets.count) "
                    + "requested passages were dropped (nonexistent, or over the "
                    + "\(AnswerContext.maximumPassages)-passage cap)")
        }

        let service = AnswerService(
            modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
            greedy: options.greedy)
        print("loading \(service.modelID)…")
        await service.load()
        guard service.isReady else {
            print("the model did not load")
            return false
        }

        let request = Prompts.summaryRequest(context)
        if options.showPrompt {
            print(String(repeating: "-", count: 78))
            print(request)
            print(String(repeating: "-", count: 78))
            print("\(await service.promptTokenCount(for: request)) prompt tokens")
            return true
        }

        var scanner = CitationScanner(context: context, library: library.patents)
        var text = ""
        let started = Date()
        var timeToFirstToken: TimeInterval = 0
        var promptTokens = 0
        var decodeTokensPerSecond = 0.0
        var ok = true

        // `ignoringCache: true` so a second run measures the model rather than the disk.
        for await event in await service.summarize(targets, in: patent, ignoringCache: true) {
            switch event {
            case .summarizing:
                // The scanner is rebuilt against the service's own context, so what the
                // verdicts are decided against is exactly what the model was shown.
                if let live = service.context {
                    scanner = CitationScanner(context: live, library: library.patents)
                }
            case .promptTokens(let count):
                promptTokens = count
            case .answer(let chunk):
                if text.isEmpty { timeToFirstToken = Date().timeIntervalSince(started) }
                text += chunk
                scanner.consume(chunk)
            case .stats(let stats):
                decodeTokensPerSecond = stats.tokensPerSecond
            case .unsupportedQuotes(let spans):
                for span in spans { print("  unsupported quotation: \(span)") }
            case .failed(let message):
                print("  FAILED: \(message)")
                ok = false
            default:
                break
            }
        }
        scanner.finish()

        print(String(repeating: "-", count: 78))
        print(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let tally = CitationCheck.tally(scanner.runs)
        print(
            String(
                format: """

                    %d prompt tok · %.2fs to first token · %.1f tok/s decode · %d words
                    citations: %d supported · %d unretrieved · %d nonexistent
                    """,
                promptTokens, timeToFirstToken, decodeTokensPerSecond,
                text.split(whereSeparator: \.isWhitespace).count,
                tally[.supported]?.count ?? 0, tally[.unretrieved]?.count ?? 0,
                tally[.nonexistent]?.count ?? 0))
        return ok
    }
}
