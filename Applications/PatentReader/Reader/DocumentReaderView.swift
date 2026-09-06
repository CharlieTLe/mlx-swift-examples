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

    private static let space = "reader"

    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var isDragging = false
    /// The row a long press armed a sweep on, and the anchor the sweep extends from.
    /// `nil` means no sweep is armed, which is every ordinary pan. iOS only; macOS takes
    /// the drag bare and carries its anchor in `selectionDrag(from:)`.
    @State private var sweepAnchor: Int?
    @FocusState private var isFocused: Bool

    /// The document's markup spans, computed once and handed to the rows.
    @State private var spansBox = DocumentSpansBox()

    @Environment(\.readerTypeface) private var typeface

    var body: some View {
        ScrollViewReader { scroller in
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
                                    guard let row = rowFrames.line(at: point) else { return }
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

    // MARK: - Rows

    @ViewBuilder
    private func row(_ row: DocumentRow, spans: [PatentMarkup.Span]) -> some View {
        DocumentRowView(
            row: row,
            patent: patent,
            spans: spans,
            isSelected: selection?.contains(row.index) ?? false,
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
            // separate gesture per modifier. Always false on iOS, where the long press in
            // `selectionDrag(from:)` is what extends a selection.
            if isShiftKeyDown, var extended = selection {
                extended.extend(to: row.index)
                select(extended)
            } else {
                select(PassageSelection(at: row.index))
            }
        }
        #if os(macOS)
            .gesture(selectionDrag(from: row.index))
        #endif
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

    /// Sweeping a range of rows out with the pointer. macOS only — the touch equivalent
    /// is `SweepRecognizer`, which a sequenced SwiftUI gesture cannot replace without
    /// taking the scroll view's pan with it.
    ///
    /// Attached per row so the anchor is this row's own index; only the head has to be
    /// hit-tested through `rowFrames`. No edge auto-scroll: on macOS the scroll wheel and
    /// two-finger scroll are not `DragGesture` events, so the reader can scroll mid-drag
    /// without the drag noticing. That same fact is why macOS can take the drag bare and
    /// iOS cannot — a touch pan *is* a `DragGesture`.
    #if os(macOS)
        private func selectionDrag(from index: Int) -> some Gesture {
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .onChanged { extendDrag(from: index, to: $0.location) }
                .onEnded { _ in isDragging = false }
        }
    #endif

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
