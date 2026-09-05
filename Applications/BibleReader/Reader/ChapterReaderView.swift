// Copyright © 2026 Apple Inc.

import Foundation
import SwiftUI

/// One chapter, as a list of selectable rows.
///
/// **One chapter at a time, whole, with no chunking** is a deliberate constraint. The
/// worst cases are Psalm 118 at 176 verses and Numbers 7 at 89 long ones, both well
/// inside what the `LazyVStack` already handles — Hamlet II.ii is ~600 rows in
/// ShakespeareReader. It makes every selection intrinsically chapter-scoped so there is
/// no cross-chapter range to validate, and keeps the cache key trivial. The cost is no
/// continuous scroll through a book; the navigator is how you move.
@MainActor
struct ChapterReaderView: View {
    let book: Book
    let key: ChapterKey
    let chapter: Chapter

    @Binding var selection: VerseSelection?

    /// A row this view should put on screen and then forget.
    ///
    /// The gap `open(_:)` used to fall into. Setting `selection` scrolls nothing on its
    /// own: the only two things that scroll are `.onAppear` below — which fires when
    /// `.id(key)` rebuilds the scroll view, so on a *chapter change* — and the arrow-key
    /// `scrollTarget`. Following a reference into the chapter already open therefore
    /// selected a row somewhere off screen and left the reader looking at an unchanged
    /// page, which inline links hit constantly: an answer usually cites the chapter it is
    /// annotating. `ContentView` writes this **only** when the chapter did not change, so
    /// it cannot race the `.onAppear` path.
    @Binding var reveal: Int?

    /// Whether Challoner's notes are rendered inline. The reader's own setting, owned by
    /// `ContentView`'s typeface menu and defaulting **on** — it is what makes this a
    /// Challoner study Bible rather than a plain text with an AI layer over it.
    let showsNotes: Bool

    /// What produced a commit. Only a pointer selection is a fresh request to have a
    /// passage annotated, so only a pointer selection brings a hidden commentary pane
    /// back; arrow keys are how you move through a chapter with the Bible on its own.
    enum CommitOrigin: Sendable { case pointer, keyboard }

    /// Called 350 ms after the selection settles, and never while dragging, so sweeping
    /// through 40 verses starts exactly one generation. The origin says whether the
    /// reader pointed at the passage or arrowed onto it.
    let onCommit: (VerseSelection, CommitOrigin) -> Void
    let onCancel: () -> Void
    let onRegenerate: () -> Void

    /// Rolls into the neighbouring chapter when an arrow key runs off the edge of this
    /// one: `+1` forward, `-1` back. Stops at the ends of the Bible, since crossing into
    /// another book is the navigator's job.
    let onStepChapter: (Int) -> Void

    /// ⌘[ — back to where a cross-reference jump came from.
    let onGoBack: () -> Void
    /// Whether there is anywhere to go back to, so the shortcut is inert rather than
    /// silently doing nothing.
    let canGoBack: Bool

    /// A word right-clicked in the text, on its way to the system dictionary: the term
    /// and the baseline origin the panel should be popped at, in
    /// `DictionaryAnchor.space`. The anchor itself lives with the pane, in
    /// `ContentView.readerPane`, so this view only carries the point across.
    let onLookUpWord: (String, CGPoint) -> Void

    /// A word right-clicked in the text, on its way to the commentary pane as a
    /// question. The row index goes with it because the word's passage may not be the
    /// annotated one, and `ContentView` is what knows whether it has to select it first.
    let onExplainWord: (String, Int) -> Void

    /// The scripture references a row's text carries, for `VerseRow` to link. Supplied by
    /// `ContentView`, closed over the corpus, so neither this view nor the row it hands
    /// them to has to learn what is in this Bible.
    let noteLinks: (Row) -> [CrossReferenceStore.Hit]

    private static let space = "reader"
    private static let commitDelay = Duration.milliseconds(350)

    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var isDragging = false
    /// The row a long press armed a sweep on, and the anchor the sweep extends from.
    /// `nil` means no sweep is armed, which is every ordinary pan. iOS only; macOS takes
    /// the drag bare and carries its anchor in `selectionDrag(from:)`.
    @State private var sweepAnchor: Int?
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    /// The row an arrow move wants on screen, written by `move(_:)` and read back inside
    /// the `ScrollViewReader`, which is the only place a `ScrollViewProxy` exists.
    /// Cleared as each chapter appears, since this view outlives them.
    @State private var scrollTarget: Int?

