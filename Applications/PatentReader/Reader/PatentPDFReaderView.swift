// Copyright © 2026 Apple Inc.

import PDFKit
import SwiftUI

/// The patent, as the office published it. The only reader there is.
///
/// There was a second one until recently: a list of parsed rows with paragraph numbers in
/// the margin and a claim tree. The parse is still here and still does everything it ever
/// did — it builds the index, fills the prompt, and names every citation — but it was
/// always a *reading* of the document, and this is the document. A figure, a table, a
/// chemical structure, a signature block and the typesetting of the printed grant are all
/// things the parse cannot carry, and "is `[0042]` really `[0042]`?" is a question only the
/// original answers.
///
/// The one thing the parsed view could do that this could not was land a citation on a
/// passage, and that turned out to be false: see `PassageAnchor` and `PatentPDFMap`.
///
/// **What the reader's keys do here, and why each one was decided rather than inherited.**
///
/// - **⌘F, ⌘G, ⇧⌘G** are the find bar, over `PDFDocument.findString`. `PDFView` ships no
///   find UI on either platform — Preview's find bar is Preview's own code over the same
///   call — so this app builds one, out of the same `FindBar` the text reader used, byte for
///   byte. See `PatentPDFFind` for why finding does not select.
/// - **⇧⌘C** copies the selection with its citation. It resolves a `PDFSelection` back to
///   the passages it spans through `PatentPDFMap.targets(spanning:)`, which compares
///   ordinals and never characters — so hyphenation and OCR damage cannot break it.
/// - **⌘C** is PDFKit's own, and copies the selected text uncited. Left alone deliberately:
///   ⌘C is what a reader presses to copy the phrase they just dragged out, and ⇧⌘C is the
///   one that means "with the citation".
/// - **Arrows, space, page up and down** are PDFKit's scrolling, which is why there is no
///   `.focusable()` on the host below: `PDFView`'s document view takes first responder
///   itself, and a SwiftUI focus item over it would compete for the keys.
/// - **Esc** is a ladder — the find bar, then the selection, then `onCancel` — through a
///   `.keyboardShortcut(.escape)` button rather than `.onExitCommand`, for the first-
///   responder reason just above.
///
/// A citation chip lands here as well as in the text: see `PatentPDFMap`, which is what
/// resolves `[0042]` against a document that carries no paragraph index of its own.
@MainActor
struct PatentPDFReaderView: View {
    let patent: Patent
    let pdf: PatentPDFService
    /// What the answer found, what it cited, and where the reader was last sent. Built by
    /// `ContentView`, which is the only place that has all three.
    let plan: HighlightPlan

    /// Bumped to raise the find bar and put the keyboard in it. A counter for
    /// `AnswerPaneView.focusRequest`'s reason — the request is an event, and a `Bool` would
    /// be a state that has to be written back to false before it can fire again.
    ///
    /// ⌘F is handled here rather than by the caller, because the state it acts on is here.
    /// This exists for the affordances that are not a key: the macOS header button, and the
    /// iOS overflow row, where there is no ⌘F to press.
    let findRequest: Int

    /// ⇧⌘C's counterpart for a phone, where there is no ⇧⌘C. Same counter idiom.
    let copyRequest: Int

    /// Whether the reader has text selected here, reported upward on every transition.
    ///
    /// `ContentView` needs it for two things it owns: scoping a question to the open patent,
    /// and enabling the iOS overflow's copy row. A `Bool` and not the selection, because the
    /// selection is a live reference into a `PDFDocument` and has no business leaving the
    /// view layer.
    let onSelection: (Bool) -> Void

    /// Esc's last rung. See `escape()`.
    let onCancel: () -> Void

    /// The open document, and the anchor map over it.
    ///
    /// **Owned here rather than inside `PatentPDFView`**, which is where `PDFDocument(url:)`
    /// used to be called, and the move is what makes everything above the representable
    /// possible. The map, the marks, the find bar and the selection all have to address the
    /// *same* `PDFDocument` instance: annotations are added to its `PDFPage`s, and a second
    /// document opened from the same URL would be a different set of pages with the marks on
    /// the wrong one. So one object, made once, handed down.
    @State private var document: PDFDocument?
    @State private var map: PatentPDFMap?
    @State private var marks = PatentPDFMarks()

