// Copyright © 2026 Apple Inc.

import MLXLLM
import MLXLMCommon
import SwiftUI

@MainActor
struct ContentView: View {
    let options: AppOptions

    @State private var service: AnnotationService
    @State private var bible: Bible?
    @State private var table: BookTable?
    @State private var crossReferences: CrossReferenceStore?
    @State private var corpusError: String?

    @State private var chapterKey: ChapterKey?
    @State private var selection: VerseSelection?
    @State private var context: PassageContext?

    /// Whether the annotation sheet is up at a compact width. Deliberately *not*
    /// `context != nil`: presentation is a moment, an annotation is not. UIKit reports an
    /// interactive dismissal for a drag of a few points — even one that snaps back to
    /// `.medium` — and with the sheet bound to the annotation, that nudge would throw away
    /// the commentary, the transcript, the follow-ups and the `ChatSession` they run on.
    ///
    /// The invariant is one-way and `clearAnnotation()` holds it: no annotation, no sheet.
    /// The converse is the point — an annotation with no sheet over it is one the reader
    /// swiped away and can have back by tapping the passage again, with no model work.
    @State private var showsAnnotation = false

    /// Which side panes are on screen. Hiding them is how the reader gets the Bible on
    /// its own, so how they left them is how they come back. Persisted the same way
    /// `readerFont` is, below.
    @AppStorage("showsNavigator") private var showsNavigator = true
    @AppStorage("showsCommentary") private var showsCommentary = true

    /// Whether Challoner's notes are rendered inline under the verses they annotate.
    ///
    /// **Default on**, and that default is the app's thesis. The Douay-Rheims ships with
    /// 1,772 verse-anchored notes by the editor whose revision this is; showing them is
    /// what makes this a Challoner study Bible rather than a plain text with a model
    /// bolted to it. A reader who wants the bare text can turn them off, and then the
    /// model does not see them either — see `ChapterReaderView.rows`.
    @AppStorage("showsNotes") private var showsNotes = true

    /// What the navigator has open. Lives here, not in `NavigatorView`, so it survives
    /// hiding the pane. Not persisted and not seeded: it follows the reading position,
    /// so the restored `chapterKey` implies it at launch.
    @State private var outline = NavigatorOutline()

    /// The face the *scripture* is set in; everything else stays on the system face.
    @AppStorage("readerFont") private var readerFont: ReaderFont = .system

    /// How large that text is set. Separate in storage from `readerFont`, because a
    /// reader who picks Baskerville does not want their size reset with it.
    @AppStorage("readerTextSize") private var readerTextSize: ReaderTextSize = .default

    /// Read here, and only so that the reader's typeface is rebuilt when the reader moves
    /// the Larger Text slider. At a non-default `readerTextSize` the text is drawn with a
    /// *fixed-size* `Font.system(size:)`, which does not follow Dynamic Type on its own —
    /// `ReaderFont.systemSize(_:at:)` does the scaling instead, and it needs the category
    /// to do it. Always `.large` on macOS.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Kept under `#if` because the macOS branch never reads it: `horizontalSizeClass`
    /// being on the macOS SDK is not something to bet the build on, and `isRegularWidth`
    /// below answers the question there without it.
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether there is room for the panes side by side, which is the *only* axis the
    /// layout forks on.
    ///
    /// Deliberately not `UIDevice.userInterfaceIdiom`. An iPad in Slide Over or a narrow
    /// Stage Manager window is compact and has to behave exactly like a phone, and it
    /// becomes compact and regular again *while the app is running* — branching on the
    /// device would stretch the three-pane layout across 320 points and never recover.
    ///
    /// Always `true` on a Mac, where a window narrow enough to matter is unreachable:
    /// `BibleReaderApp` floors it at 1080, which is over the 1010 the three panes need.
    private var isRegularWidth: Bool {
        #if os(macOS)
            true
        #else
            horizontalSizeClass == .regular
        #endif
    }

    /// Off by default: the model name, the load check and the latency numbers are for
    /// working on the app, not for reading. Forced on for a launch by `--diagnostics`.
    @AppStorage("showsDiagnostics") private var diagnosticsPreference = false

    private var showsDiagnostics: Bool { diagnosticsPreference || options.diagnostics }

    /// Which families are installed, and the on-demand download for Garamond.
    @State private var fonts = ReaderFontLibrary()

    /// The view the system dictionary panel is popped over, installed in the reader
    /// pane's background by `readerPane(book:key:chapter:)`.
    @State private var dictionaryAnchor = DictionaryAnchor()

    /// A word question waiting for a passage.
    ///
    /// `ask(_:)` needs a `context` and an idle model, so a word right-clicked in a verse
    /// that is not currently annotated cannot be asked about straight away: the passage
    /// has to be selected and annotated first. One optional and a single deterministic
    /// firing point — the end of `start(_:ignoringCache:)`'s `Task` — rather than watching
    /// `isBusy` change, which would fire on whichever transition happened to come first.
    @State private var pendingWordQuestion: String?

    /// Where the reader has been, for ⌘[.
    ///
    /// Only cross-reference jumps and navigator moves push onto it, not arrow-key rolls:
    /// a back stack that records every keypress is not a back stack. It exists because
    /// following Romans 4:3 to Genesis 15:6 is a one-tap move and getting back should be
    /// one too.
    @State private var history = NavigationHistory()

    /// The row a same-chapter jump wants on screen, handed to `ChapterReaderView` and
    /// cleared there as it is spent. See its `reveal` binding for why `selection` alone is
    /// not enough.
    @State private var revealRow: Int?

