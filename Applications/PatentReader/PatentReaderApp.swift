// Copyright © 2026 Apple Inc.

import Combine
import Dispatch
import Foundation
import MLX
import SwiftUI

#if !os(macOS)
    import UIKit
#endif

/// Command-line options.
///
/// The app normally launches with no arguments. These flags exist for the work that is
/// easier from a terminal than through the UI: inspecting the assembled prompt, pinning
/// sampling for prompt A/B comparisons, and the model-free self test.
struct AppOptions: Sendable {
    /// Run the model-free assertions and exit. No download, no network, no GPU.
    var runSelfTest = false
    /// Evaluate one tiny array on the GPU and exit. No download, no network.
    var runMetalCheck = false
    /// Print the assembled prompt and its exact token count for a sample of questions,
    /// then exit. Needs the tokenizer, so it does load the model.
    var showPrompt = false
    /// Run the real answer path over a sample of questions and report the latency
    /// numbers, then exit. This is how the README's table is produced, and how a prompt
    /// change is checked against the token budget.
    var benchmark = false
    /// `temperature: 0, seed: 0` everywhere, so two runs of the same prompt are
    /// byte-identical and a prompt edit is the only variable.
    var greedy = false
    /// Show the model capsule, the load check and the latency numbers for this launch,
    /// without persisting the preference.
    var diagnostics = false
    /// Overrides the answering model, e.g. `--model mlx-community/Qwen3-8B-4bit`.
    var modelID: String?
    /// Overrides the embedding model.
    var embedderID: String?
    /// Scopes `--show-prompt` and `--benchmark` to one patent, as `US10123456B2`, and
    /// names the patent `--paragraph` and `--claim` address.
    var patents: [String] = []
    /// Fetch these numbers into the library and exit. The only automated way to run the
    /// **live** parse — `--selftest` reads checked-in fixtures, so it cannot see markup
    /// that changed today.
    var fetch: [String] = []
    /// Anchor these numbers' stored PDFs and print how well it went, then exit. The probe
    /// harness for the one thing `--selftest` cannot reach — see `LibraryCommands.anchor`.
    var anchor: [String] = []
    /// Questions for `--show-prompt` and `--benchmark`. Empty means the built-in sample.
    var questions: [String] = []
    /// A paragraph or claim to print, for checking the citation resolver from a
    /// terminal: `--patent US10123456B2 --paragraph 42`.
    var paragraph: Int?
    var claim: Int?
    /// Summarize the named passages and exit — the terminal stand-in for a selection, since
    /// a drag is the one part of that path a terminal has none of. With `--show-prompt` it
    /// prints the assembled summary prompt and stops.
    var summarize = false
    /// Every `--paragraph` and `--claim`, in the order given, for `--summarize`, which
    /// stands in for a selection that can cover several passages. The two singular fields
    /// above keep the *last* of each, which is what `--patent --paragraph` prints, so
    /// nothing that reads them changes behaviour.
    var paragraphs: [Int] = []
    var claims: [Int] = []

    static func parse(_ arguments: [String]) -> AppOptions {
        var options = AppOptions()
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--selftest": options.runSelfTest = true
            case "--metal-check": options.runMetalCheck = true
            case "--show-prompt": options.showPrompt = true
            case "--benchmark": options.benchmark = true
            case "--greedy": options.greedy = true
            case "--diagnostics": options.diagnostics = true
            case "--summarize": options.summarize = true
            case "--model": options.modelID = rest.next()
            case "--embedder": options.embedderID = rest.next()
            case "--patent": options.patents.append(rest.next() ?? "")
            case "--fetch": options.fetch.append(rest.next() ?? "")
            case "--anchor": options.anchor.append(rest.next() ?? "")
            case "--ask": options.questions.append(rest.next() ?? "")
            case "--paragraph":
                let number = rest.next().flatMap(Int.init)
                options.paragraph = number
                if let number { options.paragraphs.append(number) }
            case "--claim":
                let number = rest.next().flatMap(Int.init)
                options.claim = number
                if let number { options.claims.append(number) }
            default: break
            }
        }
        return options
    }

    /// Whether `--patent` was given with something to print.
    ///
    /// Not when `--summarize` is also set: there the paragraph names the passage to
    /// summarize rather than one to print, and printing it first would bury the summary
    /// under the whole passage.
    var showsPassage: Bool {
        !patents.isEmpty && (paragraph != nil || claim != nil) && !summarize
    }
}

