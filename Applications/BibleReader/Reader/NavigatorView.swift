// Copyright © 2026 Apple Inc.

import SwiftUI

/// Division / book / chapter outline, with a find field over it. Selecting a chapter is
/// how the reader moves, since only one chapter is rendered at a time.
///
/// An **accordion**: one division open, one book open inside it, following the reading
/// position. `NavigatorOutline` holds that state and `NavigatorSearch` is the other way
/// in, by name or by reference.
///
/// **Nine division rows at the top, not two testament rows.** Two rows that expand to 46
/// and 27 books is not navigation; nine rows that expand to between one and eighteen is.
///
/// **A book expands to a chapter grid, not chapter rows.** Psalms would otherwise be 150
/// rows in a 210pt column, and a chapter has no name to make a row worth its height —
/// only a number. The grid is the one genuinely new view in this navigator and it is
/// what makes 1,334 chapters reachable.
///
/// The divisions and books collapse, but **not** with `DisclosureGroup`. Inside a sidebar
/// `List` that control keeps its own expansion state and overrides whatever binding it is
/// handed: `.constant(true)` left rows in mixed states, and both a parent-derived binding
/// and a child-owned `@State` initialized to `true` rendered most rows shut and refused
/// to open. Emitting the rows conditionally instead leaves the list nothing to disagree
/// with — a collapsed book's grid does not exist, and neither do a collapsed division's
/// books.
@MainActor
struct NavigatorView: View {
    let bible: Bible
    let table: BookTable
    @Binding var key: ChapterKey

    /// What is open: one division, one book. Owned by `ContentView` rather than here
    /// because hiding this pane removes the view, and a `@State` outline would come back
    /// shut with the reader's own book collapsed under them.
    @Binding var outline: NavigatorOutline

    /// Jumping to a reference the find field resolved, which may carry a verse and so is
    /// more than a chapter change.
    let onOpen: (ScriptureReference) -> Void

