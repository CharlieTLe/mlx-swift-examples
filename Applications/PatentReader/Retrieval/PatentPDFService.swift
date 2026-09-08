// Copyright © 2026 Apple Inc.

import Foundation

/// Whether this patent's original PDF can be shown, and if not, why not.
///
/// A value rather than a handful of flags on the service, so the copy the reader sees is
/// testable without a view: `--selftest`'s `originalPDFAvailability` drives
/// `availability(kind:cachedFile:storedPageHTML:)` and asserts every message. The reason a
/// PDF is missing is the only interesting thing about a missing PDF, and it is the part
/// that would otherwise be written once in a view body and never checked again.
///
/// **Both reader tabs are always present and always enabled**, whatever this says. A
/// hidden or disabled segment states the fact and withholds the reason, and the pane's
/// chrome would change shape as the reader clicks down the library — a control appearing
/// and disappearing under the pointer. So an unavailable PDF is *reported*, in the same
/// furniture as `ContentView.emptyState`, and every case below names both the problem and
/// what to do about it.
enum PatentPDFAvailability: Equatable, Sendable {
    /// The library has the bytes. The reader's copy, not the reader's original: see
    /// `LibraryStore.storePDF(_:for:)`.
    case onDisk(URL)
    /// Not fetched yet, and here is where it lives. The lazy trigger; see
    /// `PatentPDFService.ensureDownloaded`.
    case downloadable(URL)
    /// A request is in flight to the named URL. Carries it so the pane can name the host
    /// it is talking to, which `PatentPDFLink` deliberately does not pin.
    case downloading(from: URL)
    /// The download failed, with the underlying `localizedDescription` **verbatim**.
    /// Never paraphrased and never swallowed: a reader whose Wi-Fi is off should read that
    /// their Wi-Fi is off, in the system's own words.
    case failed(String)
    case unavailable(Reason)

    /// Why there is no PDF to show, in the four shapes the library can actually be in.
    enum Reason: Equatable, Sendable {
        /// A fetched patent whose `<slug>.source.html` is gone, so the link cannot be
        /// recovered from anything on disk.
        case noStoredPage
        /// A fetched patent whose page carried no `citation_pdf_url`.
        case noLinkInPage
        /// A PDF import from before the library kept its bytes, or one whose copy was
        /// deleted from under it.
        case importedCopyGone
        /// `Source.Kind.plainText`. Handled as a safety rather than as a live path — see
        /// `availability(kind:cachedFile:storedPageHTML:)`.
        case notAPDFSource

        /// The headline, in the weight `ContentView.emptyState` sets its own in.
        var headline: String {
            switch self {
            case .noStoredPage:
                "The link to the original PDF cannot be recovered."
            case .noLinkInPage:
                "No original PDF for this patent."
            case .importedCopyGone:
                "The PDF this patent was imported from was not kept."
            case .notAPDFSource:
                "This patent was imported from text, which has no original PDF."
            }
        }

        /// What happened and what to do, naming the patent where the instruction needs it.
        ///
        /// Three of the four end in an action the reader can take. `--selftest` asserts
        /// that the two with a remedy still name it — a reword that drops "fetch it again"
        /// fails the build rather than a reader's afternoon.
        func detail(for key: PatentKey) -> String {
            switch self {
            case .noStoredPage:
                "The page \(key.display) was parsed from is no longer in the library, and "
                    + "the link to the office's PDF was in it. Remove \(key.display) and "
                    + "fetch it again."
            case .noLinkInPage:
                "The page this patent was parsed from carried no link to one. The reader "
                    + "text is the whole of what was imported."
            case .importedCopyGone:
                "It was imported before the library kept a copy of the file, or the copy "
                    + "has since been deleted. Import the file again to read it here."
            case .notAPDFSource:
                "A text file has no pages, no figures and no signature block, so there is "
                    + "nothing here that the reader text does not already show."
            }
        }
    }