    /// Find in this patent. See `PatentPDFFind` for why finding deliberately does not select.
    @State private var find = PatentPDFFind()
    /// Whether the find bar is up. Separate from `find` so that type stays a description of
    /// matching rather than a view's presentation state.
    @State private var isFinding = false
    @FocusState private var isFindFocused: Bool

    /// What to say when a citation could not be landed on. See `band`.
    @State private var band: String?

    /// What the reader has selected, and whether there is anything.
    ///
    /// Two of them, and the split is deliberate. The selection itself is a live
    /// `PDFSelection` held in a plain box that **nothing reads during `body`**, so the
    /// several dozen notifications a single drag produces re-render nothing. `hasSelection`
    /// is read during `body` and changes at most twice per drag, which is the only part of
    /// this the layout actually depends on.
    @State private var selected = PDFSelectionBox()
    @State private var hasSelection = false

    /// Bumped to ask the representable to drop the selection — Esc's middle rung. A counter
    /// rather than a write to `selected`, because `PDFView` owns `currentSelection` and two
    /// writers over one property is the fight `bind(_:)` already documents for the page.
    @State private var clearSelectionRequest = 0

    var body: some View {
        Group {
            switch pdf.state(for: patent) {
            case .onDisk(let file):
                if let document, let map, opened(document, is: file) {
                    VStack(spacing: 0) {
                        if isFinding {
                            FindBar(
                                text: query(document),
                                summary: find.summary,
                                hasMatches: !find.matches.isEmpty,
                                isFocused: $isFindFocused,
                                onNext: { find.advance(by: 1) },
                                onPrevious: { find.advance(by: -1) },
                                onClose: { stopFinding() })
                            Divider()
                        }
                        if let band {
                            reportBand(band)
                            Divider()
                        }
                        PatentPDFView(
                            document: document, map: map, marks: marks, plan: plan,
                            find: find,
                            isMapped: map.isBuilt,
                            numbering: patent.numbering,
                            clearSelectionRequest: clearSelectionRequest,
                            onSelectionChange: { note($0) },
                            page: Binding(
                                get: { pdf.pages[patent.key] ?? 0 },
                                set: { pdf.pages[patent.key] = $0 }))
                    }
                } else {
                    // One frame, between the file being on disk and `.task` having opened
                    // it. Bare rather than captioned: a sentence that flashes for 16 ms is
                    // noise, where the download below genuinely takes seconds.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .downloadable(let url), .downloading(from: let url):
                // `.downloadable` renders as the spinner too: the `.task` below has
                // already been scheduled by the time this is drawn, so the request is
                // moments away and a separate "about to download" state would flash.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Downloading the original PDF from \(url.host() ?? "the office")…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                // The underlying `localizedDescription`, verbatim. A reader whose Wi-Fi is
                // off should read that their Wi-Fi is off.
                report(
                    "exclamationmark.triangle", "The download failed.", message,
                    action: "Try again"
                ) {
                    Task { await pdf.retry(patent) }
                }

            case .unavailable(let reason):
                report("doc.richtext", reason.headline, reason.detail(for: patent.key))
            }
        }
        // **The view existing is the reader having opened the patent.** `id:` re-runs the
        // whole sequence as they click down the library. `ensureDownloaded` is idempotent
        // and does not retry a failure, so clicking back and forth costs nothing — and for
        // everything imported since the download became eager it is already a no-op.
        .task(id: patent.key) { await open() }
        .task(id: bandRequest) { await raiseBand() }
        .onChange(of: findRequest) { startFinding() }
        .onChange(of: copyRequest) { copyPassage() }
        .background { shortcuts }
    }

    // MARK: - Selection

    /// The reader selected, or deselected, or dragged another point.
    ///
    /// Reported upward only on the transition between something and nothing, which is all
    /// `ContentView` acts on — and all it *should* act on. **The question is scoped to the
    /// patent, not to the selected paragraphs**, and that is unchanged rather than
    /// overlooked: `Retriever`'s scope is a `Set<PatentKey>`, and narrowing retrieval to a
    /// span inside one document is a different feature with its own ranking question.
    /// Selecting and then asking has always meant "about this patent"; it still does.
    private func note(_ selection: PDFSelection?) {
        selected.selection = selection
        let text = selection?.string ?? ""
        let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard has != hasSelection else { return }
        hasSelection = has
        onSelection(has)
    }

    /// ⇧⌘C, and why the app's own copy has a key of its own.
    ///
    /// ⌘C is what a reader presses to copy the phrase they just dragged out, and PDFKit
    /// already does that — uncited, which is the right answer for the system copy. The
    /// citation-appended quotation is a genuinely different thing, so it gets a shortcut of
    /// its own rather than depending on which handler the responder chain offers ⌘C first.
    ///
    /// **Two legs, and the first one never compares text.** `PatentPDFMap.targets(spanning:)`
    /// resolves the drag's two ends against the ordinals it already computed, so hyphenation
    /// and OCR cannot break it. `PassageAnchors.target(containing:)` is the textual fallback
    /// for a selection that falls outside every bracket the map placed. When both fail the
    /// text is copied **uncited and says so** — see `Citation.quotation(_:text:targets:)`.
    private func copyPassage() {
        guard let document, let selection = selected.selection else { return }
        let text = selection.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var targets = map?.targets(spanning: selection, in: document) ?? []
        if targets.isEmpty,
            let recovered = PassageAnchors.target(containing: text, in: patent)
        {
            targets = [recovered]
        }
        copyToPasteboard(Citation.quotation(patent, text: text, targets: targets))
        reportImplausibleSpan(targets, for: text)
    }

    /// **Two-column selection is PDFKit's to get wrong**, and this is where it shows.
    ///
    /// A drag down one column of a two-column grant can pick up the other in text-stream
    /// order, because the stream runs down the left column and back up to the top of the
    /// right. The bracket lookup copes — it produces a range citation, which is *true*: the
    /// selection really does span those passages. What is not true is that the copied text
    /// reads as prose, because it does not; it reads scrambled.
    ///
    /// So it is reported rather than silently corrected, on the one signal that separates
    /// the two cases: a span of many passages from a small amount of text. A genuine drag
    /// across four paragraphs carries four paragraphs of words.
    private func reportImplausibleSpan(_ targets: [CitationTarget], for text: String) {
        guard targets.count > 3, text.count < 200 else { return }
        band =
            "That selection spans \(targets.count) passages but is only \(text.count) "
            + "characters. On a two-column page a drag can pick up both columns in the "
            + "order the text was laid down; check what was copied before quoting it."
    }

    // MARK: - Finding

    /// The find field's text, which runs the search on every keystroke — an incremental
    /// find, the way every find field since the first one has worked.
    ///
    /// The anchor is the **current match** when there is one and the page the reader is on
    /// otherwise. That is what makes refining a query behave: typing `subs` after `sub`
    /// keeps the reader where `sub` put them instead of throwing them back up the document,
    /// while a query typed fresh starts from what they are reading.
    private func query(_ document: PDFDocument) -> Binding<String> {
        Binding(
            get: { find.query },
            set: { typed in
                let anchor =
                    find.current?.pages.first.map { document.index(for: $0) }
                    ?? pdf.pages[patent.key]
                find.search(typed, in: document, near: anchor)
            })
    }

    private func startFinding() {
        isFinding = true
        // Focused **next** main-actor turn, deliberately, and this is not a nicety: the
        // field does not exist until the bar is in the hierarchy, and a `@FocusState` write
        // naming a view SwiftUI has not created yet is dropped silently. ⌘F would raise the
        // bar and leave the keyboard in the document.
        //
        // Also correct when the bar is already up, which is the case this exists for: ⌘F
        // while reading a hit means "let me type another term", so the keyboard comes back.
        Task { isFindFocused = true }
    }

    private func stopFinding() {
        isFinding = false
        isFindFocused = false
        find.clear()
    }

    /// Esc, and the ladder it means.
    ///
    /// Esc means "put that away", innermost first: the find bar, then the reader's own
    /// selection, then whatever the app is doing. Each rung returns, so one press puts away
    /// one thing.
    ///
    /// Through a `.keyboardShortcut(.escape)` button and **not** `.onExitCommand`, which is
    /// what the text reader used. `PDFView`'s own document view takes first responder — that
    /// is how the arrows, space and page keys scroll without this app writing any of them —
    /// so there is no SwiftUI focus item here for an exit command to be delivered to.
    private func escape() {
        if isFinding {
            stopFinding()
            return
        }
        if hasSelection {
            clearSelectionRequest += 1
            return
        }
        onCancel()
    }

    /// ⌘F, ⌘G, ⇧⌘G, ⇧⌘C and Esc. Keyboard shortcuts need a control to hang off;
    /// zero-opacity rather than `.hidden()`, which removes it from the hierarchy along with
    /// its shortcut.
    ///
    /// **⌘F is the document's, and the library's filter is on ⌥⌘F to give it up.** Of the two
    /// fields this is the one ⌘F means everywhere else: find in the thing I am reading.
    @ViewBuilder
    private var shortcuts: some View {
        Group {
            Button("Find in this patent") { startFinding() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find next") { find.advance(by: 1) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find previous") { find.advance(by: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Copy passage with citation") { copyPassage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Cancel") { escape() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Fetch if needed, open, and anchor.
    ///
    /// One task rather than three, because they are one sequence and each step's input is
    /// the last step's output. Cancelled by `.task(id:)` when the reader moves on, which
    /// `PatentPDFMap.build` checks between anchors — a document nobody is looking at should
    /// not go on being walked.
    private func open() async {
        await pdf.ensureDownloaded(patent)
        guard case .onDisk(let file) = pdf.state(for: patent) else { return }
        if document == nil || !opened(document!, is: file) {
            document = PDFDocument(url: file)
            // The marks belong to the pages of the document that just went away.
            marks.clear()
        }
        guard let document else { return }
        let map = pdf.map(for: patent)
        self.map = map
        // The query survives the switch and the matches cannot — see `PatentPDFFind.refind`.
        find.refind(in: document)
        await map.build(in: document)
    }

    /// Whether an open document is the one at this URL. `PDFDocument` keeps the URL it was
    /// made from, which is the only identity available across a view rebuild.
    private func opened(_ document: PDFDocument, is file: URL) -> Bool {
        document.documentURL?.standardizedFileURL == file.standardizedFileURL
    }

    // MARK: - When a citation cannot be landed on

    /// What the band is a function of: which passage was asked for, and whether the map has
    /// finished enough to know whether it is there.
    ///
    /// Both, because the two arrive in either order. A chip clicked on a patent that is
    /// still being anchored has no verdict yet, and a map finishing has no news unless
    /// somebody asked for something.
    private struct BandRequest: Hashable {
        let focus: UUID?
        let isMapped: Bool
    }

    private var bandRequest: BandRequest {
        BandRequest(focus: plan.focus?.id, isMapped: map?.isBuilt ?? false)
    }

    /// The second of the three ways a failed jump is reported — the other two being the
    /// scroll to the nearest placed neighbour, which `PatentPDFView` does, and the third
    /// line of `ContentView.citationTally`.
    ///
    /// **Reported and not hidden**, which is this app's standing rule and matters more here
    /// than anywhere: a chip that appears to do nothing teaches the reader that the chips do
    /// not work. A chip that says it landed one paragraph early teaches them exactly how far
    /// to look.
    ///
    /// Transient because it is about a moment. The `.task(id:)` this runs in is cancelled
    /// and restarted by the next jump, so a band never outlives the jump that raised it.
    private func raiseBand() async {
        band = nil
        guard let map, map.isBuilt, let focus = plan.focus,
            map.selection(for: focus.target) == nil
        else { return }

        let label = Citation.chipLabel(focus.target, numbering: patent.numbering)
        let opening =
            "\(label) is in this patent, but it could not be found in the office's PDF."
        if let near = map.nearestPlaced(to: focus.target) {
            band =
                opening + " The nearest passage that could is "
                + "\(Citation.chipLabel(near, numbering: patent.numbering))."
        } else {
            band = opening
        }

        try? await Task.sleep(for: .seconds(8))
        band = nil
    }

    /// The band itself, in the same voice as `report(_:_:_:)` below and a quarter of the
    /// height: this one appears over a document the reader is already reading.
    @ViewBuilder
    private func reportBand(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { band = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    /// "Nothing to show you, and here is why", in `ContentView.emptyState`'s furniture so
    /// that the app says it the same way everywhere.
    @ViewBuilder
    private func report(
        _ symbol: String, _ headline: String, _ detail: String, action: String? = nil,
        perform: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action, let perform {
                Button(action, action: perform)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `PDFKit.PDFView`, as a SwiftUI view.
///
/// **Here rather than in `PlatformCompat.swift`**, which is the file two superclass names
/// would otherwise argue for. That file's own header says it holds "the handful of places
/// where AppKit and UIKit genuinely differ" so that everything else can be platform-free,
/// and every entry in it is a one-line shim over a single API. This is a feature's entire
/// view layer that happens to need two protocol names, and filing it there would make
/// `PlatformCompat.swift` the home of the reader. Keep the `#if`s at the smallest scope, in
/// the feature's own file.
///
/// The document arrives already open, from `PatentPDFReaderView` — see the note on its
/// `document` property for why it is not made here. It is still made with `PDFDocument(url:)`
/// and never `(data:)`: PDFKit memory-maps a file it is given a URL for, and a 6 MB grant
/// read through the heap on a device already holding a 4B model and an embedder is exactly
/// the wrong place to spend it. That is also why `LibraryStore.storedPDF` hands back a `URL`.
@MainActor
struct PatentPDFView {
    let document: PDFDocument
    let map: PatentPDFMap
    let marks: PatentPDFMarks
    let plan: HighlightPlan
    let find: PatentPDFFind
    /// Whether `map` has finished. A stored property and not a read of `map.isBuilt` inside
    /// `update`, because `updateNSView` is not an observation scope: the parent reads it,
    /// which is what re-runs this view when the walk finishes and the marks become drawable.
    let isMapped: Bool
    let numbering: Numbering
    /// Bumped by Esc to drop the selection. See `PatentPDFReaderView.clearSelectionRequest`.
    let clearSelectionRequest: Int
    let onSelectionChange: (PDFSelection?) -> Void

    /// The page the reader is on, zero-based, held by `PatentPDFService.pages` for this
    /// launch only.
    @Binding var page: Int

    /// Watches the view's own page and selection changes, and nothing else's.
    ///
    /// Scoped with `object: view` in both cases, because `.PDFViewPageChanged` and
    /// `.PDFViewSelectionChanged` are posted by every `PDFView` in the process and an
    /// unscoped observer would write one patent's state from another patent's document.
    @MainActor
    final class Coordinator {
        /// Re-assigned on every `update`, so the closures called here are always the
        /// current ones rather than the ones captured when the view was made.
        var onPageChange: (Int) -> Void = { _ in }
        var onSelectionChange: (PDFSelection?) -> Void = { _ in }

        /// The last jump acted on. Identity and not the target, because clicking the same
        /// chip twice has to move twice — the reason `PassageFocus` carries a `UUID` at all.
        var lastFocus: UUID?

        /// The last find step scrolled to, for the same reason in miniature: two hits in one
        /// place would be "no change" and the second ⌘G would silently not scroll.
        var lastFindStep = 0

        /// The last Esc acted on.
        var lastClear = 0

        /// `nonisolated(unsafe)` so that `deinit`, which is not main-actor isolated, can
        /// hand the tokens back. They are written once on the main actor while the view is
        /// alive and read once when nothing else holds this object, which is the whole of
        /// the unsafety.
        private nonisolated(unsafe) var tokens: [any NSObjectProtocol] = []

        func observe(_ view: PDFView) {
            guard tokens.isEmpty else { return }
            tokens.append(
                NotificationCenter.default.addObserver(
                    forName: .PDFViewPageChanged, object: view, queue: .main
                ) { [weak self, weak view] _ in
                    // The block is `@Sendable` and non-isolated, and `PDFDocument` is not
                    // `Sendable`, so every PDFKit touch has to stay on the main actor. The
                    // assumption is sound rather than hopeful: `queue: .main`.
                    MainActor.assumeIsolated {
                        guard let self, let view, let document = view.document,
                            let current = view.currentPage
                        else { return }
                        self.onPageChange(document.index(for: current))
                    }
                })
            tokens.append(
                NotificationCenter.default.addObserver(
                    forName: .PDFViewSelectionChanged, object: view, queue: .main
                ) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view else { return }
                        self.onSelectionChange(view.currentSelection)
                    }
                })
        }

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Both platforms configured identically and explicitly, including the defaults.
    ///
    /// `usePageViewController` is deliberately left off on iOS: it would give the phone a
    /// paged, horizontally swiped document and the Mac a continuous vertical one, which is
    /// two different readers for one tab.
    private func make(_ coordinator: Coordinator) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        load(into: view)
        coordinator.observe(view)
        bind(coordinator)
        return view
    }

    private func update(_ view: PDFView, _ coordinator: Coordinator) {
        bind(coordinator)
        if view.document !== document {
            load(into: view)
            // A reload is a new set of pages, so a jump made against the old ones has to be
            // made again.
            coordinator.lastFocus = nil
            coordinator.lastFindStep = 0
        }
        if coordinator.lastClear != clearSelectionRequest {
            coordinator.lastClear = clearSelectionRequest
            view.clearSelection()
        }
        // The remembered page is reconciled **before** the jump, deliberately. A jump moves
        // the view and `.PDFViewPageChanged` catches `page` up a turn later, so reconciling
        // afterwards would read a stale `page` and scroll straight back to where the reader
        // was — a chip that appears to work and then undoes itself.
        if let current = view.currentPage, document.index(for: current) != page {
            go(to: page, in: view)
        }
        // **A separate channel from the marks and from the selection**, which is the whole
        // reason closing the find bar cannot disturb an answer's evidence and a find hit
        // cannot scope the reader's next question. See `PatentPDFFind`.
        view.highlightedSelections = find.matches.isEmpty ? nil : find.highlighted
        if coordinator.lastFindStep != find.step {
            coordinator.lastFindStep = find.step
            if let hit = find.current { view.go(to: hit) }
        }
        guard isMapped else { return }
        marks.apply(plan, from: map, numbering: numbering, to: document, redrawing: view)
        jump(in: view, coordinator)
    }

    /// The jump. This is the interaction the whole app is for, at the end of its journey:
    /// a chip in the answer pane, through a paragraph number, an anchor and a placement, to
    /// a scroll of the document the office published.
    ///
    /// **Scrolls without selecting.** `go(to: PDFSelection)` moves the view and leaves
    /// `currentSelection` alone, which is what keeps the three channels apart — a jump must
    /// not scope the reader's next question, exactly as a find hit must not.
    ///
    /// When the passage could not be placed the reader is put on the nearest one that was,
    /// and `PatentPDFReaderView.raiseBand` says so. Landing next door and being told is a
    /// far better answer than a chip that does nothing.
    private func jump(in view: PDFView, _ coordinator: Coordinator) {
        guard let focus = plan.focus, coordinator.lastFocus != focus.id else { return }
        coordinator.lastFocus = focus.id

        // Inside the passage where a refinement asks for it and it is there; on the passage
        // otherwise, which is the coarser answer and still a correct one.
        if let refinement = focus.refinement,
            let narrowed = map.refine(refinement, within: focus.target, in: document)
        {
            view.go(to: narrowed)
            return
        }
        if let selection = map.selection(for: focus.target) {
            view.go(to: selection)
            return
        }
        guard let near = map.nearestPlaced(to: focus.target),
            let selection = map.selection(for: near)
        else { return }
        view.go(to: selection)
    }

    /// Points the coordinator at *this* instance's closures, on every update, so what they
    /// write is never captured from when the view was made.
    private func bind(_ coordinator: Coordinator) {
        coordinator.onPageChange = { reported in
            // Only when it differs, or this writes the state that produced it and the
            // next `update` scrolls the view that produced the notification, forever.
            guard reported != page else { return }
            page = reported
        }
        coordinator.onSelectionChange = onSelectionChange
    }

    private func load(into view: PDFView) {
        // The marks are on the pages of whatever was here before. Cleared rather than
        // left, or the next `apply` would think they were already drawn.
        marks.clear()
        view.document = document
        go(to: page, in: view)
    }

    /// Bounds-checked, because the remembered page belongs to the last document opened at
    /// this key and a re-imported patent may be a shorter one.
    private func go(to index: Int, in view: PDFView) {
        guard index >= 0, index < document.pageCount, let target = document.page(at: index)
        else { return }
        view.go(to: target)
    }
}

// The two superclass names, and nothing else. Everything above is one implementation.
#if os(macOS)
    extension PatentPDFView: NSViewRepresentable {
        func makeNSView(context: Context) -> PDFView { make(context.coordinator) }

        func updateNSView(_ view: PDFView, context: Context) {
            update(view, context.coordinator)
        }
    }
#else
    extension PatentPDFView: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFView { make(context.coordinator) }

        func updateUIView(_ view: PDFView, context: Context) {
            update(view, context.coordinator)
        }
    }
#endif

/// A live `PDFSelection`, held where nothing observes it.
///
/// A plain reference box and deliberately **not** `@Observable`. A single drag posts
/// `.PDFViewSelectionChanged` dozens of times, and every one of them would re-render the
/// reader pane if this were observed — for a value only two call sites read, both of them
/// outside `body`: ⇧⌘C and Esc. What the layout does depend on is whether there is a
/// selection at all, and `PatentPDFReaderView.hasSelection` carries that separately, changing
/// at most twice per drag.
@MainActor
final class PDFSelectionBox {
    var selection: PDFSelection?
}
