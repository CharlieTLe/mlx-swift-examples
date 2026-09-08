// Copyright © 2026 Apple Inc.

import SwiftUI

/// The reader's find bar: a field over the open patent, a count, and the two directions.
///
/// Hand-rolled and shared, not `.searchable`, for `LibraryView`'s reason one pane over —
/// on a Mac the reader is a bare `ScrollView` inside an `HSplitView` with no toolbar for a
/// search field to go in, and on a phone `.searchable` would render into the navigation bar,
/// which already holds four controls and belongs to the document's title.
///
/// It sits **above** the scroll view rather than floating over it, which is the one visual
/// choice here worth defending. A floating bar is what a browser does, and a browser can
/// afford it: its content is a page it does not own. This pane's content is measured to about
/// 70 characters and centred, so a floating bar would either cover the text it is finding or
/// hang in the margin beside it. A band that pushes the document down covers nothing.
///
/// **The count is the feature, not decoration.** `3 of 47` is what tells a reader that
/// "substrate" is used throughout rather than once, and it is the difference between a find
/// field and a jump: with a total on screen, ⌘G is a survey of how a term is used across the
/// specification.
@MainActor
struct FindBar: View {
    @Binding var text: String

    /// `3 of 47`, `No matches`, or nothing while the query is too short to have been run.
    let summary: String?

    /// Whether the two direction buttons do anything.
    let hasMatches: Bool

    /// Owned by the reader view, which has to be able to put the keyboard here when ⌘F
    /// arrives while the bar is already up — the case where presenting it is not enough.
    @FocusState.Binding var isFocused: Bool

    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Find in this patent", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(onNext)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .submitLabel(.search)
                    // Deliberately not `.never`: a patent is full of capitalised terms of
                    // art and the search is case-insensitive anyway, so what the keyboard
                    // offers costs the reader nothing either way. What *would* cost them is
                    // autocorrect rewriting `busbar` into `bus bar`, which is why that is
                    // off above.
                    .textInputAutocapitalization(.sentences)
                #else
                    // Esc belongs to the field while it holds the keyboard, exactly as it
                    // does in the library — and here it has to close the bar rather than
                    // only clear it, because the reader pane's own `.onExitCommand` clears
                    // the selection and a bar left open would keep swallowing Esc.
                    .onExitCommand(perform: onClose)
                #endif

            if let summary {
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hasMatches ? .secondary : .tertiary)
                    // Fixed so the field does not resize as the count crosses a digit
                    // boundary, which at `9 of 10` → `10 of 10` is every other keystroke.
                    .frame(minWidth: 64, alignment: .trailing)
                    .accessibilityLabel(summary)
            }

            step("chevron.up", label: "Previous match", shortcut: "⇧⌘G", action: onPrevious)
            step("chevron.down", label: "Next match", shortcut: "⌘G", action: onNext)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop finding (Esc)")
            .accessibilityLabel("Stop finding")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// One of the two directions. Disabled rather than hidden with nothing found, so the
    /// bar does not change width as the reader types.
    @ViewBuilder
    private func step(
        _ systemImage: String, label: String, shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasMatches ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .disabled(!hasMatches)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
    }
}