    /// The state a patent is in before anything has been downloaded this launch.
    ///
    /// Pure, and every input is a fact the caller already holds: `cachedFile` is
    /// `LibraryStore.storedPDF(_:)` — non-`nil` means the copy is on disk — and
    /// `storedPageHTML` is `LibraryStore.storedSource(_:)`, whose *first* caller this is.
    ///
    /// The order matters in one place. `.plainText` is checked before the cached file
    /// because `Source.Kind.plainText` is a case no importer produces today —
    /// `LibraryService.importFile` always routes through `PatentPDFImporter.load`, which
    /// always writes `kind: .pdf`, and a `.txt` fails at `PDFDocument(url:)` long before
    /// this — so it is handled as a safety, and a safety that could be shadowed by a
    /// leftover file on disk is not one.
    static func availability(
        kind: Source.Kind, cachedFile: URL?, storedPageHTML: String?
    ) -> PatentPDFAvailability {
        if kind == .plainText { return .unavailable(.notAPDFSource) }
        if let cachedFile { return .onDisk(cachedFile) }

        switch kind {
        case .pdf:
            // The bytes were the import. Nothing can recover them but the reader.
            return .unavailable(.importedCopyGone)
        case .googlePatentsHTML:
            // **The retroactive case.** Every patent ever fetched has its page on disk, so
            // a library imported before this feature existed gains a PDF tab at the next
            // launch with no re-import and no second request for the page.
            guard let storedPageHTML else { return .unavailable(.noStoredPage) }
            guard let url = PatentPDFLink.url(inPageHTML: storedPageHTML) else {
                return .unavailable(.noLinkInPage)
            }
            return .downloadable(url)
        case .plainText:
            return .unavailable(.notAPDFSource)
        }
    }
}

/// The original PDF for each patent: where it is, and fetching it when it is not here yet.
///
/// **Separate from `LibraryService`**, whose doc comment states exactly one idea — *a
/// patent becomes readable before it becomes searchable* — and owns the order of
/// operations that idea implies. A PDF fetched lazily, the first time somebody opens a
/// tab, is not a step in that order and folding it in would make that sentence untrue.
///
/// **Nothing here is eager.** `LibraryService.fetch` still makes exactly one request per
/// patent; the second request happens when, and only when, a reader asks to see the
/// original. A library of thirty patents is thirty PDFs nobody asked for, at a few
/// megabytes each, from somebody else's bucket.
@MainActor
@Observable
final class PatentPDFService {

    /// How the bytes arrive. Injected so the download can be replaced — the app's one
    /// implementation is `GooglePatentsSource.fetchPDF(at:)`, and everything else this
    /// type does is testable without a network.
    typealias Download = @Sendable (URL) async throws -> Data

    /// Which page of each PDF the reader was last on, **this launch only**.
    ///
    /// Not persisted, and `LibraryOutline` is the precedent for saying why in the type
    /// rather than discovering it later. `ReadingProgress` is stamped with
    /// `Source.contentSHA256`, which is a digest over the patent's *text* — it says
    /// nothing about the PDF beside it. A stored page number could therefore be restored
    /// against a PDF that had been re-downloaded, or replaced by a re-import, and land the
    /// reader on page 40 of a different document while looking exactly like a restored
    /// position. The reading position that matters is the text's, and that one is stamped.
    var pages: [PatentKey: Int] = [:]

    private let store: LibraryStore
    private let download: Download

    /// What a request did, for patents that have one. Absent means "nothing has been
    /// tried", which is not the same as "it failed" — that distinction is what keeps a
    /// failed download from being re-issued on every tab switch.
    private enum Attempt {
        case downloading(URL)
        case failed(String)
    }
    private var attempts: [PatentKey: Attempt] = [:]

    /// The pure verdict for patents with no copy on disk, computed once per launch.
    ///
    /// The cache is over the *page scan*, which is the expensive half: reading 215 KB of
    /// stored HTML and walking it. Everything the scan can conclude — a link, no link, no
    /// page — is fixed for the launch, so this is memoization rather than a second source
    /// of truth. Whether the file has arrived is asked of the filesystem every time.
    private var scanned: [PatentKey: PatentPDFAvailability] = [:]

