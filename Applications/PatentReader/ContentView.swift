// Copyright © 2026 Apple Inc.

import MLXLLM
import MLXLMCommon
import SwiftUI

@MainActor
struct ContentView: View {
    let options: AppOptions

    @State private var service: AnswerService
    @State private var library = LibraryService()

    @State private var openPatent: PatentKey?

    /// Which passage the reader was last sent to, and why.
    ///
    /// The whole of "where the reader is", where the deleted text reader needed three:
    /// a selection to draw a band, a scroll target, and a flash. On the original those are
    /// one thing — a highlight the view is scrolled to. Carries a fresh identity per jump so
    /// clicking the same chip twice moves twice; see `PassageFocus`.
    @State private var focus: PassageFocus?

    /// Where the reader has been, so a citation jump can be undone. See
    /// `NavigationHistory`; ⌘[ and ⌘] drive it.
    @State private var history = NavigationHistory()

    /// Whether the answer sheet is up at a compact width.
    ///
    /// Deliberately *not* `question != nil`, which is the bug this replaces: presentation
    /// is a moment, an answer is not. UIKit reports an interactive dismissal for a drag of
    /// a few points — even one that snaps back to `.medium` — and with the sheet bound to
    /// the answer, that nudge would throw away the prose, the transcript, the follow-ups
    /// and the `ChatSession` they run on.
    ///
    /// The invariant is one-way and `clearAnswer()` holds it: no answer, no sheet. The
    /// converse is the point — an answer with no sheet over it is one the reader swiped
    /// away and can have back, with no model work.
    @State private var showsAnswerSheet = false

    /// Which side panes are on screen. Hiding them is how the reader gets the document on
    /// its own, so how they left them is how they come back.
    @AppStorage("showsLibrary") private var showsLibrary = true
    @AppStorage("showsAnswers") private var showsAnswers = true

    /// What the library has open. Lives here, not in `LibraryView`, so it survives hiding
    /// the pane. Not persisted and not seeded: it follows the reading position, so the
    /// restored `openPatent` implies it at launch.
    @State private var outline = LibraryOutline()

    /// The face the *patent text* is set in; everything else stays on the system face.
    @AppStorage("readerFont") private var readerFont: ReaderFont = .system
    @AppStorage("readerTextSize") private var readerTextSize: ReaderTextSize = .default

    /// Read here, and only so that the typeface is rebuilt when the reader moves the
    /// Larger Text slider. At a non-default `readerTextSize` the text is drawn with a
    /// *fixed-size* `Font.system(size:)`, which does not follow Dynamic Type on its own.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether there is room for the panes side by side, which is the *only* axis the
    /// layout forks on.
    ///
    /// Deliberately not `UIDevice.userInterfaceIdiom`. An iPad in Slide Over or a narrow
    /// Stage Manager window is compact and has to behave exactly like a phone, and it
    /// becomes compact and regular again *while the app is running*.
    ///
    /// Always `true` on a Mac, where a window narrow enough to matter is unreachable:
    /// `PatentReaderApp` floors it at 1100, which clears the three panes' 1100.
    private var isRegularWidth: Bool {
        #if os(macOS)
            true
        #else
            horizontalSizeClass == .regular
        #endif
    }

    @AppStorage("showsDiagnostics") private var diagnosticsPreference = false
    private var showsDiagnostics: Bool { diagnosticsPreference || options.diagnostics }

    @State private var fonts = ReaderFontLibrary()

    // MARK: - Answer state

    @State private var question: String?
    @State private var scanner: CitationScanner?
    @State private var runs: [AnswerRun] = []
    @State private var tail = ""
    @State private var followUps: [String] = []
    @State private var transcript: [AnswerPaneView.Exchange] = []
    @State private var phase: Phase = .idle
    @State private var retrieved: [RetrievedChunk] = []
    @State private var isLexicalOnly = false

    /// Quoted spans the model produced that are in none of the retrieved passages, and
    /// citations by verdict. Diagnostics only — both report and neither strips, so
    /// nothing here changes what the reader is shown.
    @State private var unsupportedQuotes: [String] = []
    @State private var promptTokens: Int?
    @State private var timeToFirstToken: TimeInterval?
    @State private var stats: GenerationStats?
    @State private var errorMessage: String?

    /// Bumped by ⌘L to put the keyboard in the Ask field. See
    /// `AnswerPaneView.focusRequest` for why it is a counter.
    @State private var askFieldFocusRequest = 0

    /// Bumped to raise the reader's find bar. ⌘F is handled inside whichever reader is up,
    /// where the find state lives; this is for the affordances that are not a key — the
    /// header button here, and the overflow row on a phone.
    @State private var findRequest = 0

    /// Bumped to copy the reader's selection with its citation. ⇧⌘C's counterpart for the
    /// iOS overflow row, where there is no ⇧⌘C.
    @State private var copyRequest = 0

    /// Whether there is a non-empty text selection in the open PDF.
    ///
    /// Reported up from `PatentPDFReaderView`, because the selection itself is a live
    /// `PDFSelection` and belongs in the view layer. Two call sites: scoping a question, and
    /// enabling the phone's copy row.
    @State private var hasOriginalSelection = false

