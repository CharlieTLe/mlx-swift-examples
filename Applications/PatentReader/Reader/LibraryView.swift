// Copyright © 2026 Apple Inc.

import SwiftUI
import UniformTypeIdentifiers

/// The library: a list of patents, with a find field over it, and the sections of the
/// open one nested underneath.
///
/// `NavigatorView`'s skeleton — hand-rolled search field, `Divider`, `List(selection:)`,
/// `ScrollViewReader` putting the open row on screen next turn, ⌘F on a zero-opacity
/// button — with the play/act/scene accordion replaced by patent/section.
///
/// The accordion survives and its argument transfers unchanged: a patent runs to a few
/// hundred rows and recording what is *open* rather than what is collapsed is what makes
/// a cold start a short list. What is new is that the library is built by the reader, so
/// this pane also owns adding and removing — and the search field has to do something
/// other than filter, because a number typed here is a request for a document that may
/// not be in the library yet.
@MainActor
struct LibraryView: View {
    let library: LibraryService
    @Binding var openPatent: PatentKey?
    @Binding var outline: LibraryOutline

    /// A section or the claims of the open patent, picked from the outline.
    let onOpenSection: (Int) -> Void
    /// `[0042]` or `claim 7` typed into the find field, which is a jump rather than a
    /// filter.
    let onLocate: (LibrarySearch.LocatorKind) -> Void

    @State private var query = ""
    @FocusState private var isQueryFocused: Bool
    @State private var isImportingFile = false
    @State private var pendingNumber = ""
    @State private var isAddingByNumber = false