    /// Where every passage of each patent is in its PDF, for this launch.
    ///
    /// Cached here for the same reason `pages` is — this type is what a patent's PDF
    /// belongs to, and it is what `LibraryService.remove` already tells to forget one. The
    /// cost of *not* caching is the whole point: anchoring a 131-page grant is 1272
    /// `findString` calls, and re-running them every time the reader clicks back to a patent
    /// would make the library unusable. The map is built by `PatentPDFReaderView`, which is
    /// the only place that has the open `PDFDocument`.
    ///
    /// Not persisted, and for a stronger version of `pages`' reason: a placement is a page
    /// and an offset into a specific set of bytes, so a re-downloaded PDF would restore
    /// highlights onto whatever text now sits at those offsets. `ReadingProgress` stores a
    /// paragraph number precisely because that survives and this does not.
    private var maps: [PatentKey: PatentPDFMap] = [:]

    init(
        store: LibraryStore,
        download: @escaping Download = { try await GooglePatentsSource().fetchPDF(at: $0) }
    ) {
        self.store = store
        self.download = download
    }

    // MARK: - Reading

    func state(for patent: Patent) -> PatentPDFAvailability {
        let key = patent.key
        // The filesystem first, so a download that has just landed is shown without
        // anything having to invalidate a cache.
        if let file = store.storedPDF(key) { return .onDisk(file) }
        switch attempts[key] {
        case .downloading(let url): return .downloading(from: url)
        case .failed(let message): return .failed(message)
        case nil: break
        }
        if let scanned = scanned[key] { return scanned }

        let value = PatentPDFAvailability.availability(
            kind: patent.source.kind, cachedFile: nil,
            storedPageHTML: store.storedSource(key))
        scanned[key] = value
        return value
    }

    /// The anchor map for one patent, made empty on first ask and built by whoever has the
    /// open document.
    ///
    /// Handed out rather than built here because building needs a `PDFDocument`, which is
    /// the view layer's — this type deals in bytes and URLs and has never opened one.
    func map(for patent: Patent) -> PatentPDFMap {
        if let existing = maps[patent.key] { return existing }
        let map = PatentPDFMap(patent: patent)
        maps[patent.key] = map
        return map
    }

    // MARK: - Fetching

    /// Fetches the PDF if that is what this patent needs, and does nothing otherwise.
    ///
    /// Called from `PatentPDFReaderView.task`, which means **the view existing is the
    /// reader having opened the tab** — the trigger is structural rather than an event
    /// that a new call site could forget to send.
    ///
    /// Idempotent in both directions, which is the whole of its contract: a request
    /// already in flight is not duplicated, a file already on disk is not re-fetched, and
    /// **a failure is not retried**. That last one is deliberate and is the difference
    /// between a reader with no network seeing one error and seeing the same error re-run
    /// every time they touch the segmented control. Retrying is a button.
    func ensureDownloaded(_ patent: Patent) async {
        guard case .downloadable(let url) = state(for: patent) else { return }
        await fetch(patent.key, from: url)
    }

    /// The **Try again** button under a `.failed` report. The one thing that clears a
    /// failure, because the reader asking is the new information.
    func retry(_ patent: Patent) async {
        attempts[patent.key] = nil
        await ensureDownloaded(patent)
    }

    private func fetch(_ key: PatentKey, from url: URL) async {
        // Written before the first suspension point, on the main actor, so a second
        // `ensureDownloaded` arriving while this one waits already reads `.downloading`.
        attempts[key] = .downloading(url)
        do {
            let data = try await download(url)
            try store.storePDF(data, for: key)
            attempts[key] = nil
        } catch {
            // **A cancellation is not a failure.** This runs inside the view's `.task`, so
            // leaving the tab or clicking the next patent mid-download cancels it — and
            // recording that as a failure would make it *stick*, since a failure is never
            // retried on its own. The reader would come back to "The download failed. The
            // operation couldn't be completed" for a download nobody had a problem with.
            // Cleared instead, so returning to the tab simply asks again.
            // `LibraryService.build` treats a cancelled index the same way.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                attempts[key] = nil
            } else {
                attempts[key] = .failed(error.localizedDescription)
            }
        }
    }

    /// Everything this type remembers about a patent, dropped along with the patent.
    /// `LibraryStore.remove` deletes the file; this drops the page, the scan, the anchor map
    /// and any failure, so re-importing the same number starts clean rather than inheriting
    /// the last one's error — or, worse, the last document's placements.
    func forget(_ key: PatentKey) {
        pages[key] = nil
        attempts[key] = nil
        scanned[key] = nil
        maps[key] = nil
    }
}