    @State private var commentary = ""
    @State private var followUps: [String] = []
    @State private var transcript: [AnnotationPaneView.Exchange] = []
    @State private var phase: Phase = .idle

    /// Quoted spans the model produced that are not in the selected passage.
    /// Diagnostics only — `QuoteCheck` reports and never strips, so this changes nothing
    /// the reader is shown.
    @State private var unsupportedQuotes: [String] = []
    /// Quoted spans that are nowhere in the Bible at all. Strictly worse.
    @State private var inventedQuotes: [String] = []
    /// Every reference the model named, with its verdict. The one check whose result
    /// reaches the reader rather than only the diagnostics strip.
    @State private var references: [CheckedReference] = []
    @State private var unverifiedCitations: [String] = []
    @State private var promptTokens: Int?
    @State private var timeToFirstToken: TimeInterval?
    @State private var stats: GenerationStats?
    @State private var errorMessage: String?

    init(options: AppOptions) {
        self.options = options
        _service = State(
            initialValue: AnnotationService(
                modelID: options.modelID ?? LLMRegistry.qwen3_4b_4bit.name,
                greedy: options.greedy))
    }

    var body: some View {
        layout
            // Installed above the split view so both panes inherit it, and it is what
            // keeps a `drb://` link inside the process: `OpenURLAction` is offered the URL
            // before the system is, so nothing has to be registered in either
            // `Info.plist`. Anything that is not ours falls through to `.systemAction`
            // rather than being swallowed.
            //
            // `pushingHistory: true` is what the `SEE ALSO` buttons already pass, so ⌘[,
            // the toolbar's Back and the iOS overflow menu all work on an inline link with
            // no further change.
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard url.scheme == ReferenceLinks.scheme,
                        let reference = ReferenceLinks.reference(url)
                    else { return .systemAction }
                    open(reference, pushingHistory: true)
                    return .handled
                }
            )
            .task {
                loadCorpus()
                await service.load()
            }
            // Recorded here rather than inside `openChapter(_:)`, so every path that
            // moves the reader is caught, including an arrow-key move, which comes back
            // through `ChapterReaderView`'s `$selection` binding and never calls it. No
            // debounce: CFPreferences coalesces writes, so a held arrow key is not a
            // per-keypress disk hit.
            //
            // The navigator follows from here for the same reason, and this is also what
            // seeds it: `loadCorpus()` writes the restored key into a `chapterKey` that
            // started `nil`, so a launch opens the outline at the chapter coming back.
            .onChange(of: chapterKey) {
                recordProgress()
                if let chapterKey, let bible {
                    outline = .following(chapterKey, in: bible)
                }
            }
            .onChange(of: selection) { recordProgress() }
            .onChange(of: showsNotes) {
                // Turning notes on or off renumbers every row below the first note, and a
                // selection is a pair of row indices. Keeping it would silently move the
                // highlight onto different verses, so it goes.
                selection = nil
            }
    }

    // MARK: - Layout

    /// The one place the two platforms genuinely diverge. Both branches build their panes
    /// from the same three `@ViewBuilder` helpers below, so what differs here is the
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
            if let bible, let table, let chapterKey,
                let book = bible.book(chapterKey.bookID),
                let chapter = bible.chapter(chapterKey)
            {
                // The side panes are fixed widths, and that is what keeps the navigator
                // still. `HSplitView` distributes width from each child's min / ideal /
                // max, and it will move *any* pane that has room between them: a
                // `maxWidth` caps how far a pane can grow but leaves it just as free to be
                // shrunk. Pinning the sides leaves the reader as the only pane with any
                // give, so it absorbs the whole difference and the dividers never move.
                //
                // The cost is that the dividers are no longer draggable. 210 + 380 here
                // plus the reader's 420 floor is the 1010 that sets the window minimum in
                // `BibleReaderApp`.
                HSplitView {
                    if showsNavigator {
                        navigatorPane(bible: bible, table: table, key: chapterKey)
                            .frame(width: 210)
                    }

                    readerPane(bible: bible, book: book, key: chapterKey, chapter: chapter)
                        // The only pane with any flexibility, so every width change lands
                        // here. The explicit `idealWidth` keeps the chapter heading from
                        // proposing the window's preferred width: without one this frame
                        // propagates the child's own ideal, which is the full single-line
                        // width of whichever Challoner argument happens to be on screen —
                        // and those run to a full sentence.
                        .frame(minWidth: 420, idealWidth: 640, maxWidth: .infinity)

                    if showsCommentary {
                        commentaryPane().frame(width: 380)
                    }
                }
            } else if let corpusError {
                failure(corpusError)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    #else
        /// Navigator and reader as the two columns of a `NavigationSplitView`, which a
        /// compact width renders collapsed — so there it is a push from the book list to
        /// the reader with the system's own back button standing in for ⌘1 — and a regular
        /// width renders as two columns side by side the way the Mac's `HSplitView` does.
        ///
        /// Which of the two bindings below is live follows from that, and only one ever
        /// is: `navigatorVisibility` at regular width, `navigatorColumn` once collapsed.
        ///
        /// The commentary is an `.inspector` because that one container is both shapes: it
        /// auto-presents as a **sheet** at a compact width, where the text stays on screen
        /// above the annotation — the whole point of the three-pane desktop layout and the
        /// one part of it worth keeping on a phone — and as a trailing **column** at a
        /// regular width, which is the desktop layout itself.
        @ViewBuilder
        private var phonePanes: some View {
            NavigationSplitView(
                columnVisibility: navigatorVisibility,
                preferredCompactColumn: navigatorColumn
            ) {
                Group {
                    if let bible, let table, let chapterKey {
                        navigatorPane(bible: bible, table: table, key: chapterKey)
                    } else if let corpusError {
                        failure(corpusError)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle("Books")
            } detail: {
                Group {
                    if let bible, let chapterKey,
                        let book = bible.book(chapterKey.bookID),
                        let chapter = bible.chapter(chapterKey)
                    {
                        readerPane(
                            bible: bible, book: book, key: chapterKey, chapter: chapter
                        )
                        .navigationTitle(book.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { readerToolbar }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .inspector(isPresented: commentaryPresented) {
                commentaryPane()
            }
        }

        /// Which flag the commentary answers to, which is the whole of the difference
        /// between the two widths.
        ///
        /// Regular width routes through `setCommentary(_:)` rather than writing
        /// `showsCommentary` directly, and that is the point of it: that function already
        /// stops live work when the pane goes away and picks a pending selection back up
        /// when it returns, and it already guards on `shown != showsCommentary` so it is
        /// idempotent under SwiftUI's repeated writes.
        ///
        /// Compact width ignores a `true` write: the sheet is raised by `commit` and by
        /// nothing else, so there is no path that presents it from out here.
        private var commentaryPresented: Binding<Bool> {
            Binding(
                get: { isRegularWidth ? showsCommentary : showsAnnotation },
                set: { shown in
                    if isRegularWidth {
                        setCommentary(shown)
                    } else if !shown {
                        hideAnnotation()
                    }
                })
        }

        /// The persisted navigator preference, in the shape a *regular-width* split view
        /// acts on. `navigatorColumn` below is the same flag in the shape a collapsed one
        /// acts on, and between them the stored `Bool` drives both layouts.
        ///
        /// `.all` and not `.doubleColumn`: in a two-column split view they mean the same
        /// thing, and `.all` is the one that reads as "both columns". The setter tests
        /// `!= .detailOnly` rather than `== .all` because SwiftUI writes `.automatic`
        /// back, which at a regular width means both columns showing.
        private var navigatorVisibility: Binding<NavigationSplitViewVisibility> {
            Binding(
                get: { showsNavigator || corpusError != nil ? .all : .detailOnly },
                set: { showsNavigator = $0 != .detailOnly })
        }

        /// The same preference, in the shape a *collapsed* split view acts on.
        ///
        /// `columnVisibility:` is ignored once the split view collapses, which is every
        /// iPhone and an iPad at a compact width. `preferredCompactColumn:` is the two-way
        /// one: writing `.detail` pushes the reader, and SwiftUI writes `.sidebar` back
        /// when the reader taps the system back button.
        private var navigatorColumn: Binding<NavigationSplitViewColumn> {
            Binding(
                get: { showsNavigator || corpusError != nil ? .sidebar : .detail },
                set: {
                    // The guard is what keeps two bindings over one flag from fighting. At
                    // a regular width the pop this setter exists for does not happen, and a
                    // write arriving *during* a size-class transition would set
                    // `showsNavigator` from a column preference the split view is no longer
                    // acting on — collapsing the sidebar the reader can see.
                    guard !isRegularWidth else { return }
                    showsNavigator = $0 == .sidebar
                    // The pop is the phone's ⌘1, and on a Mac ⌘1 leaves the commentary
                    // alone because the two panes are side by side. Here the sheet is
                    // over the *split view*, not over the reader column, so it outlives
                    // the column it belongs to and ends up citing verses from a chapter
                    // that is no longer on screen. `hideAnnotation()` rather than
                    // `cancel()`: leaving the reader is not throwing the annotation out,
                    // and a re-tap of the still-highlighted passage brings it back with
                    // no model work.
                    if $0 == .sidebar { hideAnnotation() }
                })
        }
    #endif

    // MARK: - Panes

    @ViewBuilder
    private func navigatorPane(bible: Bible, table: BookTable, key: ChapterKey)
        -> some View
    {
        NavigatorView(
            bible: bible,
            table: table,
            key: Binding(get: { key }, set: { openChapter($0) }),
            outline: $outline,
            onOpen: { open($0) })
    }

    @ViewBuilder
    private func readerPane(bible: Bible, book: Book, key: ChapterKey, chapter: Chapter)
        -> some View
    {
        ChapterReaderView(
            book: book, key: key, chapter: chapter,
            selection: $selection,
            reveal: $revealRow,
            showsNotes: showsNotes,
            onCommit: { selection, origin in
                commit(
                    selection, book: book, key: key, chapter: chapter,
                    revealingCommentary: origin == .pointer)
            },
            onCancel: { cancel() },
            onRegenerate: { regenerate() },
            onStepChapter: { step in stepChapter(step, in: bible) },
            onGoBack: { goBack() },
            canGoBack: history.canGoBack,
            onLookUpWord: { term, point in lookUpInDictionary(term, at: point) },
            onExplainWord: { term, row in explainWord(term, atRow: row) },
            noteLinks: { row in
                // Notes only. A verse of this edition carries no cross-references, and
                // keeping 35,805 of the 37,000-odd rows out of the link machinery is what
                // keeps the sweep gesture uncontested everywhere it matters.
                guard let table, row.kind == .note else { return [] }
                return ReferenceLinks.resolvable(
                    row.displayText, in: book, chapter: chapter.number, bible: bible,
                    table: table)
            }
        )
        .environment(
            \.readerTypeface,
            fonts.typeface(
                for: readerFont, textSize: readerTextSize,
                dynamicTypeSize: dynamicTypeSize)
        )
        // The dictionary panel needs an `NSView` to be popped over and a point to be
        // popped at, and this is both: the anchor fills the reader pane, so the space
        // registered here *is* the anchor's own coordinate system, and a word's baseline
        // origin resolved in a `VerseRow` can be spent against it unconverted. It draws
        // nothing and takes no clicks.
        .coordinateSpace(name: DictionaryAnchor.space)
        .background { DictionaryAnchorView(anchor: dictionaryAnchor) }
    }

    @ViewBuilder
    private func commentaryPane() -> some View {
        VStack(spacing: 0) {
            AnnotationPaneView(
                citation: context?.citation,
                selectedVerses: context?.selected ?? [],
                commentary: commentary,
                followUps: followUps,
                transcript: transcript,
                isBusy: isBusy,
                references: references,
                unverifiedCitations: unverifiedCitations,
                onAsk: ask,
                onOpen: { open($0, pushingHistory: true) },
                link: { prose in
                    guard let bible, let table else { return AttributedString(prose) }
                    return ReferenceLinks.modelProse(prose, bible: bible, table: table)
                },
                linkNote: { text in
                    // Challoner's echoed notes, read in the context of the passage they
                    // were selected from — which is what `chap. 5.3` and `ver. 16` mean
                    // relative to.
                    guard let bible, let table, let chapterKey,
                        let book = bible.book(chapterKey.bookID)
                    else { return AttributedString(text) }
                    return ReferenceLinks.note(
                        text, in: book, chapter: chapterKey.chapter, bible: bible,
                        table: table)
                })
            // Both go together: a divider with nothing under it would leave an empty
            // band at the foot of the pane.
            if showsDiagnostics || errorMessage != nil {
                Divider()
                statusStrip
            }
        }
        // Half height by default, which is the entire reason the commentary is an
        // `.inspector` rather than a plain `.sheet`: at `.medium` the text is still on
        // screen above the annotation, which is what the third pane does on a Mac.
        // Without these the inspector presents at full height at a compact width and the
        // passage being annotated disappears behind its own annotation.
        //
        // `presentationBackgroundInteraction` is the other half: at `.medium` the reader
        // can tap the next verse without dismissing the sheet first, so moving through a
        // chapter stays one tap per passage the way it is on a Mac.
        #if !os(macOS)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        #endif
    }

    // MARK: - Header

    #if os(macOS)
        @ViewBuilder
        private var header: some View {
            HStack(spacing: 10) {
                paneToggle(
                    "the book list", systemImage: "sidebar.leading", shortcut: "1",
                    isVisible: showsNavigator
                ) {
                    showsNavigator.toggle()
                }

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
                    "the commentary", systemImage: "sidebar.trailing", shortcut: "2",
                    isVisible: showsCommentary
                ) {
                    setCommentary(!showsCommentary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    #else
        /// The header's controls, in a navigation bar instead.
        ///
        /// Copy, Clear and Select Chapter move into the overflow menu because ⌘C, Esc and
        /// ⌘A are not keys a touch device has, and they are the reason this file, not
        /// `ChapterReaderView`, owns that menu: the selection they act on lives here.
        @ToolbarContentBuilder
        private var readerToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                loadStateIndicator
                typefaceMenu
                if isRegularWidth {
                    paneToggle(
                        "the commentary", systemImage: "sidebar.trailing", shortcut: "2",
                        isVisible: showsCommentary
                    ) {
                        setCommentary(!showsCommentary)
                    }
                }
                overflowMenu
            }
        }

        @ViewBuilder
        private var overflowMenu: some View {
            Menu {
                Button("Regenerate", systemImage: "arrow.clockwise") { regenerate() }
                    .disabled(selection == nil || isBusy)
                Button("Select chapter", systemImage: "text.justify") { selectChapter() }
                Button("Copy passage", systemImage: "doc.on.doc") { copySelection() }
                    .disabled(selection == nil)
                Button("Clear selection", systemImage: "xmark") { clearSelection() }
                    .disabled(selection == nil)
                Button("Back", systemImage: "chevron.backward") { goBack() }
                    .disabled(!history.canGoBack)
                Divider()
                Toggle("Show Challoner's notes", isOn: $showsNotes)
                Toggle("Show diagnostics", isOn: $diagnosticsPreference)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenu()
            .accessibilityLabel("More")
        }

        /// ⌘A's counterpart.
        private func selectChapter() {
            guard let rows = renderedRows() else { return }
            selection = VerseSelection.chapter(rows)
        }

        /// ⌘C's counterpart. `ChapterReaderView` cannot own this the way it owns
        /// `copyItem()`: the menu is in the navigation bar, which is this view's.
        private func copySelection() {
            guard let bible, let chapterKey, let selection,
                let book = bible.book(chapterKey.bookID),
                let chapter = bible.chapter(chapterKey),
                let rows = renderedRows(),
                let range = selection.clamped(to: rows)?.range
            else { return }
            let rendered = Chapter(
                number: chapter.number, latinIncipit: chapter.latinIncipit,
                argument: chapter.argument, rows: rows)
            copyToPasteboard(
                Citation.quotation(book: book, chapter: rendered, range: range))
        }
    #endif

    /// The rows the reader can actually see, which is what a selection indexes into.
    /// Restates `ChapterReaderView.rows` because the toolbar lives out here.
    private func renderedRows() -> [Row]? {
        guard let bible, let chapterKey, let chapter = bible.chapter(chapterKey)
        else { return nil }
        return showsNotes ? chapter.rows : chapter.rows.filter { $0.kind != .note }
    }

    /// The face and size the Bible is set in, and whether Challoner's notes show. Sits
    /// with the reader's own controls rather than with the model capsule, because that is
    /// what it changes.
    ///
    /// A `Menu` and **not** a `Picker`: picker rows are selection tags with nowhere to
    /// hang a download or a retry affordance, and a per-row `.font()` would not preview
    /// anything anyway — inside a menu it goes through `NSMenuItem`, which takes its title
    /// font from the menu.
    ///
    /// `Toggle` rather than `Button`, because an `NSMenuItem` has exactly **one** image
    /// slot and SwiftUI puts a `Button` label's leading `Image` in it. A hand-drawn
    /// checkmark would therefore *displace* the status glyph on the selected row — which
    /// is precisely the row whose download state matters, since `choose(_:)` selects and
    /// downloads together.
    ///
    /// Nothing is ever disabled. A disabled `NSMenuItem` shows no tooltip on macOS, so a
    /// greyed row with `.help()` attached would communicate nothing at all, and a row that
    /// failed to download stays tappable so choosing it again retries.
    @ViewBuilder
    private var typefaceMenu: some View {
        Menu {
            Section("Typeface") {
                // `offered`, not `allCases`: the two iOS-only families would be dead rows
                // on a Mac and Big Caslon and Garamond are unresolvable on a phone.
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
                            set: { _ in readerTextSize = size })
                    )
                }
            }

            Section("Text") {
                Toggle("Challoner's notes", isOn: $showsNotes)
            }
        } label: {
            Image(systemName: "textformat")
        }
        // `Menu` ignores `.buttonStyle(.borderless)`, hence `.menuStyle`; and
        // `.fixedSize()` stops a borderless-button menu claiming more width than its label
        // needs.
        .borderlessMenu()
        .fixedSize()
        .help("The face and size the text is set in")
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
            .help("Show the model, the load check and the latency numbers")
            .accessibilityLabel("Diagnostics")
        }
    #endif

    /// `nil` for a family that is installed and idle, which is the ordinary case and wants
    /// no glyph at all.
    ///
    /// A filled arrow for in flight rather than a `ProgressView`: a menu row *is* an
    /// `NSMenuItem`, which takes an image and not a view, so a spinner has nowhere to
    /// render and silently disappears.
    private func statusGlyph(_ font: ReaderFont) -> String? {
        if fonts.failed[font] != nil { return "exclamationmark.triangle" }
        if fonts.downloading.contains(font) { return "arrow.down.circle.fill" }
        return fonts.isAvailable(font) ? nil : "arrow.down.circle"
    }

    /// Picking a family that is not installed starts its download as well as selecting it.
    /// Until the family lands the reader sees the system face, because
    /// `ReaderTypeface.familyName` stays nil until then.
    private func choose(_ font: ReaderFont) {
        readerFont = font
        if !fonts.isAvailable(font) { fonts.download(font) }
    }

    /// The two pane toggles. `.command` shortcuts rather than menu items, because the app
    /// has no menu of its own to add them to.
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
                    // no 120 points to spare, where a Mac header and a regular-width iPad
                    // bar both do. The percentage alone carries the same information.
                    if isRegularWidth {
                        ProgressView(value: progress.fractionCompleted)
                            .frame(width: 120)
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
            // Also never hidden: without this the reader gets a Bible that silently
            // refuses to annotate anything.
            Label("Load failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private var shortModelName: String {
        service.modelID.split(separator: "/").last.map(String.init) ?? service.modelID
    }

    // MARK: - Status strip

    /// With diagnostics on, every wait gets a name and the numbers that decide whether the
    /// prompt needs shedding are on screen rather than in a log. With them off the strip is
    /// nothing but a place for a failure to be reported.
    @ViewBuilder
    private var statusStrip: some View {
        if showsDiagnostics {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    switch phase {
                    case .idle:
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                        Text(selection == nil ? "Idle" : "Done")
                    case .cached:
                        Image(systemName: "bolt.fill").foregroundStyle(.green)
                        Text("Cached")
                    case .prefilling:
                        ProgressView().controlSize(.small)
                        Text("Prefilling…")
                    case .streaming:
                        Image(systemName: "text.cursor")
                        Text("Annotating")
                    case .listingFollowUps:
                        ProgressView().controlSize(.small)
                        Text("Finding what to ask next…")
                    case .answering:
                        Image(systemName: "text.cursor")
                        Text("Answering")
                    case .revising:
                        ProgressView().controlSize(.small)
                        Text("Revising the answer…")
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

                // The three reference verdicts, counted. This is the number that says
                // whether a prompt change made the model more or less inventive, and it
                // is the only one of the four checks whose result the reader also sees.
                if let counters = referenceCounters {
                    Text(counters)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if !unsupportedQuotes.isEmpty {
                    // Reported, never corrected. A quotation the selected passage does
                    // not contain is evidence about a prompt, and hiding it to tidy the
                    // output would spend the signal.
                    Text(
                        "not in the passage: "
                            + unsupportedQuotes.map { "“\($0)”" }.joined(separator: ", ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }

                if !inventedQuotes.isEmpty {
                    // Strictly worse than the line above: not merely outside the passage
                    // but outside the Bible.
                    Text(
                        "not in this Bible at all: "
                            + inventedQuotes.map { "“\($0)”" }.joined(separator: ", ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.red)
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

    private var referenceCounters: String? {
        guard !references.isEmpty || !unverifiedCitations.isEmpty else { return nil }
        var parts: [String] = []
        for verdict in [CheckedReference.Verdict.ok, .ungiven, .nonexistent] {
            let count = references.count { $0.verdict == verdict }
            if count > 0 { parts.append("\(count) \(verdict.rawValue)") }
        }
        if !unverifiedCitations.isEmpty {
            parts.append("\(unverifiedCitations.count) unverified citation")
        }
        return parts.isEmpty ? nil : "refs: " + parts.joined(separator: " · ")
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

    @ViewBuilder
    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Corpus

    private func loadCorpus() {
        guard bible == nil else { return }
        do {
            let loaded = try CorpusLoader.load()
            let names = BookTable(loaded)
            bible = loaded
            table = names
            crossReferences = CrossReferenceStore(bible: loaded, table: names)
            // The checks need the corpus to resolve a reference against, and building the
            // normalized haystack is a tenth of a second — paid once, here, rather than
            // on the first annotation.
            service.ground(AnnotationService.Grounding(bible: loaded, table: names))
            // Back where the reader left off, or Genesis 1 on a cold start.
            let opening = loaded.opening(from: ProgressStore.progress())
            chapterKey = opening.key
            selection = opening.selection
        } catch {
            corpusError = error.localizedDescription
        }
    }

    /// Records the position, for the next launch to open on. The stamp is the book's own
    /// source digest, so a rebuilt corpus can tell that the stored indices are no longer
    /// indices into the same rows.
    private func recordProgress() {
        guard let bible, let chapterKey, let book = bible.book(chapterKey.bookID)
        else { return }
        ProgressStore.save(
            ReadingProgress(
                schemaVersion: ProgressStore.schemaVersion,
                key: chapterKey,
                selection: selection,
                corpusStamp: book.source.textSHA256))
    }

    /// Brings the reader on screen, at the width where it is not already.
    ///
    /// `#if`-free at the call site and conditional here. At a regular width all three
    /// panes are already up, so hiding the navigator on every click would be the opposite
    /// of what a click asks for. That guard carries more than it looks: `openChapter(_:)`
    /// calls this *above* its `key != chapterKey` guard, so without it every tap in the
    /// book list would collapse the sidebar out from under the reader.
    private func revealReader() {
        guard !isRegularWidth else { return }
        showsNavigator = false
    }

    private func openChapter(_ key: ChapterKey) {
        // Above the guard: a tap on the chapter already open is a request to *see* it, and
        // on a phone that is a push. `List(selection:)` does call its setter for a tap on
        // the row it has already selected, so this is that tap arriving.
        revealReader()
        // Everything below is a chapter *change*. A re-tap must not reach `selection = nil`
        // / `clearAnnotation()`: the same "a re-tap is not a new request" rule a re-tapped
        // annotated verse follows, which also makes a duplicate call harmless.
        guard key != chapterKey else { return }
        chapterKey = key
        selection = nil
        clearAnnotation()
    }

    /// Opening a reference, which may name a verse and not just a chapter.
    ///
    /// The other half of the find field's reference parser, and — from Phase 4 — of a
    /// tappable cross-reference in the commentary pane. Selecting the verse is the point:
    /// jumping to Romans 4 and leaving the reader to find verse 3 is not what they asked
    /// for.
    private func open(_ reference: ScriptureReference, pushingHistory: Bool = false) {
        guard let bible else { return }
        if pushingHistory, let chapterKey {
            history.push(NavigationHistory.Entry(key: chapterKey, selection: selection))
        }
        let wasAlreadyOpen = chapterKey == reference.chapterKey
        openChapter(reference.chapterKey)
        guard let index = rowIndex(of: reference, in: bible) else { return }
        let last = reference.lastVerse.flatMap {
            rowIndex(
                of: ScriptureReference(
                    bookID: reference.bookID, chapter: reference.chapter, verse: $0),
                in: bible)
        }
        selection = VerseSelection(anchor: index, head: last ?? index)
        // Only for a jump *inside* the chapter already open. A chapter change rebuilds
        // the reader's scroll view under `.id(key)`, and its `.onAppear` already puts the
        // selection on screen; asking for both would be two scrolls racing.
        if wasAlreadyOpen { revealRow = index }
    }

    /// A reference's row index **in the rendered rows**, which is what a selection holds.
    ///
    /// Not `Bible.rowIndex(of:)`, which indexes `chapter.rows`: with Challoner's notes
    /// hidden the two disagree by one per note above the verse, and a cross-reference that
    /// landed a few rows off would be worse than one that did not resolve at all.
    private func rowIndex(of reference: ScriptureReference, in bible: Bible) -> Int? {
        guard let chapter = bible.chapter(reference.chapterKey) else { return nil }
        let rows = showsNotes ? chapter.rows : chapter.rows.filter { $0.kind != .note }
        guard let verse = reference.verse else {
            return rows.firstIndex { $0.isVerse }
        }
        return rows.firstIndex { $0.isVerse && $0.number == verse }
    }

    /// An arrow key that ran off the edge of a chapter: `+1` opens the next chapter on its
    /// first row, `-1` the previous one on its last.
    ///
    /// Scoped to the current book. `chapterKeys` is flat across the whole corpus, and
    /// running off the end of Genesis into Exodus is a bigger jump than an arrow key
    /// should make, so both ends of the book just stop.
    private func stepChapter(_ step: Int, in bible: Bible) {
        guard let chapterKey else { return }
        let keys = bible.chapterKeys.filter { $0.bookID == chapterKey.bookID }
        guard let at = keys.firstIndex(of: chapterKey) else { return }
        let next = at + step
        guard keys.indices.contains(next), let chapter = bible.chapter(keys[next]) else {
            return
        }

        openChapter(keys[next])
        // After `openChapter`, which nils it: the edge row being arrowed onto.
        let rows = showsNotes ? chapter.rows : chapter.rows.filter { $0.kind != .note }
        guard !rows.isEmpty else { return }
        selection = VerseSelection(at: step > 0 ? 0 : rows.count - 1)
    }

    // MARK: - Panes

    /// Hiding the commentary hides the status strip with it, so anything running would run
    /// unannounced — and an annotation nobody can read is model work spent on nothing. So
    /// the pane going away stops the current work, and coming back picks up where the
    /// reader left off.
    ///
    /// This is the *deliberate* way back, for a reader who wants the pane again without
    /// choosing a new passage; `commit(revealingCommentary:)` is the other, where pointing
    /// at a passage brings the pane along with it.
    private func setCommentary(_ shown: Bool) {
        guard shown != showsCommentary else { return }
        showsCommentary = shown

        guard shown else {
            cancel()
            return
        }
        // A selection made while the pane was hidden is exactly what the reader wants
        // annotated now.
        guard let bible, let chapterKey, let selection,
            let book = bible.book(chapterKey.bookID),
            let chapter = bible.chapter(chapterKey)
        else { return }
        commit(selection, book: book, key: chapterKey, chapter: chapter)
    }

    // MARK: - Annotation

    private func clearAnnotation() {
        context = nil
        // The one-way half of `showsAnnotation`'s invariant: no annotation, no sheet. It
        // belongs here rather than in `cancel()` because `openChapter(_:)` clears without
        // cancelling, and a sheet left up across a chapter change would show a citation
        // from the chapter just left. It is also why `commit`'s raise comes *after* this.
        showsAnnotation = false
        commentary = ""
        followUps = []
        transcript = []
        phase = .idle
        unsupportedQuotes = []
        inventedQuotes = []
        references = []
        unverifiedCitations = []
        promptTokens = nil
        timeToFirstToken = nil
        stats = nil
        errorMessage = nil
    }

    private func commit(
        _ selection: VerseSelection, book: Book, key: ChapterKey, chapter: Chapter,
        ignoringCache: Bool = false, revealingCommentary: Bool = false
    ) {
        // A pointer selection is a request to have that passage annotated, so it brings
        // the commentary back if the reader had it hidden. Selecting from the keyboard
        // does not: arrow keys are how you move through a chapter with the Bible on its
        // own, and ⌘C on a hidden pane is how you copy a quote without generating
        // anything. ⌘2 still picks the pending selection up by hand.
        guard showsCommentary || revealingCommentary, service.isReady else { return }
        guard let rows = renderedRows(),
            let built = PassageContext.build(
                book: book, key: key, chapter: chapter, rows: rows,
                selection: selection, crossReferences: crossReferences)
        else { return }

        if options.showPrompt {
            print(Prompts.annotationRequest(built))
        }

        // A tap on the passage already in the pane is not a new request. Rebuilding it
        // would blank the body, cancel a live generation, re-read the same JSON off disk
        // and throw away the session the follow-ups run on — a flicker that ends where it
        // started. Two deliberate exceptions: ⌘R (`ignoringCache`) is how a finished
        // annotation is asked for again, and a passage with nothing on screen — one that
        // failed, or was stopped before its first token — is worth another attempt.
        if !ignoringCache, let current = context, current.isSamePassage(as: built),
            isBusy || !commentary.isEmpty
        {
            if revealingCommentary { showsCommentary = true }
            // Load-bearing, not defensive: a swipe-away leaves a finished annotation in
            // place, so a re-tap of that passage lands *here*, and without this the tap
            // would do nothing and the reader would have no way back to it.
            showsAnnotation = true
            // A queued word question would otherwise wait for a stream that is not going
            // to start, and then be answered about whichever passage is annotated next.
            if !isBusy, let question = pendingWordQuestion {
                pendingWordQuestion = nil
                ask(question)
            }
            return
        }

        // Only now: there is a passage to put in the pane.
        if revealingCommentary { showsCommentary = true }
        clearAnnotation()
        context = built
        // After the clear, which lowers it, and in the same update as `context` so there
        // is no dismiss-then-present flicker.
        showsAnnotation = true
        start(built, ignoringCache: ignoringCache)
    }

    /// ⌘R. Resolves the chapter from state at the moment it runs rather than closing over
    /// the values this body was built with, because the shortcut hangs off a hidden
    /// `Button` inside `ChapterReaderView`'s `.background`, and that button keeps the
    /// action it was created with. Reading `@State` through a stale copy of this struct is
    /// safe — the storage is shared.
    private func regenerate() {
        guard let bible, let chapterKey, let selection,
            let book = bible.book(chapterKey.bookID),
            let chapter = bible.chapter(chapterKey)
        else { return }
        commit(
            selection, book: book, key: chapterKey, chapter: chapter,
            ignoringCache: true)
    }

    private func start(_ built: PassageContext, ignoringCache: Bool) {
        let started = Date()
        Task {
            for await event in await service.annotate(built, ignoringCache: ignoringCache) {
                switch event {
                case .cached(let entry):
                    commentary = entry.commentary
                    promptTokens = entry.promptTokenCount
                case .phase(let value):
                    phase = value
                case .promptTokens(let count):
                    promptTokens = count
                case .commentary(let chunk):
                    if timeToFirstToken == nil {
                        timeToFirstToken = Date().timeIntervalSince(started)
                    }
                    commentary += chunk
                case .answer:
                    break
                case .followUps(let questions):
                    followUps = questions
                case .stats(let value):
                    stats = value
                case .followUpStats:
                    // The follow-up turn's numbers are for `--benchmark`; showing them
                    // here would replace the reader's own request with a 40-token prefill.
                    break
                case .unsupportedQuotes(let spans):
                    unsupportedQuotes = spans
                case .invented(let spans):
                    inventedQuotes = spans
                case .references(let checked):
                    references = checked
                case .unverifiedCitations(let citations):
                    unverifiedCitations = citations
                case .failed(let message):
                    errorMessage = message
                }
            }
            // The one place a queued word question is fired. By here the service's stream
            // has closed, which means its final `.phase(.idle)` has already landed, so
            // `ask(_:)`'s `!isBusy` guard passes.
            if let question = pendingWordQuestion {
                pendingWordQuestion = nil
                ask(question)
            }
        }
    }

    /// Guarded here and not only by the pane's `.disabled`, because a Return keypress can
    /// race a phase change, and `AnnotationService` overwrites its active task per call
    /// rather than serializing — a second ask in flight would strand the first.
    private func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy, context != nil else { return }

        let index = transcript.count
        transcript.append(.init(question: question, answer: ""))
        followUps = []

        Task {
            for await event in service.answer(question) {
                switch event {
                case .phase(let value):
                    phase = value
                case .answer(let chunk):
                    transcript[index].answer += chunk
                case .followUps(let questions):
                    followUps = questions
                case .stats(let value):
                    stats = value
                case .unsupportedQuotes(let spans):
                    unsupportedQuotes = spans
                case .invented(let spans):
                    inventedQuotes = spans
                case .references(let checked):
                    references = checked
                case .unverifiedCitations(let citations):
                    unverifiedCitations = citations
                case .failed(let message):
                    errorMessage = message
                default:
                    break
                }
            }
        }
    }

    /// The phone's swipe-away. A drag down is a request to see the text, not to throw the
    /// annotation out, so with nothing running nothing is cleared: the annotation, its
    /// transcript and its session stay, and tapping the still-highlighted passage raises
    /// the sheet again for free.
    ///
    /// Mid generation it deliberately *is* Esc, for the reason `setCommentary(_:)` gives —
    /// an annotation nobody can read is model work spent on nothing — plus one this path
    /// adds: `stopActiveWork()` discards the session, so a half-streamed passage kept on
    /// screen would let `ask(_:)` append a question whose answer never arrives.
    ///
    /// Idempotent, since SwiftUI may write `false` more than once around a dismissal.
    private func hideAnnotation() {
        showsAnnotation = false
        if isBusy { cancel() }
    }

    private func cancel() {
        Task { await service.stopActiveWork() }
        // A queued word question goes with the passage it was asked about.
        pendingWordQuestion = nil
        clearAnnotation()
    }

    /// Esc's counterpart on iOS, and what the overflow menu's Clear calls.
    private func clearSelection() {
        selection = nil
        cancel()
    }

    // MARK: - Back stack

    /// ⌘[. Where a cross-reference jump came from.
    private func goBack() {
        guard let entry = history.pop() else { return }
        openChapter(entry.key)
        selection = entry.selection
    }

    // MARK: - Word lookup

    /// The system dictionary, over the word itself.
    ///
    /// A real `DCSCopyTextDefinition` panel rather than a `dict://` URL, which works but
    /// switches apps: looking a word up in the middle of a chapter should not take the
    /// reader out of the Bible. Douay-Rheims English is *more* dictionary-worthy than
    /// Shakespeare's — `firmament`, `propitiation`, `concupiscence`, `laver` — so this
    /// earns its place here more than it did there.
    private func lookUpInDictionary(_ term: String, at point: CGPoint) {
        dictionaryAnchor.showDefinition(term, at: point)
    }

    /// A word, glossed in context by the model.
    ///
    /// This rides the existing turn-2 path — `ask(_:)` into the passage's own
    /// `ChatSession`, which is why a follow-up costs about 0.2 s — and adds no generation
    /// machinery of its own. Turn 1 is untouched, which is what keeps `Prompts.version`
    /// and the golden `PassageContext` render out of it.
    ///
    /// The word's own row has to be *inside the annotated passage*, not merely inside the
    /// current selection: the session the question goes into was built from the passage,
    /// so asking about a word three verses away would be asking about something the model
    /// was never shown.
    private func explainWord(_ term: String, atRow index: Int) {
        let question = Prompts.wordQuestion(term)
        if context != nil, selection?.contains(index) == true, !isBusy {
            ask(question)
            return
        }

        guard let bible, let chapterKey, let book = bible.book(chapterKey.bookID),
            let chapter = bible.chapter(chapterKey)
        else { return }

        // Selecting the row by hand rather than through the reader's own 350 ms debounce,
        // which only `ChapterReaderView`'s gestures reach: writing `selection` from out
        // here commits nothing on its own. Revealing the commentary, because asking about
        // a word is a request to be told something, exactly as pointing at a passage is.
        let selected = VerseSelection(at: index)
        pendingWordQuestion = question
        selection = selected
        commit(
            selected, book: book, key: chapterKey, chapter: chapter,
            revealingCommentary: true)
    }
}

/// A back stack of reading positions, for ⌘[.
///
/// New in this app, and it exists because cross-reference navigation is new. Following
/// Romans 4:3 to Genesis 15:6 is one tap; without this, getting back is finding Romans in
/// the navigator, opening chapter 4 and re-selecting the verse.
///
/// **Only deliberate jumps push.** An arrow-key roll into the next chapter does not, and
/// neither does an ordinary navigator tap — a back stack that records every keypress is
/// not a back stack, it is an undo log, and ⌘[ would take twenty presses to leave a
/// chapter the reader arrowed through.
///
/// Bounded, because it is a convenience and an unbounded one would hold a selection for
/// every jump of a long session for no benefit past the first few.
struct NavigationHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var key: ChapterKey
        var selection: VerseSelection?
    }

    static let limit = 20

    private var entries: [Entry] = []

    var canGoBack: Bool { !entries.isEmpty }

    mutating func push(_ entry: Entry) {
        // A jump that lands where it started is not a jump.
        guard entries.last != entry else { return }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst() }
    }

    mutating func pop() -> Entry? {
        entries.popLast()
    }
}