    /// The find field. `@State` and not a preference: a filter is a moment, and it
    /// clearing when the pane is hidden is right.
    @State private var query = ""
    @FocusState private var isQueryFocused: Bool

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .background {
            // ⌘F, needing a control to hang off. Zero-opacity rather than `.hidden()`,
            // which removes it from the hierarchy along with its shortcut.
            //
            // Live only while this pane is on screen: hidden, the navigator does not
            // exist and ⌘F does nothing, which is the same trade the pane's own state
            // makes by living in `ContentView`.
            Button("Find a book") { isQueryFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Outline

    @ViewBuilder
    private var content: some View {
        switch NavigatorSearch.matches(in: bible, table: table, query: query) {
        case .reference(let resolved):
            referenceResult(resolved)
        case .books(let matches):
            outlineList(matches)
        }
    }

    /// What a typed reference looks like: one row that goes there, and — where the two
    /// numbering systems disagree — one secondary row that says so.
    ///
    /// **A hint is never an auto-redirect.** `Ps 23` opens DRB 23, which is what the
    /// reader asked for and a real psalm; the hint offers DRB 22 beside it. Sending them
    /// to 22 silently would be the app deciding it knows which Bible they meant, and it
    /// would teach them nothing about why the numbers differ.
    @ViewBuilder
    private func referenceResult(_ resolved: ResolvedReference) -> some View {
        let name = table.name(of: resolved.reference.bookID) ?? resolved.reference.bookID

        List {
            Button {
                onOpen(resolved.reference)
                isQueryFocused = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resolved.reference.string(bookName: name))
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let hint = resolved.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func outlineList(_ matches: [NavigatorSearch.BookMatch]) -> some View {
        // `List` selection is optional; the reader always has a chapter open, so a
        // deselection is ignored rather than allowed to empty the pane.
        let selected = Binding<ChapterKey?>(
            get: { key },
            set: { if let new = $0 { key = new } })

        // The open book can be anywhere in the corpus now that the outline starts closed,
        // so the sidebar scrolls itself. The book rows carry the id, not the chapters:
        // a chapter lives in a grid rather than in a list row, so there is no row to
        // scroll to below the book.
        ScrollViewReader { scroller in
            List(selection: selected) {
                if matches.isEmpty {
                    Text("No books match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(Division.allCases, id: \.self) { division in
                    let books = matches.filter { $0.book.division == division }
                    if !books.isEmpty {
                        divisionHeader(division, count: books.count)
                        if isOpen(division) {
                            ForEach(books) { match in
                                bookHeader(match, in: division)
                                if isOpen(match.book, in: division) {
                                    chapterGrid(match.book)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { scroll(scroller) }
            // What catches an arrow key rolling into the next chapter from the reader
            // pane. A tap in the sidebar scrolls to a row already on screen, which is a
            // harmless no-op.
            .onChange(of: key) { scroll(scroller) }
        }
    }

    /// Puts the book being read on screen, **next** main-actor turn.
    ///
    /// Deferred deliberately. A roll into the next book arrives here before `ContentView`
    /// has moved the outline onto it — that follow is an `onChange` of its own — so at
    /// this instant the division holding the new book is still shut and the row being
    /// aimed at does not exist. `scrollTo` on an id the list has not declared does nothing
    /// at all, silently. By the next turn the outline has moved and the rows are there.
    private func scroll(_ scroller: ScrollViewProxy) {
        let id = key.bookID
        Task { scroller.scrollTo(id, anchor: .center) }
    }

    /// Every result of a search is open, so the hits are on screen; otherwise the
    /// accordion decides.
    private func isOpen(_ division: Division) -> Bool {
        isSearching || outline.isOpen(division: division)
    }

    /// A book is never forced open by a search. A name search answers with books, and the
    /// reader picks one — opening all of them would fill the column with grids.
    private func isOpen(_ book: Book, in division: Division) -> Bool {
        outline.isOpen(book: book.id, in: division)
    }

    // MARK: - Headers

    @ViewBuilder
    private func divisionHeader(_ division: Division, count: Int) -> some View {
        let font = Font.subheadline.weight(.semibold)
        let title = "\(division.name) (\(count))"

        if isSearching {
            // Held open by the search, so its chevron has nothing to close — a plain
            // label rather than a `Button`, for the reason under `bookHeader`.
            headerRow(title, isOpen: true, font: font, prominent: true)
        } else {
            Button {
                outline.toggle(division: division)
            } label: {
                headerRow(
                    title, isOpen: outline.isOpen(division: division), font: font,
                    prominent: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// Carries no `.tag`, so the list does not treat it as a selectable chapter.
    ///
    /// The dagger marks a deuterocanonical book. **Informational only** — the books stay
    /// in canonical order among the rest, because a Catholic Bible integrates them rather
    /// than segregating them, and a reader coming from a Protestant Bible is owed an
    /// explanation of why Tobias is between Esther and Job rather than a separate
    /// section that implies it is an appendix.
    @ViewBuilder
    private func bookHeader(_ match: NavigatorSearch.BookMatch, in division: Division)
        -> some View
    {
        Button {
            outline.toggle(book: match.book.id, in: division)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(
                        systemName: isOpen(match.book, in: division)
                            ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)

                    Text(match.book.name)
                        .font(.callout)
                        .lineLimit(2)

                    if match.book.deuterocanonical {
                        Text("†")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Deuterocanonical")
                    }
                    Spacer(minLength: 0)
                }
                if let via = match.via {
                    Text("also \(via)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .id(match.book.id)
    }

    @ViewBuilder
    private func headerRow(
        _ title: String, isOpen: Bool, font: Font, prominent: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(title)
                .font(font)
                .foregroundStyle(
                    prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                )
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        // The whole width is the hit target, not just the glyph.
        .contentShape(Rectangle())
    }

    // MARK: - Chapter grid

    /// A book's chapters, as a grid of small numbered buttons.
    ///
    /// The one genuinely new view in this navigator, and it is what makes the third level
    /// affordable. Psalms as list rows is 150 rows of a single number each; as a grid it
    /// is 25 lines of six. Isaias is 11 lines, and 47 of the 73 books fit in four lines
    /// or fewer.
    ///
    /// **Not** part of `List(selection:)`. A grid cell is a `Button` that writes `key`
    /// directly, because a `.tag` only participates in list selection when it is on a
    /// list row, and these are six to a row. The consequence is that the current chapter
    /// has to draw its own selected state, which `isCurrent` below does — and that is an
    /// improvement rather than a cost, since a filled circle on the number reads at a
    /// glance where a row highlight behind a grid would not.
    ///
    /// `.adaptive` rather than a fixed column count, so a wider sidebar uses the width it
    /// has. 26pt is sized for three digits at `.caption`, which Psalm 119 needs.
    ///
    /// The leading indent is 10 rather than the 26 the book rows use, and that is
    /// measured rather than chosen: at 26 the grid came out four columns wide in the
    /// 210pt sidebar and Psalms was 38 rows of scrolling, which is most of what the grid
    /// exists to avoid. At 10 it is five columns and 30 rows. Six would need cells under
    /// 26pt, which is narrower than `150` sets at this size, so five is where the two
    /// constraints meet.
    @ViewBuilder
    private func chapterGrid(_ book: Book) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 26), spacing: 4)], spacing: 4
        ) {
            ForEach(book.chapters, id: \.number) { chapter in
                let isCurrent = key.bookID == book.id && key.chapter == chapter.number
                Button {
                    key = ChapterKey(bookID: book.id, chapter: chapter.number)
                } label: {
                    Text("\(chapter.number)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
                        )
                        .frame(minWidth: 26, minHeight: 22)
                        .background {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(book.name) chapter \(chapter.number)")
            }
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
    }

    // MARK: - Find field

    /// Hand-rolled and shared, not `.searchable`. On a phone this pane is a
    /// `NavigationSplitView` column and `.searchable` would render into the navigation
    /// bar, but on a Mac the navigator is a bare `List` inside an `HSplitView` with no
    /// toolbar for a search field to go in. The shape is the Ask field's, in
    /// `AnnotationPaneView`.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Book or reference", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isQueryFocused)
                // Return keeps the filter and hands the keyboard back, which is what
                // dismisses the software one on a phone; on a Mac it is the arrows and
                // Esc returning to the reader pane.
                .onSubmit { isQueryFocused = false }
                #if !os(macOS)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #else
                    // Esc belongs to the field while it holds the keyboard, and giving the
                    // keyboard up is the point: focused, the field makes the reader pane's
                    // arrows, Esc, ⌘C and ⌘R dead. Esc clears the filter and lets the
                    // keyboard go; clicking a verse is what hands it back to the reader,
                    // since nothing claims focus on its own when a `@FocusState` is dropped.
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
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}
