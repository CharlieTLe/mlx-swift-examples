// Copyright © 2026 Apple Inc.

import Foundation
import SwiftUI

/// One patent, as a list of selectable rows.
///
/// **One document at a time** is a deliberate constraint, carried over from
/// `SceneReaderView` with its reasoning intact: it bounds rows to a few hundred, makes
/// every selection intrinsically document-scoped so there is no cross-patent range to
/// validate, and keeps the scroll target a plain row index. The cost is no continuous
/// scroll through the library, and the library pane is how you move.
@MainActor
struct DocumentReaderView: View {
    let patent: Patent
    let rows: [DocumentRow]

    @Binding var selection: PassageSelection?

    /// Set by a citation jump, and cleared as the flash finishes. Changing identity is
    /// what re-fires the animation, so a second jump to the same row is visible.
    let flash: FlashHighlight?

    /// A row index to put on screen. Written from outside by a jump, and by this view's
    /// own arrow-key moves.
    @Binding var scrollTarget: Int?

    let onCancel: () -> Void
    /// A claim's parent badge, tapped. Cross-references and reference numerals inside
    /// the text are links instead — see `DocumentRowView.onOpen`.
    let onOpen: (CitationTarget) -> Void
    let onLookUpWord: (String, CGPoint) -> Void

    /// Bumped to raise the find bar and put the keyboard in it. A counter for
    /// `AnswerPaneView.focusRequest`'s reason — the request is an event, and a `Bool` would
    /// be a state that has to be written back to false before it can fire again.
    ///
    /// ⌘F is handled here rather than by the caller, because the state it acts on is here.
    /// This exists for the affordances that are not a key: the macOS header button, and the
    /// iOS overflow row, where there is no ⌘F to press.
    let findRequest: Int

    private static let space = "reader"

    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var isDragging = false
    /// The row a long press armed a sweep on, and the anchor the sweep extends from.
    /// `nil` means no sweep is armed, which is every ordinary pan. iOS only; macOS takes
    /// the drag bare and carries its anchor in `selectionDrag(from:)`.
    @State private var sweepAnchor: Int?
    @FocusState private var isFocused: Bool

    /// Find in this patent. See `DocumentFind` for why it is a value type and why finding
    /// deliberately leaves `selection` alone.
    @State private var find = DocumentFind()
    /// Whether the find bar is up. Separate from `find` so the model stays testable prose
    /// about matching rather than a view's presentation state.
    @State private var isFinding = false
    @FocusState private var isFindFocused: Bool

    /// The document's markup spans, computed once and handed to the rows.
    @State private var spansBox = DocumentSpansBox()

    @Environment(\.readerTypeface) private var typeface