    private var parsedQuery: LibrarySearch.Query { LibrarySearch.parse(query) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        .background {
            // ⌘F, needing a control to hang off. Zero-opacity rather than `.hidden()`,
            // which removes it from the hierarchy along with its shortcut.
            Button("Find a patent") { isQueryFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.pdf, .plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await library.importFile(at: url) }
        }
        // The whole pane is the drop target, not a row, because a reader dropping a PDF
        // is adding to the library rather than to anything in it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await library.importFile(at: url) }
            return true
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var list: some View {
        let matches = LibrarySearch.matches(in: library.patents, query: parsedQuery)
        let suggestion = LibrarySearch.fetchSuggestion(
            for: parsedQuery, in: library.patents)

        ScrollViewReader { scroller in
            List(selection: selectionBinding) {
                if let importing = library.importing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Adding \(importing)…").font(.callout)
                    }
                }
                if let message = library.importError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // A number typed into a patent app is a request for that patent, so an
                // unmatched number is not an empty result — it is an action the reader
                // has all but asked for. This row is the difference between "No patents
                // match" and getting them the document.
                if let suggestion {
                    Button {
                        query = ""
                        Task { await library.fetch(suggestion) }
                    } label: {
                        Label(
                            "Fetch \(suggestion.display)",
                            systemImage: "arrow.down.circle"
                        )
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .disabled(library.importing != nil)
                }

                if matches.isEmpty, suggestion == nil {
                    Text(library.patents.isEmpty ? emptyLibraryHint : "No patents match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(matches) { patent in
                    patentRow(patent)
                    if outline.isOpen(patent: patent.key) {
                        sectionRows(patent)
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { scroll(scroller) }
            .onChange(of: openPatent) { scroll(scroller) }
        }
    }

    private var emptyLibraryHint: String {
        "No patents yet. Add one by number, or drop a PDF here."
    }

    /// `List` selection is optional; a deselection is ignored rather than allowed to
    /// empty the pane, exactly as the navigator next door does.
    private var selectionBinding: Binding<PatentKey?> {
        Binding(get: { openPatent }, set: { if let new = $0 { openPatent = new } })
    }

    /// Puts the open patent on screen, **next** main-actor turn.
    ///
    /// Deferred deliberately, for `NavigatorView`'s reason: a jump that switches
    /// documents arrives here before `ContentView` has moved the outline onto the new
    /// one — that follow is an `onChange` of its own — so at this instant the row being
    /// aimed at may not exist. `scrollTo` on an id the list has not declared does nothing
    /// at all, silently.
    private func scroll(_ scroller: ScrollViewProxy) {
        let key = openPatent
        Task { if let key { scroller.scrollTo(key, anchor: .center) } }
    }

    @ViewBuilder
    private func patentRow(_ patent: Patent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(
                    systemName: outline.isOpen(patent: patent.key)
                        ? "chevron.down" : "chevron.right"
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .onTapGesture { outline.toggle(patent: patent.key) }

                Text(patent.key.display)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                statusGlyph(for: patent)
            }

            Text(patent.title)
                .font(.callout)
                .lineLimit(2)
                .padding(.leading, 16)

            Text(subtitle(patent))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.leading, 16)
        }
        .tag(patent.key)
        .contextMenu {
            Button("Remove from library", systemImage: "trash", role: .destructive) {
                library.remove(patent.key)
            }
            if case .ready = library.state(of: patent.key) {
            } else {
                Button("Index now", systemImage: "arrow.clockwise") {
                    library.enqueue(patent.key)
                }
            }
        }
        #if !os(macOS)
            .swipeActions {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    library.remove(patent.key)
                }
            }
        #endif
    }

    private func subtitle(_ patent: Patent) -> String {
        var parts: [String] = []
        if let assignee = patent.assignee { parts.append(assignee) }
        if let date = patent.publicationDate?.prefix(4) { parts.append(String(date)) }
        parts.append("\(patent.paragraphs.count) ¶")
        parts.append("\(patent.claims.count) claims")
        return parts.joined(separator: " · ")
    }

    /// The per-patent index state.
    ///
    /// The same vocabulary `ReaderFontLibrary`'s download glyphs use, and for the same
    /// reason: nothing at all in the ordinary case, a determinate figure while work is in
    /// flight, and a warning triangle with the message in a tooltip when it failed. A
    /// determinate figure rather than a spinner because this is the operation that takes
    /// tens of seconds, and a spinner over tens of seconds is indistinguishable from a
    /// hang.
    @ViewBuilder
    private func statusGlyph(for patent: Patent) -> some View {
        switch library.state(of: patent.key) {
        case .ready:
            EmptyView()
        case .notIndexed:
            Image(systemName: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Not indexed — questions will use keyword search only")
        case .indexing(let done, let total):
            Text(total > 0 ? "\(done)/\(total)" : "…")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    /// The open patent's own structure: its `<heading>` sections, then Claims.
    ///
    /// Its own structure and not a table of contents this app invented — these are the
    /// headings the patent prints, which is what makes them safe to navigate by.
    @ViewBuilder
    private func sectionRows(_ patent: Patent) -> some View {
        ForEach(Array(patent.sections.enumerated()), id: \.offset) { index, section in
            if !section.heading.isEmpty {
                Button {
                    outline.toggle(section: index, in: patent.key)
                    onOpenSection(index)
                } label: {
                    sectionLabel(
                        section.heading.capitalized,
                        detail: "\(section.paragraphs.count)")
                }
                .buttonStyle(.plain)
            }
        }
        if !patent.claims.isEmpty {
            Button {
                outline.toggle(section: LibraryOutline.claimsSection, in: patent.key)
                onOpenSection(LibraryOutline.claimsSection)
            } label: {
                sectionLabel("Claims", detail: "\(patent.claims.count)")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 26)
        .contentShape(Rectangle())
    }

    // MARK: - Find field

    /// Hand-rolled and shared, not `.searchable`. On a phone this pane is a
    /// `NavigationSplitView` column and `.searchable` would render into the navigation
    /// bar, but on a Mac the library is a bare `List` inside an `HSplitView` with no
    /// toolbar for a search field to go in.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Number, title, or [0042]", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isQueryFocused)
                .onSubmit { submitQuery() }
                #if !os(macOS)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #else
                    // Esc belongs to the field while it holds the keyboard, and giving
                    // the keyboard up is the point: focused, the field makes the reader
                    // pane's arrows, Esc and ⌘C dead.
                    .onExitCommand {
                        query = ""
                        isQueryFocused = false
                    }
                #endif

            if !query.isEmpty {
                Button {
                    query = ""
                    isQueryFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear the filter")
            }

            addMenu
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .alert("Add a patent", isPresented: $isAddingByNumber) {
            TextField("US 10,123,456 B2", text: $pendingNumber)
            Button("Cancel", role: .cancel) { pendingNumber = "" }
            Button("Fetch") {
                if let key = PatentNumberParser.parse(pendingNumber) {
                    Task { await library.fetch(key) }
                }
                pendingNumber = ""
            }
        } message: {
            Text(
                "Fetched from Google Patents. Any spelling of the number works — "
                    + "US10123456B2, 10,123,456, or 10123456.")
        }
    }

    /// Enter in the find field.
    ///
    /// Three readings, three behaviours: a locator jumps, a number that is not in the
    /// library fetches, and anything else keeps the filter and hands the keyboard back —
    /// which is what dismisses the software keyboard on a phone.
    private func submitQuery() {
        switch parsedQuery {
        case .locator(let kind):
            onLocate(kind)
            query = ""
        case .number(let key)
        where LibrarySearch.fetchSuggestion(for: parsedQuery, in: library.patents) != nil:
            query = ""
            Task { await library.fetch(key) }
        default:
            break
        }
        isQueryFocused = false
    }

    @ViewBuilder
    private var addMenu: some View {
        Menu {
            Button("Add by number…", systemImage: "number") { isAddingByNumber = true }
            Button("Import PDF…", systemImage: "doc") { isImportingFile = true }
            if library.patents.contains(where: { !library.index.indexed.contains($0.key) }) {
                Divider()
                Button("Index everything", systemImage: "arrow.clockwise") {
                    library.indexAll()
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .borderlessMenu()
        .fixedSize()
        .disabled(library.importing != nil)
        .help("Add a patent by number, or import a PDF")
        .accessibilityLabel("Add a patent")
    }
}