/// The one-line GPU check behind `--metal-check`.
///
/// `--selftest` parses fixtures and renders prompts, and never touches the GPU, so it
/// passes on a build whose Metal kernels were never compiled. mlx-swift's `.metal`
/// sources become a `default.metallib` inside `mlx-swift_Cmlx.bundle`, which is looked up
/// beside the running executable and only on first GPU use, where a miss surfaces from
/// C++ as "Failed to load the default metallib": long after launch, in the middle of
/// answering a question. Evaluating one array proves the kernels are there before a
/// reader finds out the slow way, which is what makes this worth a flag of its own.
enum MetalCheck {
    static func run() -> Bool {
        let sum = MLXArray([1, 2, 3]).sum(stream: .gpu)
        eval(sum)
        guard sum.item(Int32.self) == 6 else {
            FileHandle.standardError.write(Data("metal: wrong result\n".utf8))
            return false
        }
        print("metal: ok")
        return true
    }
}

/// Separate from the `App` so the headless flags can run before SwiftUI starts.
///
/// `App` supplies its own `static main()`, and there is no way to call that default
/// implementation from an override of it. Owning the entry point and forwarding to
/// `PatentReaderApp.main()` is the way to get a `--selftest` that exits without ever
/// opening a window.
@main
enum EntryPoint {
    /// `@MainActor` so it can hand the parsed options to the `App`, and because this is
    /// the main thread at process start either way.
    @MainActor
    static func main() {
        let options = AppOptions.parse(Array(CommandLine.arguments.dropFirst()))

        // The headless flags are terminal work and macOS-only. `dispatchMain()` and
        // `exit()` have no place in an iOS app, where an app that exits itself on launch
        // reads to the system as a crash, and there is no terminal to print a prompt dump
        // or a benchmark table to. iOS parses the arguments and ignores them, which
        // leaves `--diagnostics` and `--model` working under `xcrun simctl launch`.
        #if os(macOS)
            if options.runSelfTest {
                // Entirely synchronous and off the main actor, so it can run right here.
                exit(SelfTest.run() ? 0 : 1)
            }

            if options.runMetalCheck {
                exit(MetalCheck.run() ? 0 : 1)
            }

            // `--fetch` and `--patent … --paragraph N` need no model, but they do need
            // the main actor: the library is `@MainActor` because the app's views own it.
            // Same `dispatchMain()` shape as the two below and for the same reason —
            // blocking the main thread on a semaphore would deadlock against the
            // main-actor executor.
            if !options.fetch.isEmpty || options.showsPassage || !options.anchor.isEmpty {
                Task {
                    var ok = true
                    if !options.fetch.isEmpty {
                        ok = await LibraryCommands.fetch(options.fetch)
                    }
                    if ok, options.showsPassage {
                        ok = LibraryCommands.show(options)
                    }
                    if ok, !options.anchor.isEmpty {
                        ok = await LibraryCommands.anchor(options.anchor)
                    }
                    exit(ok ? 0 : 1)
                }
                dispatchMain()
            }

            if options.showPrompt || options.benchmark || options.summarize {
                // The prompt dump needs the main actor (it drives `AnswerService`), so
                // the main thread has to keep servicing it rather than block on a
                // semaphore — that would deadlock against the main-actor executor.
                // `dispatchMain()` parks the main thread on the main queue and never
                // returns; the task exits the process itself.
                Task {
                    let ok: Bool
                    if options.summarize {
                        ok = await SummaryProbe.run(options: options)
                    } else if options.benchmark {
                        ok = await Benchmark.run(options: options)
                    } else {
                        ok = await PromptDump.run(options: options)
                    }
                    exit(ok ? 0 : 1)
                }
                dispatchMain()
            }
        #endif

        PatentReaderApp.options = options
        PatentReaderApp.main()
    }
}

struct PatentReaderApp: App {
    /// Set by `EntryPoint` before SwiftUI starts. `static` because `App` is initialized
    /// by the framework, so there is no initializer to pass through.
    @MainActor static var options = AppOptions()

    var body: some SwiftUI.Scene {
        WindowGroup("Patent Reader") {
            ContentView(options: Self.options)
                // The three panes need 240 + 460 + 400 = 1100 with all of them open, so
                // the floor has to clear that or the document gets pushed under its own
                // minimum. AppKit clamps an autosaved frame up to a raised minimum on the
                // next launch, so a window left narrower than this widens once and holds.
                //
                // Wider than ShakespeareReader's 1080 for one reason: a patent's measure
                // has to hold a claim, and a claim is a single sentence four hundred
                // words long with a five-level hanging indent under it.
                #if os(macOS)
                    .frame(minWidth: 1100, minHeight: 640)
                #else
                    // Two models' working set is a large fraction of what iOS will let
                    // one app hold, and MLX's buffer-reuse pool is the part of it that is
                    // safe to give back: the weights are still needed, cached scratch
                    // buffers are not. Dropping them on a warning is what makes the
                    // difference between the system reclaiming memory and jetsam killing
                    // the app mid-answer.
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.didReceiveMemoryWarningNotification)
                    ) { _ in
                        guard hasMLXDevice else { return }
                        Memory.clearCache()
                    }
                #endif
        }
    }
}