    init(options: AppOptions) {
        self.options = options
        _service = State(
            initialValue: AnswerService(
                modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
                greedy: options.greedy))
    }

    var body: some View {
        layout
            .task {
                library.load()
                if openPatent == nil {
                    let opening = ProgressStore.opening(
                        from: ProgressStore.progress(), in: library.patents)
                    openPatent = opening.patent
                    focus = opening.focus.map { PassageFocus($0) }
                }
                await service.load()
            }
            .onChange(of: openPatent) {
                recordProgress()
                if let openPatent { outline = .following(openPatent) }
            }
            .onChange(of: focus) { recordProgress() }
            // Every `patentreader://` URL in the answer pane and in the document text
            // lands here. `Text` will not host a `Button`, so a tappable run inside
            // flowing prose has to be a link — and `.handled` is what keeps the link from
            // ever reaching the system, which would open a browser.
            .environment(
                \.openURL,
                OpenURLAction { url in
                    open(url)
                    return .handled
                }
            )
            .background { shortcuts }
    }

    // MARK: - Layout

    /// The one place the two platforms genuinely diverge. Both branches build their panes
    /// from the same three `@ViewBuilder` helpers, so what differs here is the
    /// *container* and nothing else.
    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
            VStack(spacing: 0) {
                header
                Divider()
                desktopPanes
            }
        #else
            phonePanes
        #endif
    }

    #if os(macOS)
        @ViewBuilder
        private var desktopPanes: some View {
            // The side panes are fixed widths, and that is what keeps the library still.
            // `HSplitView` distributes width from each child's min / ideal / max, and it
            // will move *any* pane that has room between them: a `maxWidth` caps how far
            // a pane can grow but leaves it just as free to be shrunk. Pinning the sides
            // leaves the reader as the only pane with any give, so it absorbs the whole
            // difference and the dividers never move.
            //
            // The cost is that the dividers are no longer draggable. 240 + 400 here plus
            // the reader's 460 floor is the 1100 that sets the window minimum.
            HSplitView {
                if showsLibrary {
                    libraryPane().frame(width: 240)
                }

                readerPane()
                    // The only pane with any flexibility, so every width change lands
                    // here.
                    .frame(minWidth: 460, idealWidth: 680, maxWidth: .infinity)

                if showsAnswers {
                    answerPane().frame(width: 400)
                }
            }
        }
    #else
        /// Library and reader as the two columns of a `NavigationSplitView`, which a
        /// compact width renders collapsed — so there it is a push from the library to
        /// the document with the system's own back button standing in for ⌘1 — and a
        /// regular width renders as two columns side by side the way the Mac's
        /// `HSplitView` does.
        ///
        /// The answers pane is an `.inspector` because that one container is both shapes:
        /// it auto-presents as a **sheet** at a compact width, where the document stays
        /// on screen above the answer — the whole point of the three-pane desktop layout
        /// and the one part of it worth keeping on a phone — and as a trailing **column**
        /// at a regular width, which is the desktop layout itself.
        @ViewBuilder
        private var phonePanes: some View {
            NavigationSplitView(
                columnVisibility: libraryVisibility,
                preferredCompactColumn: libraryColumn
            ) {
                libraryPane()
                    .navigationTitle("Patents")
            } detail: {
                Group {
                    if openPatent != nil {
                        readerPane()
                            .navigationTitle(patent?.key.display ?? "")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { readerToolbar }
                    } else {
                        emptyState
                    }
                }
            }
            .inspector(isPresented: answersPresented) {
                answerPane()
            }
        }

        /// Which flag the answers pane answers to, which is the whole of the difference
        /// between the two widths.
        ///
        /// Regular width routes through `setAnswers(_:)` rather than writing the flag
        /// directly, so the column's own close button behaves exactly as ⌘2 does on the
        /// Mac. Compact width ignores a `true` write: the sheet is raised by asking a
        /// question and by nothing else.
        private var answersPresented: Binding<Bool> {
            Binding(
                get: { isRegularWidth ? showsAnswers : showsAnswerSheet },
                set: { shown in
                    if isRegularWidth {
                        setAnswers(shown)
                    } else if !shown {
                        hideAnswerSheet()
                    }
                })
        }

        /// The persisted library preference, in the shape a *regular-width* split view
        /// acts on. `.all` and not `.doubleColumn`: in a two-column split view they mean
        /// the same thing, and `.all` is the one that reads as "both columns". The setter
        /// tests `!= .detailOnly` because SwiftUI writes `.automatic` back.
        private var libraryVisibility: Binding<NavigationSplitViewVisibility> {
            Binding(
                get: { showsLibrary ? .all : .detailOnly },
                set: { showsLibrary = $0 != .detailOnly })
        }

        /// The same preference, in the shape a *collapsed* split view acts on.
        ///
        /// `columnVisibility:` is ignored once the split view collapses, which is every
        /// iPhone and an iPad at a compact width. `preferredCompactColumn:` is the
        /// two-way one: writing `.detail` pushes the reader, and SwiftUI writes
        /// `.sidebar` back when the reader taps the system back button.
        private var libraryColumn: Binding<NavigationSplitViewColumn> {
            Binding(
                get: { showsLibrary ? .sidebar : .detail },
                set: {
                    // The guard is what keeps two bindings over one flag from fighting.
                    // At a regular width the pop this setter exists for does not happen,
                    // and a write arriving *during* a size-class transition would set the
                    // flag from a column preference the split view is no longer acting
                    // on — collapsing a sidebar the reader can see.
                    guard !isRegularWidth else { return }
                    showsLibrary = $0 == .sidebar
                    // The sheet is over the *split view*, not over the reader column, so
                    // it outlives the column it belongs to and would end up citing
                    // paragraphs of a patent that is no longer on screen.
                    if $0 == .sidebar { hideAnswerSheet() }
                })
        }
    #endif

    private var patent: Patent? {
        openPatent.flatMap { library.store.patent($0) }
    }

    /// What the open document should have painted on it: the passages retrieval put in the
    /// prompt, the ones the answer cited, and the one the reader was last sent to.
    ///
    /// Assembled here because this is the only place that holds all three. Everything about
    /// *which* passages qualify lives in `HighlightPlan.make`, which is pure and asserted —
    /// in particular the three exclusions, which are the part a view body would get wrong.
    ///
    /// The transcript's runs go in beside the current answer's: a reader three follow-ups
    /// deep is still reading one conversation, and the passages the earlier turns cited are
    /// still the evidence on the page.
    private var highlightPlan: HighlightPlan {
        guard let openPatent else { return .empty }
        return HighlightPlan.make(
            for: openPatent,
            retrieved: retrieved.map(\.chunk.target),
            runs: runs + transcript.flatMap(\.runs),
            focus: focus)
    }

    // MARK: - Panes

    @ViewBuilder
    private func libraryPane() -> some View {
        LibraryView(
            library: library,
            openPatent: Binding(
                get: { openPatent },
                set: { if let key = $0 { openPatent(key) } }),
            outline: $outline,
            onOpenSection: { index in scrollToSection(index) },
            onLocate: { locate($0) })
    }

    /// The reader: the document as the office published it, and nothing else.
    ///
    /// There used to be two, behind a segmented control — a list of parsed rows, and this.
    /// The parsed text was always a *means*: it is how the app builds an index, fills a
    /// prompt and names a citation, and it still does all three. What it was not was the
    /// thing a patent reader wants in front of them, which is the figures, the tables, the
    /// chemical structures, the real typesetting, and the ability to check that `[0042]` is
    /// `[0042]`.
    ///
    /// The one thing the tab bar bought — a citation landing on a passage — is now
    /// `PassageAnchor` and `PatentPDFMap`'s, and the measurements are in their headers.
    @ViewBuilder
    private func readerPane() -> some View {
        if let patent {
            PatentPDFReaderView(
                patent: patent, pdf: library.pdf, plan: highlightPlan,
                findRequest: findRequest,
                copyRequest: copyRequest,
                onSelection: { hasOriginalSelection = $0 },
                onCancel: { cancel() })
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func answerPane() -> some View {
        VStack(spacing: 0) {
            AnswerPaneView(
                question: question,
                runs: runs,
                tail: tail,
                followUps: followUps,
                transcript: transcript,
                isBusy: isBusy,
                isLexicalOnly: isLexicalOnly,
                retrievedCount: retrieved.count,
                numbering: patent?.numbering ?? .printed,
                focusRequest: askFieldFocusRequest,
                onAsk: ask)
            // Both go together: a divider with nothing under it would leave an empty band
            // at the foot of the pane.
            if showsDiagnostics || errorMessage != nil {
                Divider()
                statusStrip
            }
        }
        // Half height by default, which is the entire reason the answers pane is an
        // `.inspector` rather than a plain `.sheet`: at `.medium` the document is still on
        // screen above the answer, which is what the third pane does on a Mac. Without
        // these the inspector presents at full height at a compact width and the passage
        // a citation lands on disappears behind the answer that cited it.
        #if !os(macOS)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No patent open")
                .font(.headline)
            Text("Add one by number from the library, or drop a PDF on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header and toolbar

    #if os(macOS)
        @ViewBuilder
        private var header: some View {
            HStack(spacing: 10) {
                paneToggle(
                    "the library", systemImage: "sidebar.leading", shortcut: "1",
                    isVisible: showsLibrary
                ) {
                    showsLibrary.toggle()
                }

                backForward
                findButton
                typefaceMenu

                if showsDiagnostics {
                    Text("\(shortModelName) · on-device")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Spacer()

                loadStateIndicator
                diagnosticsMenu

                paneToggle(
                    "the answers", systemImage: "sidebar.trailing", shortcut: "2",
                    isVisible: showsAnswers
                ) {
                    setAnswers(!showsAnswers)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    #else
        @ToolbarContentBuilder
        private var readerToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                loadStateIndicator
                typefaceMenu
                if isRegularWidth {
                    paneToggle(
                        "the answers", systemImage: "sidebar.trailing", shortcut: "2",
                        isVisible: showsAnswers
                    ) {
                        setAnswers(!showsAnswers)
                    }
                }
                overflowMenu
            }
        }

        @ViewBuilder
        private var overflowMenu: some View {
            Menu {
                // ⌘[ is not a key a phone has, so the back stack needs a control. Only
                // shown when there is something on it, because a permanently disabled row
                // teaches nothing.
                if history.canGoBack {
                    Button("Back", systemImage: "chevron.left") { goBack() }
                }
                // Neither is ⌘F, and this is the only way to a find field on a phone.
                Button("Find in this patent", systemImage: "text.magnifyingglass") {
                    findRequest += 1
                }
                // ⇧⌘C is not a key a phone has either. The row is disabled rather than
                // hidden, because "copy the passage" is worth teaching even when there is
                // nothing selected yet.
                //
                // There is no **Clear selection** row beside it any more, and its going is
                // a small gain rather than a loss: the row band it used to dismiss had no
                // other way out, where PDFKit's own selection is cleared by tapping the
                // page — the system's gesture, which a reader already knows.
                Button("Copy passage", systemImage: "doc.on.doc") { copyRequest += 1 }
                    .disabled(!hasOriginalSelection)
                Divider()
                Toggle("Show diagnostics", isOn: $diagnosticsPreference)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenu()
            .accessibilityLabel("More")
        }
    #endif

    /// ⌘F, as a control — because a shortcut nobody is told about is a feature half the
    /// readers do not have. The bar itself, and the key, belong to whichever reader is up.
    ///
    /// Disabled with no patent open, where there is nothing to search and no reader view to
    /// receive the request. Both readers now answer this: the request goes to the one in the
    /// hierarchy, and each searches the document it is showing.
    @ViewBuilder
    private var findButton: some View {
        Button {
            findRequest += 1
        } label: {
            Image(systemName: "text.magnifyingglass")
        }
        .buttonStyle(.borderless)
        .disabled(patent == nil)
        .help("Find in this patent (⌘F)")
        .accessibilityLabel("Find in this patent")
    }

    /// ⌘[ and ⌘], as a control on macOS and as an overflow row on a phone.
    @ViewBuilder
    private var backForward: some View {
        HStack(spacing: 2) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!history.canGoBack)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")

            Button {
                goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!history.canGoForward)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
        }
    }

    /// Keyboard shortcuts need a control to hang off. Zero-opacity rather than
    /// `.hidden()`, which removes it from the hierarchy along with its shortcut.
    ///
    /// Kept on iOS too: it costs nothing and works with a hardware keyboard.
    @ViewBuilder
    private var shortcuts: some View {
        Group {
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { goForward() }
                .keyboardShortcut("]", modifiers: .command)
            // ⌘L, the conventional "focus the entry field". The library has ⌘F and the
            // field a reader uses most had nothing, which is the wrong way round: asking
            // is the app's primary interaction. Reveals the pane first, since a shortcut
            // that focuses something invisible has done nothing.
            Button("Ask") {
                setAnswers(true)
                askFieldFocusRequest += 1
            }
            .keyboardShortcut("l", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Where the model is, on both platforms. The first launch downloads gigabytes and an
    /// app that says nothing while it does looks broken, so the loading and failed states
    /// are never hidden by the diagnostics preference; idle and ready are noise and are.
    @ViewBuilder
    private var loadStateIndicator: some View {
        switch service.loadState {
        case .idle:
            if showsDiagnostics {
                Text("Idle").foregroundStyle(.secondary).font(.caption)
            }
        case .loading(let progress):
            HStack(spacing: 6) {
                if let progress, progress.totalUnitCount > 0 {
                    // The constraint is the *bar's* width, not the platform: a compact
                    // navigation bar already holds three controls at this point and has
                    // no 120 points to spare.
                    if isRegularWidth {
                        ProgressView(value: progress.fractionCompleted).frame(width: 120)
                    }
                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        case .ready:
            if showsDiagnostics {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            // Also never hidden: without this the reader gets a library that silently
            // refuses to answer anything.
            Label("Load failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(message)
        }
    }

    /// The face and size the patent is set in. A `Menu` of `Toggle`s and **not** a
    /// `Picker`, for `ContentView`'s reason next door: picker rows are selection tags with
    /// nowhere to hang a download or a retry affordance, and an `NSMenuItem` has exactly
    /// one image slot, so a hand-drawn checkmark would displace the download glyph on the
    /// row whose state matters.
    @ViewBuilder
    private var typefaceMenu: some View {
        Menu {
            Section("Typeface") {
                ForEach(ReaderFont.offered, id: \.self) { font in
                    Toggle(
                        isOn: Binding(
                            get: { font == readerFont }, set: { _ in choose(font) })
                    ) {
                        if let glyph = statusGlyph(font) {
                            Label(font.displayName, systemImage: glyph)
                        } else {
                            Text(font.displayName)
                        }
                    }
                    .help(fonts.failed[font] ?? "")
                }
            }

            Section("Size") {
                ForEach(ReaderTextSize.allCases, id: \.self) { size in
                    Toggle(
                        size.displayName,
                        isOn: Binding(
                            get: { size == readerTextSize },
                            set: { _ in readerTextSize = size }))
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
        .borderlessMenu()
        .fixedSize()
        .help("The face and size the patent is set in")
        .accessibilityLabel("Reader typeface and size")
    }

    #if os(macOS)
        @ViewBuilder
        private var diagnosticsMenu: some View {
            Menu {
                Toggle("Show diagnostics", isOn: $diagnosticsPreference)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenu()
            .fixedSize()
            .help("Show the model, the load check and the retrieval numbers")
            .accessibilityLabel("Diagnostics")
        }
    #endif

    /// `nil` for a family that is installed and idle, which is the ordinary case and
    /// wants no glyph at all.
    private func statusGlyph(_ font: ReaderFont) -> String? {
        if fonts.failed[font] != nil { return "exclamationmark.triangle" }
        if fonts.downloading.contains(font) { return "arrow.down.circle.fill" }
        return fonts.isAvailable(font) ? nil : "arrow.down.circle"
    }

    private func choose(_ font: ReaderFont) {
        readerFont = font
        if !fonts.isAvailable(font) { fonts.download(font) }
    }

    @ViewBuilder
    private func paneToggle(
        _ name: String, systemImage: String, shortcut: KeyEquivalent, isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(isVisible ? "Hide" : "Show") \(name) (⌘\(String(shortcut.character)))")
        .accessibilityLabel("\(isVisible ? "Hide" : "Show") \(name)")
    }

    private var shortModelName: String {
        service.modelID.split(separator: "/").last.map(String.init) ?? service.modelID
    }

    // MARK: - Status strip

    /// With diagnostics on, every wait gets a name and the numbers that decide whether
    /// the prompt needs shedding are on screen rather than in a log. With them off the
    /// strip is nothing but a place for a failure to be reported.
    @ViewBuilder
    private var statusStrip: some View {
        if showsDiagnostics {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    switch phase {
                    case .idle:
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                        Text(question == nil ? "Idle" : "Done")
                    case .cached:
                        Image(systemName: "bolt.fill").foregroundStyle(.green)
                        Text("Cached")
                    case .retrieving:
                        ProgressView().controlSize(.small)
                        Text("Searching the library…")
                    case .prefilling:
                        ProgressView().controlSize(.small)
                        Text("Prefilling…")
                    case .answering:
                        Image(systemName: "text.cursor")
                        Text("Answering")
                    case .listingFollowUps:
                        ProgressView().controlSize(.small)
                        Text("Finding what to ask next…")
                    }

                    Spacer()

                    if let timeToFirstToken {
                        Text(String(format: "first token %.2fs", timeToFirstToken))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                if let line = statsLine {
                    Text(line)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                citationTally
                if let line = retrievalLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if let line = anchorLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if !unsupportedQuotes.isEmpty {
                    // Reported, never corrected. A quotation none of the retrieved
                    // passages contains is evidence about a prompt, and hiding it to tidy
                    // the output would spend the signal.
                    Text(
                        "not in the passages: "
                            + unsupportedQuotes.map { "“\($0)”" }.joined(separator: ", ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else if let errorMessage {
            // A generation that failed still has to say so.
            Text(errorMessage)
                .font(.caption2)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    /// The two verdicts that are not `.supported`, named.
    ///
    /// As loud as `unsupportedQuotes` above and for the same reason: between them these
    /// are the app's primary signal about prompt quality. What they cannot see is worth
    /// remembering while reading them — a real, retrieved paragraph cited for a claim it
    /// does not make comes back `.supported`, and no string comparison reaches that.
    @ViewBuilder
    private var citationTally: some View {
        let tally = CitationCheck.tally(runs + transcript.flatMap(\.runs))
        if let unretrieved = tally[.unretrieved], !unretrieved.isEmpty {
            Text("cited but not retrieved: " + unretrieved.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let missing = tally[.nonexistent], !missing.isEmpty {
            Text("cited and does not exist: " + missing.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if !unlocatable.isEmpty {
            Text("cited and not found in the PDF: " + unlocatable.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    /// Citations that check out and that the reader still cannot be taken to.
    ///
    /// The third line of the tally, and **deliberately not a `CitationCheck.Verdict`.** The
    /// verdicts are model-free, PDFKit-free and decided at commit time inside
    /// `CitationScanner`, and a fourth case that depended on a document being open — and on
    /// a map having finished walking it — would break all three of those at once. A chip
    /// whose paragraph exists and was retrieved is a good citation whatever this app can do
    /// with a PDF; that it cannot land on it is a fact about the app, and it is reported as
    /// one, here, beside the other things the app admits to.
    private var unlocatable: [String] {
        guard let openPatent, let map = library.pdf.anchored(openPatent), map.isBuilt
        else { return [] }
        var seen: Set<String> = []
        return (runs + transcript.flatMap(\.runs)).compactMap { run in
            guard case .citation(let citation) = run, citation.verdict == .supported,
                citation.target.patent == openPatent,
                !HighlightPlan.isFrontMatter(citation.target),
                map.selection(for: citation.target) == nil,
                seen.insert(citation.literal).inserted
            else { return nil }
            return citation.literal
        }
    }

    /// `anchored 428/437 paragraphs · 106/120 claims`, for the open document.
    ///
    /// One line, and it is the alarm for the whole feature. Anchoring fails *quietly*: a
    /// document shape that drops to 60% looks, chip by chip, exactly like a handful of
    /// unlucky paragraphs, and there is no other place in the app where the rate is visible.
    private var anchorLine: String? {
        openPatent.flatMap { library.pdf.anchored($0)?.summary }
    }

    /// What retrieval found and by which leg, which is how a retrieval regression gets
    /// diagnosed without a rebuild.
    private var retrievalLine: String? {
        guard !retrieved.isEmpty else { return nil }
        let parts = retrieved.prefix(4).map { chunk -> String in
            let dense = chunk.denseRank.map { "d\($0)" } ?? "d–"
            let lexical = chunk.lexicalRank.map { "b\($0)" } ?? "b–"
            return
                "\(AnswerContext.label(chunk.chunk.target, numbering: patent?.numbering ?? .printed, qualified: false)) \(dense)/\(lexical)"
        }
        return "top: " + parts.joined(separator: " · ")
    }

    private var statsLine: String? {
        var parts: [String] = []
        if let promptTokens { parts.append("\(promptTokens) prompt tok") }
        if let stats {
            parts.append(String(format: "prefill %.0f tok/s", stats.promptTokensPerSecond))
            parts.append(String(format: "decode %.1f tok/s", stats.tokensPerSecond))
            parts.append(
                String(format: "%.2f GB peak", Double(stats.peakBytes) / 1_073_741_824))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var isBusy: Bool {
        switch phase {
        case .idle, .cached: false
        default: true
        }
    }

    // MARK: - Navigation

    private func openPatent(_ key: PatentKey) {
        revealReader()
        guard key != openPatent else { return }
        if let current = openPatent {
            history.push(NavigationHistory.Position(patent: current, target: focus?.target))
        }
        openPatent = key
        focus = nil
    }

    /// Brings the reader on screen, at the width where it is not already.
    ///
    /// `#if`-free at the call site and conditional here. At a regular width all panes are
    /// already up, so hiding the library on every click would be the opposite of what a
    /// click asks for. That guard carries more than it looks: `openPatent(_:)` calls this
    /// *above* its "is this a different patent" guard, so without it every tap in the
    /// library would collapse the sidebar out from under the reader.
    private func revealReader() {
        guard !isRegularWidth else { return }
        showsLibrary = false
    }

    /// The jump. This is the function the whole app is for.
    ///
    /// **It used to open by switching to the parsed text**, on the argument that a paragraph
    /// number is a fact about the parse and the PDF carries no index to resolve `[0042]`
    /// against. The first half is still true; the conclusion was wrong. A paragraph's own
    /// first six words are that index, they are already in the parse, and
    /// `PassageAnchors` → `PatentPDFMap` resolves 97% of them in about two milliseconds
    /// each. So the jump lands on the office's own document, and the 3% that cannot be
    /// landed on are reported in three places rather than hidden — see
    /// `PatentPDFReaderView.raiseBand` and `unlocatable`.
    ///
    /// The order of the first two steps matters: switching documents clears the focus, so
    /// the history push and the switch have to happen before anything is aimed.
    private func jump(to target: CitationTarget) {
        guard library.store.patent(target.patent) != nil else { return }

        if target.patent != openPatent {
            if let current = openPatent {
                history.push(
                    NavigationHistory.Position(patent: current, target: focus?.target))
            }
            openPatent = target.patent
            revealReader()
        } else if let current = openPatent, let previous = focus?.target {
            // Same document: still worth recording, because a jump within a long patent
            // loses the reader's place exactly as a jump across one does.
            history.push(NavigationHistory.Position(patent: current, target: previous))
        }

        focus = PassageFocus(target)
    }

    /// A `patentreader://` URL from an answer chip, a reference numeral, or a claim
    /// cross-reference. One handler, because they are one interaction from the reader's
    /// side: a thing in the text that takes you to the thing it names.
    private func open(_ url: URL) {
        if let target = CitationLink.target(from: url) {
            jump(to: target)
            return
        }
        guard url.scheme == ReaderLink.scheme, let openPatent else { return }
        let value = Int(url.lastPathComponent)
        switch url.host() {
        case "claim":
            guard let value else { return }
            jump(to: .claim(ClaimKey(patent: openPatent, number: value)))
        case "numeral":
            guard let value else { return }
            showNumeral(value)
        default:
            break
        }
    }

    /// Where a reference numeral is introduced: the first paragraph that mentions it.
    ///
    /// "Introduced" is approximated by "first mentioned", and that is right far more often
    /// than not — a patent introduces a part where it first names it, because that is the
    /// drafting convention the numerals exist to serve.
    ///
    /// The search stays exactly what it was: a pure fact about the parsed text, over
    /// `Patent.paragraphs`, deciding *which paragraph*. What is new is the second half —
    /// the reader lands on the numeral rather than near it, because `PassageFocus.refinement`
    /// narrows within that paragraph's own bracket of the document. Searching the PDF for
    /// `130` directly would answer a different question: the numeral is in every figure
    /// caption.
    private func showNumeral(_ numeral: Int) {
        guard let patent else { return }
        let token = String(numeral)
        guard
            let paragraph = patent.paragraphs.first(where: { paragraph in
                paragraph.text.split(whereSeparator: { !$0.isNumber })
                    .contains(Substring(token))
            })
        else { return }
        if let current = openPatent, let previous = focus?.target {
            history.push(NavigationHistory.Position(patent: current, target: previous))
        }
        focus = PassageFocus(
            .paragraph(ParagraphKey(patent: patent.key, number: paragraph.number)),
            refining: token)
    }

    /// `[0042]` or `claim 7` typed into the library's find field.
    private func locate(_ kind: LibrarySearch.LocatorKind) {
        guard let openPatent else { return }
        switch kind {
        case .paragraph(let number):
            jump(to: .paragraph(ParagraphKey(patent: openPatent, number: number)))
        case .claim(let number):
            jump(to: .claim(ClaimKey(patent: openPatent, number: number)))
        }
    }

    /// A section picked from the library's outline.
    ///
    /// **Aimed at the section's first passage**, not at its heading, and the swap is what
    /// lets this work at all on the original: the PDF has no heading rows to scroll to, and
    /// anchoring headings separately would be a second kind of anchor with its own failure
    /// rate to measure. The heading is one line above the first paragraph, so the reader
    /// lands with it on screen — and the paragraph inherits the monotonic placement the
    /// whole document already computed.
    private func scrollToSection(_ index: Int) {
        guard let patent, let target = firstPassage(ofSection: index, in: patent)
        else { return }
        revealReader()
        focus = PassageFocus(target)
    }

    /// The first thing under a heading that a citation could name. `claim 1` for the
    /// outline's Claims sentinel.
    private func firstPassage(ofSection index: Int, in patent: Patent) -> CitationTarget? {
        if index == LibraryOutline.claimsSection {
            return patent.claims.first.map {
                .claim(ClaimKey(patent: patent.key, number: $0.number))
            }
        }
        guard patent.sections.indices.contains(index),
            let paragraph = patent.sections[index].paragraphs.first
        else { return nil }
        return .paragraph(ParagraphKey(patent: patent.key, number: paragraph.number))
    }

    private func goBack() {
        guard let current = openPatent else { return }
        let now = NavigationHistory.Position(patent: current, target: focus?.target)
        guard let previous = history.goBack(from: now) else { return }
        restore(previous)
    }

    private func goForward() {
        guard let current = openPatent else { return }
        let now = NavigationHistory.Position(patent: current, target: focus?.target)
        guard let next = history.goForward(from: now) else { return }
        restore(next)
    }

    private func restore(_ position: NavigationHistory.Position) {
        openPatent = position.patent
        focus = position.target.map { PassageFocus($0) }
    }

    private func recordProgress() {
        guard let patent else { return }
        ProgressStore.save(
            ReadingProgress(
                schemaVersion: ProgressStore.schemaVersion,
                patent: patent.key,
                focus: focus?.target,
                stamp: patent.source.contentSHA256))
    }

    // MARK: - Panes

    /// Hiding the answers pane hides the status strip with it, so anything running would
    /// run unannounced — and an answer nobody can read is model work spent on nothing. So
    /// the pane going away stops the current work.
    private func setAnswers(_ shown: Bool) {
        guard shown != showsAnswers else { return }
        showsAnswers = shown
        if !shown { cancel() }
    }

    /// The phone's swipe-away. A drag down is a request to see the document, not to throw
    /// the answer out, so with nothing running nothing is cleared: the answer, its
    /// transcript and its session stay.
    ///
    /// Mid generation it deliberately *is* Esc, for the reason `setAnswers(_:)` gives —
    /// an answer nobody can read is model work spent on nothing — plus one this path
    /// adds: `stopActiveWork()` discards the session, so a half-streamed answer kept on
    /// screen would let a tapped follow-up append a question whose answer never arrives.
    private func hideAnswerSheet() {
        showsAnswerSheet = false
        if isBusy { cancel() }
    }

    // MARK: - Asking

    private func clearAnswer() {
        question = nil
        scanner = nil
        runs = []
        tail = ""
        followUps = []
        transcript = []
        retrieved = []
        // The one-way half of `showsAnswerSheet`'s invariant: no answer, no sheet.
        showsAnswerSheet = false
        phase = .idle
        promptTokens = nil
        timeToFirstToken = nil
        stats = nil
        errorMessage = nil
        unsupportedQuotes = []
    }

    /// A question, from a suggested row or from the Ask field.
    ///
    /// Guarded here and not only by the pane's `.disabled`, because a Return keypress can
    /// race a phase change, and `AnswerService` overwrites its active task per call rather
    /// than serializing — a second question in flight would strand the first.
    ///
    /// **A tapped suggestion is a follow-up and a typed question is not**, and that rule
    /// is the reader's rather than a heuristic about the words. The app suggested that row
    /// *about these passages*, so it answers about these passages — same session, same KV
    /// cache, a few hundred tokens instead of the whole prompt, and a citation in the
    /// answer refers to the same set as the chips above it. A question the reader typed
    /// could be about anything in the library, so it searches again; answering it from the
    /// previous question's passages would silently scope it to whatever the last question
    /// happened to find.
    private func ask(_ raw: String, isSuggestion: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, service.isReady else { return }

        if isSuggestion, question != nil, !runs.isEmpty {
            followUp(text)
        } else {
            start(text)
        }
    }

    private func start(_ text: String) {
        clearAnswer()
        question = text
        showsAnswerSheet = true
        showsAnswers = true

        // Scoped to the selection when there is one, and to the whole library otherwise.
        // Selecting and then asking is how a reader says "about this bit", and it is the
        // only scoping gesture the app has. Either reader's selection counts, because the
        // gesture is the same one — the reader has their finger on a passage.
        //
        // **Scoped to the patent, not to the selected passages**, which is unchanged rather
        // than overlooked: `Retriever`'s scope is a `Set<PatentKey>`, and narrowing
        // retrieval to a span inside one document is a different feature with its own
        // ranking question.
        let scope: Set<PatentKey>? =
            hasOriginalSelection && openPatent != nil ? [openPatent!] : nil

        let started = Date()
        Task {
            for await event in await service.answer(
                question: text, library: library, scope: scope)
            {
                consume(event, into: nil, started: started)
            }
            scanner?.finish()
            if let scanner { runs = scanner.runs }
            tail = ""
        }
    }

    private func followUp(_ text: String) {
        let index = transcript.count
        transcript.append(.init(question: text, runs: [], tail: ""))
        followUps = []
        // A fresh scanner per turn. It accumulates committed runs and never forgets them,
        // which is what makes the first answer stable while it streams — so reusing turn
        // one's would prepend the whole first answer to every follow-up.
        scanner = nil

        Task {
            for await event in service.followUp(text) {
                consume(event, into: index, started: nil)
            }
            scanner?.finish()
            if let scanner, transcript.indices.contains(index) {
                transcript[index].runs = scanner.runs
                transcript[index].tail = ""
            }
        }
    }

    /// One event, folded into the pane's state.
    ///
    /// `into` is the transcript row a follow-up's text goes to, or `nil` for the first
    /// answer. One function rather than two nearly identical loops, because the difference
    /// between them is exactly where the prose lands.
    private func consume(_ event: AnswerEvent, into index: Int?, started: Date?) {
        switch event {
        case .cached(let entry):
            // A cache hit lands whole rather than streaming, so the scanner is fed the
            // finished text in one call — which is a case worth having: it is the only
            // path where `consume` is not called once per token, and it exercises the
            // scanner's grammar without any partials at all.
            promptTokens = entry.promptTokenCount
            feed(entry.answer, into: index)
        case .phase(let value):
            phase = value
        case .retrieved(let chunks):
            retrieved = chunks
            isLexicalOnly = service.context?.isLexicalOnly ?? false
        case .promptTokens(let count):
            promptTokens = count
        case .answer(let chunk):
            if let started, timeToFirstToken == nil {
                timeToFirstToken = Date().timeIntervalSince(started)
            }
            feed(chunk, into: index)
        case .followUps(let questions):
            followUps = questions
        case .stats(let value):
            stats = value
        case .unsupportedQuotes(let spans):
            unsupportedQuotes = spans
        case .failed(let message):
            errorMessage = message
        }
    }

    /// Streamed text into the scanner, and the scanner's output into the pane.
    ///
    /// The scanner is created lazily, on the first chunk, because it needs the retrieved
    /// set — which arrives with `.retrieved`, one event earlier.
    private func feed(_ chunk: String, into index: Int?) {
        if scanner == nil, let context = service.context {
            scanner = CitationScanner(context: context, library: library.patents)
        }
        guard scanner != nil else {
            // No context means no verdicts are decidable, so the text goes through as
            // prose rather than being held back. This is the failure path, not a mode.
            if let index, transcript.indices.contains(index) {
                transcript[index].tail += chunk
            } else {
                tail += chunk
            }
            return
        }
        scanner?.consume(chunk)
        guard let scanner else { return }
        if let index, transcript.indices.contains(index) {
            transcript[index].runs = scanner.runs
            transcript[index].tail = scanner.tail
        } else {
            runs = scanner.runs
            tail = scanner.tail
        }
    }

    private func cancel() {
        Task { await service.stopActiveWork() }
        clearAnswer()
    }
}