    var body: some View {
        ScrollViewReader { scroller in
            VStack(spacing: 0) {
                if isFinding {
                    FindBar(
                        text: query(scroller),
                        summary: find.summary,
                        hasMatches: !find.matches.isEmpty,
                        isFocused: $isFindFocused,
                        onNext: { step(1, scroller) },
                        onPrevious: { step(-1, scroller) },
                        onClose: { stopFinding() })
                    Divider()
                }

                ScrollView {
                    measured(
                        LazyVStack(alignment: .leading, spacing: 0) {
                            FrontPageCard(patent: patent)
                            let spans = spansBox.spans(for: patent, rows: rows)
                            ForEach(rows) { row in
                                self.row(row, spans: spans[row.index])
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.trailing, 12)
                        #if !os(macOS)
                            // Inside the scroll content on purpose: `SweepRecognizer` finds
                            // the scroll view by walking up from here, and a background of
                            // the `ScrollView` would sit outside it.
                            .background {
                                SweepRecognizer(
                                    onBegan: { point in
                                        // **Only from the number margin.** This guard is the
                                        // arbitration between the reader's two selections, and
                                        // it is load-bearing: the prose is selectable text, so
                                        // a long press on it belongs to the system's character
                                        // selection. Armed from anywhere, as it was, one long
                                        // press gave grab handles and a five-row band at the
                                        // same time — two selections of two different things
                                        // from one gesture.
                                        guard let row = rowFrames.line(at: point),
                                            isOnMargin(point, of: row)
                                        else { return }
                                        sweepAnchor = row
                                        extendDrag(from: row, to: point)
                                    },
                                    onChanged: { point in
                                        guard let sweepAnchor else { return }
                                        extendDrag(from: sweepAnchor, to: point)
                                    },
                                    onEnded: {
                                        sweepAnchor = nil
                                        isDragging = false
                                    }
                                )
                            }
                        #endif
                    )
                }
                .coordinateSpace(name: Self.space)
                #if !os(macOS)
                    // The other half of `SweepRecognizer`: it allows simultaneous recognition
                    // so it never inhibits the pan, which means once a sweep is under way the
                    // scroll view would otherwise still be panning under the finger doing it.
                    .scrollDisabled(isDragging)
                #endif
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .onChange(of: scrollTarget) {
                    // Where a jump and an arrow move both land. Scrolling can only happen in
                    // here, with the proxy, while `.onMoveCommand` has to sit on the
                    // focusable view itself — see the note beside it below. So both write a
                    // row index and this puts it on screen.
                    guard let scrollTarget else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scroller.scrollTo(scrollTarget, anchor: .center)
                    }
                }
                .onChange(of: typeface) {
                    // `.id(patent.key)` does not change on a font switch, which is right —
                    // the reader keeps their place rather than being thrown back to the top.
                    // But the scroll offset is preserved in *points* while the content just
                    // got taller or shorter, so the row they were reading drifts. Put it back
                    // under them.
                    scroller.scrollTo(selection?.head ?? 0, anchor: .center)
                }
                .onAppear {
                    // A selection already set on first appearance was either restored from
                    // the last session or is the target of a jump that switched documents, so
                    // put it back on screen.
                    if let head = selection?.head {
                        scroller.scrollTo(head, anchor: .center)
                    }
                }
                // A fresh scroll view per document: resets the scroll position to the top
                // without needing macOS 15's `ScrollPosition`.
                //
                // Here, and **not** on the whole pane, which would take the `.focusable()`
                // responder below down with it on every document change: an arrow key would
                // then land in the next document with `isFocused` still reading true and
                // every key dead until the reader clicked a row.
                .id(patent.key)
            }
            .onChange(of: findRequest) { startFinding() }
            .onChange(of: patent.key) { refind() }
            .background { findShortcuts(scroller) }
            #if os(macOS)
                .background { copyShortcut }
            #endif
        }
        // macOS only, and this is the whole reason the pane is focusable at all: the two
        // responder-chain commands below are offered to the focused view. iOS has neither,
        // and asking for focus there had a visible cost — the reader view became first
        // responder with no input view of its own, so the software keyboard rose over the
        // bottom third of the document every time a navigation-bar menu opened.
        #if os(macOS)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onMoveCommand { move($0) }
            .onExitCommand { clearSelection() }
            .onCopyCommand { [copyItem()].compactMap { $0 } }
        #endif
    }

    // MARK: - Finding

    /// The find field's text, which runs the search on every keystroke and scrolls to what
    /// it finds — an incremental find, the way every find field since the first one has
    /// worked.
    ///
    /// The anchor is the **current match** when there is one and the reading position
    /// otherwise. That is what makes refining a query behave: typing `subs` after `sub` keeps
    /// the reader where `sub` put them instead of throwing them back up the document, while a
    /// query typed fresh starts from what they are reading.
    private func query(_ scroller: ScrollViewProxy) -> Binding<String> {
        Binding(
            get: { find.query },
            set: { typed in
                let anchor = find.current?.row ?? selection?.head
                find.search(typed, in: rows, near: anchor)
                if let match = find.current { scroll(to: match.row, with: scroller) }
            })
    }