    /// The face the Bible is set in. Injected here by `ContentView` and read by this view
    /// and `VerseRow`; nothing outside the reader pane sees it.
    @Environment(\.readerTypeface) private var typeface

    /// The rows actually rendered, which is `chapter.rows` with the notes taken out when
    /// the reader has turned them off.
    ///
    /// **Indices into this array are what a selection holds**, which is the one thing
    /// about `showsNotes` that is not cosmetic: turning notes off renumbers every row
    /// below the first note. `ContentView` clears the selection when the setting changes
    /// for exactly that reason, and `PassageContext` is built from this array too, so a
    /// hidden note is not fed to the model either. A reader who turned Challoner off
    /// meant it.
    private var rows: [Row] {
        showsNotes ? chapter.rows : chapter.rows.filter { $0.kind != .note }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            measured(heading)

            ScrollViewReader { scroller in
                ScrollView {
                    measured(
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                self.row(index: index, row: row)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.trailing, 12)
                        #if !os(macOS)
                            // Inside the scroll content on purpose: `SweepRecognizer` finds
                            // the scroll view by walking up from here, and a background of
                            // the `ScrollView` would sit outside it. Inside the measure too,
                            // and harmlessly: the recognizer converts into the scroll view's
                            // own content space, which is where `rowFrames` is measured too.
                            .background {
                                SweepRecognizer(
                                    onBegan: { point in
                                        guard let line = rowFrames.line(at: point) else { return }
                                        sweepAnchor = line
                                        extendDrag(from: line, to: point)
                                    },
                                    onChanged: { point in
                                        guard let sweepAnchor else { return }
                                        extendDrag(from: sweepAnchor, to: point)
                                    },
                                    onEnded: {
                                        sweepAnchor = nil
                                        if isDragging { endDrag() }
                                    }
                                )
                            }
                        #endif
                    )
                }
                .coordinateSpace(name: Self.space)
                #if !os(macOS)
                    // The other half of `SweepRecognizer`: it allows simultaneous
                    // recognition so it never inhibits the pan, which means once a sweep is
                    // under way the scroll view would otherwise still be panning under the
                    // finger doing it. macOS is left alone deliberately — there the wheel is
                    // not a `DragGesture`, so scrolling mid-drag is a feature rather than a
                    // collision.
                    .scrollDisabled(isDragging)
                #endif
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .onChange(of: scrollTarget) {
                    // Where an arrow move lands. Scrolling can only happen in here, with
                    // the proxy, while `.onMoveCommand` has to sit on the focusable view
                    // itself — see the note beside it below. So the move writes a row
                    // index and this puts it on screen.
                    if let scrollTarget {
                        scroller.scrollTo(scrollTarget, anchor: .center)
                    }
                }
                .onChange(of: reveal) {
                    // Where a reference inside the chapter already open lands. Cleared as
                    // it is spent, so following the same reference twice scrolls twice
                    // rather than reading as "no change" the second time — which is the
                    // ordinary case for a reader flicking between an answer and the verse
                    // it cites.
                    guard let reveal else { return }
                    scroller.scrollTo(reveal, anchor: .center)
                    self.reveal = nil
                }
                .onChange(of: typeface) {
                    // `.id(key)` does not change on a font switch, which is right — the
                    // reader keeps their place rather than being thrown back to the top
                    // of the chapter. But the scroll offset is preserved in *points*
                    // while the content just got taller or shorter, so the verse they
                    // were reading drifts. Put it back under them.
                    scroller.scrollTo(selection?.head ?? 0, anchor: .center)
                }
                .onAppear {
                    // This subtree was just rebuilt at the top of the chapter. A
                    // selection already set on first appearance was either restored from
                    // the last session, or is the edge row an arrow rolled onto, or is a
                    // cross-reference the commentary pane navigated to — so put it back
                    // on screen. `scrollTo` reaches a row that the `LazyVStack` has not
                    // materialized, because `ForEach` over the enumerated rows declares
                    // every id up front.
                    //
                    // `scrollTarget` outlives the chapter now that the identity below is
                    // the scroll view's rather than the whole pane's; clearing it keeps a
                    // move onto the same index as the last chapter's from being read as
                    // "no change" and skipping its scroll.
                    scrollTarget = nil
                    if let head = selection?.head {
                        scroller.scrollTo(head, anchor: .center)
                    }
                }
                // A fresh scroll view per chapter: resets the scroll position to the top
                // without needing macOS 15's `ScrollPosition`.
                //
                // Here, and **not** on the whole pane, which took the `.focusable()`
                // responder below down with it on every chapter change: an arrow-key roll
                // then landed in the next chapter with `isFocused` still reading true —
                // the band even stayed accent — and every key dead, arrows and Esc alike,
                // until the reader clicked a verse.
                .id(key)
            }
        }
        // macOS only, and this is the whole reason the pane is focusable at all: the
        // three responder-chain commands below are offered to the focused view. iOS has
        // none of them, and asking for focus there had a visible cost. The reader view
        // became first responder with no input view of its own, so the software keyboard
        // rose over the bottom third of the text every time a `Menu` in the navigation
        // bar opened. ⌘R still works with a hardware keyboard because it hangs off the
        // `Button` below, which needs no focus.
        #if os(macOS)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
        #endif
        .onChange(of: key) {
            // This view outlives the chapter, so a commit scheduled for the verse the
            // reader is leaving would land in a pane `ContentView` has just cleared for
            // the new one. The roll cancels it in `move(_:)` for the same reason; this
            // covers the navigator and the cross-reference jump.
            commitTask?.cancel()
        }
        .onChange(of: selection) {
            // A selection cleared from *outside* this view, where the iPhone toolbar's
            // Clear has no reach into `commitTask`, must take a pending commit with it or
            // the debounce fires 350 ms later and annotates the passage that was just
            // dismissed. Esc cancels explicitly as well, since that path wants the
            // cancellation to be immediate rather than a change notification behind.
            if selection == nil { commitTask?.cancel() }
        }
        // Beside `.focusable()` and **not** on the `ScrollView` inside, where it used to
        // be and never fired: a command handler is offered to the focused view and then
        // to its ancestors, never to its descendants, so the arrows were dead even with
        // the pane focused while `.onExitCommand` here worked. Hence `scrollTarget`
        // rather than the proxy, which only exists inside the `ScrollViewReader`.
        //
        // macOS only, all three: these are responder-chain commands with no iOS
        // equivalent. Their touch replacements are in `ContentView`'s reader toolbar
        // (Clear, Copy, Select chapter) and in `selectionDrag(from:)` below.
        #if os(macOS)
            .onMoveCommand { move($0) }
            .onExitCommand { clearSelection() }
            .onCopyCommand { [copyItem()].compactMap { $0 } }
        #endif
        .background {
            // Keyboard shortcuts need a control to hang off. Zero-opacity rather than
            // `.hidden()`, which removes it from the hierarchy along with its shortcut.
            //
            // Kept on iOS too: it costs nothing and works with a hardware keyboard. The
            // visible affordances there are the reader toolbar's items.
            VStack {
                Button("Regenerate", action: onRegenerate)
                    .keyboardShortcut("r", modifiers: .command)
                Button("Select Chapter", action: selectChapter)
                    .keyboardShortcut("a", modifiers: .command)
                Button("Back", action: onGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!canGoBack)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(index: Int, row: Row) -> some View {
        VerseRow(
            index: index,
            row: row,
            isPoetry: book.genre == .poetry,
            isSelected: selection?.contains(index) ?? false,
            isFirstSelected: selection?.range.lowerBound == index,
            hasFocus: bandHasFocus,
            onLookUpWord: onLookUpWord,
            onExplainWord: onExplainWord,
            noteLinks: noteLinks
        )
        .reportRowFrame(index: index, space: Self.space)
        // The `count: 2` gesture must be attached *before* the `count: 1` gesture or
        // SwiftUI resolves every double-click as two single clicks.
        .onTapGesture(count: 2) {
            select(VerseSelection.period(at: index, in: rows))
        }
        .onTapGesture {
            // Read the modifiers synchronously from the event rather than through
            // `TapGesture().modifiers(.shift)`, which is unreliable here and would need a
            // separate gesture per modifier. Always false on iOS, where the long press in
            // `selectionDrag(from:)` is what extends a selection.
            if isShiftKeyDown, var extended = selection {
                extended.extend(to: index)
                select(extended)
            } else {
                select(VerseSelection(at: index))
            }
        }
        #if os(macOS)
            .gesture(selectionDrag(from: index))
        #endif
        // iOS attaches nothing here. A `DragGesture` on these rows, in any shape, stops
        // the chapter from scrolling; the touch equivalent of the sweep is the
        // `SweepRecognizer` on the scroll view instead. See its own note.
        //
        // Nothing is attached here for word lookup either, on either platform. The hover
        // that marks a word and the menu that acts on it are both inside `VerseRow`, on
        // the text alone, and hover consumes neither clicks nor drags — which is the
        // reason the four gestures above did not have to be renegotiated to get it.
    }

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

    /// Sweeping a range of verses out with the pointer. macOS only — the touch
    /// equivalent is the pair of simultaneous gestures at the attachment site, which a
    /// sequenced gesture cannot do without taking the scroll view's pan with it.
    ///
    /// Attached per row so the anchor is this row's own index; only the head has to be
    /// hit-tested through `rowFrames`. No edge auto-scroll: on macOS the scroll wheel and
    /// two-finger scroll are not `DragGesture` events, so the reader can scroll mid-drag
    /// without the drag noticing. That same fact is why macOS can take the drag bare and
    /// iOS cannot: a touch pan *is* a `DragGesture`.
    #if os(macOS)
        private func selectionDrag(from index: Int) -> some Gesture {
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .onChanged { extendDrag(from: index, to: $0.location) }
                .onEnded { _ in endDrag() }
        }
    #endif

    /// The head of a drag moved. `index` is the row the gesture started on, which is the
    /// anchor, and `location` is hit-tested against `rowFrames` for the head.
    private func extendDrag(from index: Int, to location: CGPoint) {
        if !isDragging {
            isDragging = true
            selection = VerseSelection(at: index)
            // Same reason as `select(_:)`: the pane has to hold the keyboard for the
            // arrows to keep working after a drag. Inside the guard, because this runs
            // per event and focus is not worth re-requesting at frame rate.
            isFocused = true
        }
        selection?.extend(to: rowFrames.line(at: location) ?? index)
    }

    private func endDrag() {
        isDragging = false
        if let selection { scheduleCommit(selection, from: .pointer) }
    }

    /// Caps a piece of the pane at the reading measure and centres what is left over.
    ///
    /// Applied to the **heading and the text content separately**, and not to the pane or
    /// to the `ScrollView`. Capping either of those would put the scroll indicator at the
    /// measure's edge rather than at the pane's, and — worse — leave the margins *outside*
    /// the scroller, so a pan in the empty space beside the text on a wide iPad would not
    /// scroll the chapter at all. Both pieces rather than the text alone, so the heading
    /// stays aligned with the text it introduces on a wide pane.
    ///
    /// The measure narrows for a book of poetry, which with the looser leading and the
    /// inset in `VerseRow` is the whole of what this app does about verse layout. The
    /// source carries no line breaks and none are invented.
    private func measured<V: View>(_ content: V) -> some View {
        content
            .frame(
                maxWidth: book.genre == .poetry
                    ? typeface.poetryMeasure : typeface.measure,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Book, chapter, and Challoner's argument.
    ///
    /// The argument sits exactly where ShakespeareReader put the scene setting, and it is
    /// the best thing this edition gives the app for free: a one-sentence summary of the
    /// chapter, written by the editor whose notes are in the text, needing no model at
    /// all.
    ///
    /// It is **not** in `chapter.rows` and so cannot be selected, which is deliberate: a
    /// Challoner summary must not be annotatable as if it were scripture. It still
    /// reaches the prompt, from `PassageContext`.
    @ViewBuilder
    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(book.name)
                Text("·")
                Text("Chapter \(chapter.number)")
            }
            .font(typeface.chapterHeading)
            .tracking(typeface.chapterTracking)

            if let incipit = chapter.latinIncipit {
                Text(incipit)
                    .font(typeface.latinIncipit)
                    .foregroundStyle(.tertiary)
            }
            if let argument = chapter.argument {
                Text(argument)
                    .font(typeface.chapterArgument)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Selection

    private func select(_ new: VerseSelection) {
        selection = new
        // Clicking in the reader is what hands the keyboard back to it. A tap gesture is
        // not an `NSControl`, so it never moves first responder on its own: after a click
        // in the navigator's `List` the sidebar keeps it, and the arrows, Esc, ⌘C and ⌘R
        // here are all dead until something takes it back. `.onAppear` fires once,
        // outside `.id(key)`, so it cannot be that something.
        //
        // `isFocused` reads stale inside this closure — the write resolves on commit — so
        // nothing here may branch on it. Setting it beside `selection` is not a hazard:
        // both land in the one transaction.
        isFocused = true
        scheduleCommit(new, from: .pointer)
    }

    /// ⌘A, and the reader toolbar's Select Chapter on iOS.
    ///
    /// A chapter is the unit this reader renders and the unit a selection can never
    /// cross, so "select all" and "select chapter" are the same command. It exists
    /// because the whole chapter is a passage a reader genuinely wants annotated — the
    /// Decalogue, a psalm, the Prologue of John — and sweeping 176 verses to ask for one
    /// is not reasonable.
    private func selectChapter() {
        guard let whole = VerseSelection.chapter(rows) else { return }
        select(whole)
    }

    /// Debounces so a sweep through 40 verses starts one generation, not 40, and so a
    /// click that is really the start of a shift-click does not fire first.
    private func scheduleCommit(_ new: VerseSelection, from origin: CommitOrigin) {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled, !isDragging else { return }
            onCommit(new, origin)
        }
    }

    /// Where an arrow key lands. macOS only: `MoveCommandDirection` is not available on
    /// iOS at all, and `.onMoveCommand`, its only caller, is not either. A hardware
    /// keyboard attached to a phone therefore does not move the selection. The touch
    /// equivalents are tap and press-and-hold-then-drag.
    #if os(macOS)
        private func move(_ direction: MoveCommandDirection) {
            let step: Int
            switch direction {
            case .up: step = -1
            case .down: step = 1
            default: return
            }

            // Read the modifiers from the event for the same reason the click path does
            // at `row(index:row:)`: SwiftUI does not report them on a move command.
            let extending = isShiftKeyDown
            guard
                let next = VerseSelection.moved(
                    from: selection, by: step, extending: extending, in: rows)
            else {
                // Off the edge of the chapter, with nothing to extend: roll into the next
                // one. Cancelling first matters — `.id(key)` replaces this subtree on a
                // roll, and a commit already scheduled for the verse being left would
                // land in a pane `ContentView` has just cleared for the new chapter.
                commitTask?.cancel()
                onStepChapter(step)
                return
            }

            selection = next
            scrollTarget = next.head
            scheduleCommit(next, from: .keyboard)
        }
    #endif

    // MARK: - Copy

    /// Esc, and the reader toolbar's Clear on iOS.
    private func clearSelection() {
        commitTask?.cancel()
        selection = nil
        onCancel()
    }

    #if os(macOS)
        /// The selected rows with the citation appended, wrapped for the responder chain.
        /// iOS copies the same string through `UIPasteboard` from `ContentView`'s reader
        /// toolbar, since `.onCopyCommand` has no counterpart there.
        private func copyItem() -> NSItemProvider? {
            guard let text = quotation() else { return nil }
            return NSItemProvider(object: text as NSString)
        }
    #endif

    /// The selected rows as quotable text. Internal rather than private because the iOS
    /// reader toolbar copies through `ContentView`.
    func quotation() -> String? {
        guard let selection, let range = selection.clamped(to: rows)?.range
        else { return nil }
        // Built against the rendered chapter rather than `chapter.rows`, so a reader with
        // notes turned off copies what they can see.
        let rendered = Chapter(
            number: chapter.number, latinIncipit: chapter.latinIncipit,
            argument: chapter.argument, rows: rows)
        return Citation.quotation(book: book, chapter: rendered, range: range)
    }
}
