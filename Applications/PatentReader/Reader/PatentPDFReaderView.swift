// Copyright © 2026 Apple Inc.

import PDFKit
import SwiftUI

/// The document as the office published it, beside the parsed text.
///
/// The reader text is this app's whole argument — rows, paragraph numbers, a claim tree,
/// citation chips that land on a passage — and it is a *reading* of the document. This tab
/// is the document. A figure, a table, a chemical structure, a signature block and the
/// typesetting of the printed grant are all things the parse cannot carry, and "is `[0042]`
/// really `[0042]`?" is a question only the original answers.
///
/// **What the reader's keys do here, and why each one was decided rather than inherited.**
///
/// - **⌘F** switches to the reader text and raises the find bar. `PDFView` ships no find
///   UI on either platform — Preview's find bar is Preview's own code over
///   `PDFDocument.findString(_:withOptions:)` — so a ⌘F left unbound would be a working
///   shortcut that silently stops working on one tab. Sending it to the text is honest
///   about which of the two views the app can actually search.
/// - **⌘G, ⇧⌘G** are absent, because there is nothing here to step through.
/// - **⇧⌘C** is absent. `Citation.quotation` needs `[DocumentRow]`, and a `PDFSelection`
///   cannot be mapped back to a paragraph index: the PDF is paginated by the office's
///   typesetting and carries no index this app can resolve one against.
/// - **⌘C** is PDFKit's own, and copies the selected text **uncited**. That is stated here
///   because it is a real difference from the text tab, where ⌘C appends the citation: no
///   truthful citation can be attached to a span this app cannot locate in the document it
///   parsed, and attaching an approximate one would be exactly the failure the citation
///   verdicts exist to prevent.
/// - **Arrows, space, page up and down** are PDFKit's scrolling, which is why there is no
///   `.focusable()` on the host below: `PDFView`'s document view takes first responder
///   itself, and a SwiftUI focus item over it would compete for the keys.
/// - **Esc** does nothing, deliberately. Esc means "put that away" in a ladder — the find
///   bar, then the selection, then `onCancel` — and a tab is not a thing you put away.
///
/// A citation click always lands in the *text*: see `ContentView.aimAtText()`.
@MainActor
struct PatentPDFReaderView: View {
    let patent: Patent
    let pdf: PatentPDFService
    /// ⌘F and the two find affordances: switch to the reader text, then raise the bar.
    let onFindInText: () -> Void

    /// The open document, and the anchor map over it.
    ///
    /// **Owned here rather than inside `PatentPDFView`**, which is where `PDFDocument(url:)`
    /// used to be called, and the move is what makes everything above the representable
    /// possible. The map, the marks and — shortly — the find bar and the selection all have
    /// to address the *same* `PDFDocument` instance: annotations are added to its
    /// `PDFPage`s, and a second document opened from the same URL would be a different set
    /// of pages with the marks on the wrong one. So one object, made once, handed down.
    @State private var document: PDFDocument?
    @State private var map: PatentPDFMap?
    @State private var marks = PatentPDFMarks()

    var body: some View {
        Group {
            switch pdf.state(for: patent) {
            case .onDisk(let file):
                if let document, let map, opened(document, is: file) {
                    PatentPDFView(
                        document: document, map: map, marks: marks,
                        // Step by step: nothing is painted yet. The plan arrives from
                        // `ContentView` with the answer that produced it.
                        plan: .empty,
                        isMapped: map.isBuilt,
                        numbering: patent.numbering,
                        page: Binding(
                            get: { pdf.pages[patent.key] ?? 0 },
                            set: { pdf.pages[patent.key] = $0 }))
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
        // **The view existing is the reader having opened the tab.** The lazy fetch is
        // therefore structural rather than an event some future call site could forget to
        // send — and `id:` re-runs it when the reader clicks down the library with this
        // tab up. `ensureDownloaded` is idempotent and does not retry a failure, so the
        // switching back and forth this invites costs nothing.
        .task(id: patent.key) { await open() }
        .background { findShortcut }
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
        await map.build(in: document)
    }

    /// Whether an open document is the one at this URL. `PDFDocument` keeps the URL it was
    /// made from, which is the only identity available across a view rebuild.
    private func opened(_ document: PDFDocument, is file: URL) -> Bool {
        document.documentURL?.standardizedFileURL == file.standardizedFileURL
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

    /// ⌘F on this tab. Zero-opacity rather than `.hidden()`, which would take the shortcut
    /// out of the hierarchy with the button — the idiom `DocumentReaderView.findShortcuts`
    /// and `ContentView.shortcuts` both use.
    ///
    /// There is never a second ⌘F: `ContentView` puts one reader or the other in the
    /// hierarchy with a `switch`, so `DocumentReaderView`'s shortcuts leave with it.
    @ViewBuilder
    private var findShortcut: some View {
        Button("Find in this patent") { onFindInText() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// `PDFKit.PDFView`, as a SwiftUI view.
///
/// **Here rather than in `PlatformCompat.swift`**, which is the file two superclass names
/// would otherwise argue for. That file's own header says it holds "the handful of places
/// where AppKit and UIKit genuinely differ" so that everything else can be platform-free,
/// and every entry in it is a one-line shim over a single API. This is a feature's entire
/// view layer that happens to need two protocol names, and filing it there would make
/// `PlatformCompat.swift` the home of the PDF tab. `DocumentReaderView` is the model
/// instead: keep the `#if`s at the smallest scope, in the feature's own file.
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
    /// Whether `map` has finished. A stored property and not a read of `map.isBuilt` inside
    /// `update`, because `updateNSView` is not an observation scope: the parent reads it,
    /// which is what re-runs this view when the walk finishes and the marks become drawable.
    let isMapped: Bool
    let numbering: Numbering

    /// The page the reader is on, zero-based, held by `PatentPDFService.pages` for this
    /// launch only.
    @Binding var page: Int

    /// Watches the view's own page changes, and nothing else's.
    ///
    /// Scoped with `object: view`, because `.PDFViewPageChanged` is posted by every
    /// `PDFView` in the process and an unscoped observer would write one patent's page
    /// number from another patent's scrolling.
    @MainActor
    final class Coordinator {
        /// Re-assigned on every `update`, so the binding written here is always the
        /// current one rather than the one captured when the view was made.
        var onPageChange: (Int) -> Void = { _ in }

        /// `nonisolated(unsafe)` so that `deinit`, which is not main-actor isolated, can
        /// hand the token back. It is written once on the main actor while the view is
        /// alive and read once when nothing else holds this object, which is the whole of
        /// the unsafety.
        private nonisolated(unsafe) var token: (any NSObjectProtocol)?

        func observe(_ view: PDFView) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
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
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
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
        if view.document !== document { load(into: view) }
        if isMapped {
            marks.apply(
                plan, from: map, numbering: numbering, to: document, redrawing: view)
        }
        guard let current = view.currentPage, document.index(for: current) != page
        else { return }
        go(to: page, in: view)
    }

    /// Points the coordinator at *this* instance's binding, on every update, so the page
    /// it writes is never the one captured when the view was made.
    private func bind(_ coordinator: Coordinator) {
        coordinator.onPageChange = { reported in
            // Only when it differs, or this writes the state that produced it and the
            // next `update` scrolls the view that produced the notification, forever.
            guard reported != page else { return }
            page = reported
        }
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