    /// ⌘G, ⇧⌘G, Return in the field, and the bar's two chevrons.
    private func step(_ direction: Int, _ scroller: ScrollViewProxy) {
        guard let match = find.advance(by: direction) else { return }
        scroll(to: match.row, with: scroller)
    }

    /// Puts a hit on screen.
    ///
    /// Through the proxy directly and **not** by writing `scrollTarget`, which is the
    /// obvious route and a broken one: two hits in the same row write the same value twice,
    /// `.onChange` sees no change, and the second ⌘G silently does not scroll. That is not a
    /// corner case — it is a reader who panned away by hand, which a row index cannot see,
    /// looking at a highlight they cannot find.
    private func scroll(to row: Int, with scroller: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            scroller.scrollTo(row, anchor: .center)
        }
    }

    private func startFinding() {
        isFinding = true
        // Focused **next** main-actor turn, deliberately, and this is not a nicety: the field
        // does not exist until the bar is in the hierarchy, and a `@FocusState` write naming a
        // view SwiftUI has not created yet is dropped silently. ⌘F would raise the bar and
        // leave the keyboard in the document. Same deferral `LibraryView.scroll(_:)` makes for
        // the same class of reason — aiming at something that is not there yet.
        //
        // Also correct when the bar is already up, which is the case this exists for: ⌘F while
        // reading a hit means "let me type another term", so the keyboard comes back.
        Task { isFindFocused = true }
    }

    private func stopFinding() {
        isFinding = false
        isFindFocused = false
        find.clear()
        // The keyboard goes back to the document. Without this the arrows, Esc and ⌘C stay
        // dead after the bar closes, because nothing else would take first responder back.
        isFocused = true
    }

    /// The same query, run again against a different document.
    ///
    /// The query survives a document switch and the matches cannot. Keeping it is the point:
    /// a term of art is exactly the thing a reader carries from one patent to the next, so
    /// ⌘F and then clicking down the library is how they ask which of these patents talk
    /// about beam steering.
    ///
    /// Deliberately no scroll. The scroll view is brand new — `.id(patent.key)` — so it is at
    /// the top, and `.onAppear` is already putting the reading position back; a find scroll
    /// racing that would fight it.
    private func refind() {
        guard isFinding else { return }
        let query = find.query
        find.search(query, in: rows, near: nil)
    }

    /// ⌘F, ⌘G and ⇧⌘G. Keyboard shortcuts need a control to hang off; zero-opacity rather
    /// than `.hidden()`, which removes it from the hierarchy along with its shortcut.
    ///
    /// **⌘F is the document's, and the library's filter moved to ⌥⌘F to give it up.** Two
    /// hidden buttons cannot share a shortcut, and of the two fields this is the one ⌘F means
    /// everywhere else: find in the thing I am reading.
    @ViewBuilder
    private func findShortcuts(_ scroller: ScrollViewProxy) -> some View {
        Group {
            Button("Find in this patent") { startFinding() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find next") { step(1, scroller) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find previous") { step(-1, scroller) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ row: DocumentRow, spans: [PatentMarkup.Span]) -> some View {
        DocumentRowView(
            row: row,
            patent: patent,
            spans: spans,
            isSelected: selection?.contains(row.index) ?? false,
            highlights: find.highlights(in: row.index),
            hasFocus: bandHasFocus,
            flash: flash?.row == row.index ? flash?.id : nil,
            onLookUpWord: onLookUpWord,
            onOpen: onOpen
        )
        .id(row.index)
        .reportRowFrame(index: row.index, space: Self.space)
        // The `count: 2` gesture must be attached *before* the `count: 1` gesture or
        // SwiftUI resolves every double-click as two single clicks.
        .onTapGesture(count: 2) {
            select(PassageSelection.unit(at: row.index, in: rows))
        }
        .onTapGesture {
            // Read the modifiers synchronously from the event rather than through
            // `TapGesture().modifiers(.shift)`, which is unreliable here and would need a
            // separate gesture per modifier. Always false on iOS, where the long press on
            // the number margin is what extends a selection.
            if isShiftKeyDown, var extended = selection {
                extended.extend(to: row.index)
                select(extended)
            } else {
                select(PassageSelection(at: row.index))
            }
        }
    }

    /// Whether a point is on a row's **number margin** rather than on its prose.
    ///
    /// The boundary between the reader's two selections, as a hit test rather than a mode —
    /// because the two live side by side on screen, and a mode would make the reader declare
    /// in advance which one they meant. The margin prints the paragraph or claim number,
    /// which is not prose and can never be part of a quotation, so a press there can only
    /// mean "this row". Everything right of it is text the system lets them select.
    ///
    /// Points *left* of the row count as margin too. At a wide window the measured column is
    /// centred, so there is empty space out there; it is not text, and a press in it reads as
    /// aiming at the row it is level with.
    ///
    /// iOS only. macOS needs no equivalent because it no longer sweeps with a drag at all —
    /// see the note on `extendDrag(from:to:)`.
    #if !os(macOS)
        private func isOnMargin(_ point: CGPoint, of row: Int) -> Bool {
            guard let frame = rowFrames[row] else { return false }
            return point.x <= frame.minX + DocumentRowView.rowPadding + typeface.gutterWidth
        }
    #endif

    /// Whether the selection band should draw as though the pane holds the keyboard.
    ///
    /// `.focusable()` never becomes focused on a phone with no hardware keyboard, so the
    /// band would render in the unfocused grey for good. That grey means "the arrows are
    /// pointed somewhere else", and on a touch device there is nowhere else for them to
    /// point.
    private var bandHasFocus: Bool {
        #if os(macOS)
            isFocused
        #else
            true
        #endif
    }

    /// **Why macOS no longer sweeps rows with a drag.**
    ///
    /// It used to: a `DragGesture` per row, anchored on that row, hit-testing the head
    /// through `rowFrames`. Making the prose selectable took the pointer's drag for the text,
    /// and a row gesture layered over selectable text is the collision the phone made visible
    /// — two selections from one gesture — with the added macOS problem that a gesture on the
    /// row can consume the drag the text needs before the text ever sees it.
    ///
    /// Nothing became unreachable, which is what makes this a trade rather than a loss:
    /// click, shift-click, double-click for a whole section, and ⇧↑/⇧↓ all still build a
    /// multi-row passage, which is how a table has always done it. The phone keeps its sweep
    /// because it has no shift-click to fall back on — armed from the number margin, where
    /// there is no text to compete with.
    ///
    /// The touch sweep lives in `SweepRecognizer`, which a sequenced SwiftUI gesture cannot
    /// replace without taking the scroll view's pan with it.
    #if !os(macOS)
        private func extendDrag(from index: Int, to location: CGPoint) {
            if !isDragging {
                isDragging = true
                selection = PassageSelection(at: index)
                // Same reason as `select(_:)`: the pane has to hold the keyboard for the
                // arrows to keep working after a drag. Inside the guard, because this runs
                // per event and focus is not worth re-requesting at frame rate.
                isFocused = true
            }
            selection?.extend(to: rowFrames.line(at: location) ?? index)
        }
    #endif

    /// Caps a piece of the pane at the reading measure and centres what is left over.
    ///
    /// Applied to the content and **not** to the pane or the `ScrollView`. Capping either
    /// of those would put the scroll indicator at the measure's edge rather than at the
    /// pane's, and — worse — leave the margins *outside* the scroller, so a pan in the
    /// empty space beside the text on a wide iPad would not scroll the document at all.
    private func measured<V: View>(_ content: V) -> some View {
        content
            .frame(maxWidth: typeface.measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    #if os(macOS)
        /// ⇧⌘C, and why the app's own copy now has a key of its own.
        ///
        /// ⌘C used to be unambiguous: nothing else could be selected, so it meant the selected
        /// rows with `Citation.quotation` appended. With the prose selectable, ⌘C is what a
        /// reader presses to copy the phrase they just dragged out, and that expectation is the
        /// right one to honour. But the citation-appended quotation is a genuinely different
        /// thing and cannot be derived from a text selection, because SwiftUI never says which
        /// characters are in one. So it gets its own shortcut rather than depending on which
        /// handler the responder chain happens to offer ⌘C first.
        ///
        /// `.onCopyCommand` is deliberately left in place: with a row selected and no text
        /// selection — the ordinary case — ⌘C still copies the passage exactly as it always
        /// did, and removing it would have made ⌘C do nothing at all there.
        @ViewBuilder
        private var copyShortcut: some View {
            Button("Copy passage with citation") { copyPassage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }

        /// The selected rows, quoted, straight to the pasteboard.
        ///
        /// Writes the pasteboard rather than returning an `NSItemProvider` the way
        /// `copyItem()` does, for the reason `copyToPasteboard` documents: a keyboard shortcut
        /// on a `Button` is not a responder-chain command.
        private func copyPassage() {
            guard let range = selection?.clamped(to: rows)?.range else { return }
            copyToPasteboard(Citation.quotation(patent, rows: Array(rows[range])))
        }
    #endif

    // MARK: - Selection

    private func select(_ new: PassageSelection) {
        selection = new
        // Clicking in the reader is what hands the keyboard back to it. A tap gesture is
        // not an `NSControl`, so it never moves first responder on its own: after a click
        // in the library's `List` the sidebar keeps it, and the arrows, Esc and ⌘C here
        // are all dead until something takes it back.
        //
        // **No debounced commit.** `SceneReaderView` scheduled one 350 ms after every
        // selection change, because there selecting a passage *was* the request to
        // annotate it. Here a selection scopes the next question and starts nothing, so
        // there is nothing to debounce — which also means a programmatic jump can write
        // `selection` freely without arming a generation behind the reader's back.
        isFocused = true
    }

    /// Where an arrow key lands. macOS only: `MoveCommandDirection` is not available on
    /// iOS at all, and `.onMoveCommand`, its only caller, is not either.
    #if os(macOS)
        private func move(_ direction: MoveCommandDirection) {
            let step: Int
            switch direction {
            case .up: step = -1
            case .down: step = 1
            default: return
            }

            // Read the modifiers from the event for the same reason the click path does:
            // SwiftUI does not report them on a move command.
            guard
                let next = PassageSelection.moved(
                    from: selection, by: step, extending: isShiftKeyDown, in: rows)
            else { return }

            selection = next
            scrollTarget = next.head
        }
    #endif

    /// Esc.
    private func clearSelection() {
        // The find bar first, if it is up. Esc means "put that away", and the field's own
        // `.onExitCommand` only fires while the field holds the keyboard — so without this a
        // bar the reader had clicked out of would swallow every Esc from here on, since this
        // handler would keep clearing a selection instead of closing it.
        if isFinding {
            stopFinding()
            return
        }
        selection = nil
        onCancel()
    }

    #if os(macOS)
        /// The selected rows with the citation appended, wrapped for the responder chain.
        /// iOS copies the same string through `UIPasteboard` from `ContentView`'s
        /// toolbar, since `.onCopyCommand` has no counterpart there.
        private func copyItem() -> NSItemProvider? {
            guard let selection, let range = selection.clamped(to: rows)?.range
            else { return nil }
            let text = Citation.quotation(patent, rows: Array(rows[range]))
            return NSItemProvider(object: text as NSString)
        }
    #endif
}

/// A row to flash after a citation jump.
///
/// The `id` is what makes a repeat jump visible: `DocumentRowView` animates off a change
/// to it, so jumping twice to the same row fires twice, where a bare row index would be
/// "no change" the second time and the reader would click a chip and see nothing happen.
struct FlashHighlight: Equatable, Sendable {
    let row: Int
    let id: UUID

    init(row: Int) {
        self.row = row
        self.id = UUID()
    }
}
