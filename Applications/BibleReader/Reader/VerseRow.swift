// Copyright © 2026 Apple Inc.

import CoreText
import SwiftUI

/// One row of the chapter: number gutter and the text.
///
/// Selected styling is deliberately **size-neutral** — a background fill, a left accent
/// rule, and a colour change, with no weight or size change. Row height feeds
/// `RowFramesKey`, which is written into `@State`, which is read back during layout;
/// anything that makes height depend on selection closes that loop. The hovered word's
/// mark is bound by the same contract, and that is why it is an underline: an underline
/// is drawn inside the line box, where a heavier weight or a larger size would reflow
/// the row the pointer is sitting on.
///
/// Changing the typeface resizes every row and so is *not* that loop: `rowFrames` is
/// written from a preference and read **only** inside the drag gesture in
/// `ChapterReaderView.row(index:row:)`, never in `body`, so a font change is a one-shot
/// relayout that settles. Selection is the thing that has to stay size-neutral, because
/// `isSelected` *is* read during layout.
///
/// The catchword's italic run and the per-row alignment below are in the typeface's
/// category and not selection's: both are derived from the row's own content, so they
/// are constant for the life of the row and settle in one pass.
@MainActor
struct VerseRow: View {
    let index: Int
    let row: Row

    /// Whether this row belongs to a book set as poetry, which narrows its measure,
    /// loosens its leading and insets it. Typography only — the source carries no line
    /// breaks and this app does not invent any. See `ReaderTypeface.poetryMeasure`.
    let isPoetry: Bool

    let isSelected: Bool
    let isFirstSelected: Bool

    /// Whether the reader pane holds the keyboard. Focus stays in the navigator when a
    /// chapter is picked there, so the band goes grey to say the arrows are pointed
    /// somewhere else, the way an unfocused `NSTableView` does. Colour **only**: this is
    /// read during layout just as `isSelected` is, so it is bound by the same
    /// size-neutrality contract above.
    let hasFocus: Bool

    /// A word of this row, and where its dictionary panel should be popped: the word's
    /// baseline origin in `DictionaryAnchor.space`. Both are macOS-only paths today; on
    /// iOS nothing calls them, because there is no context menu to call them from.
    let onLookUpWord: (String, CGPoint) -> Void

    /// A word of this row, to be asked about in the commentary pane. The row index goes
    /// with it, because the passage may not be the one currently glossed.
    let onExplainWord: (String, Int) -> Void

    /// The scripture references this row's text carries, resolved against the corpus.
    ///
    /// A closure rather than the corpus itself, which is how the commentary pane is fed
    /// too: the reader knows how to draw a link and nothing about which verses exist.
    /// **Notes only** — `ChapterReaderView` hands back nothing for a verse, since this
    /// edition's verses carry no cross-references and 35,805 of the 37,000-odd rows are
    /// better left out of the link machinery entirely.
    let noteLinks: (Row) -> [CrossReferenceStore.Hit]

    @Environment(\.readerTypeface) private var typeface

    /// The word under the pointer, as a range of `row.displayText`.
    ///
    /// Local to the row and **not** on `ChapterReaderView`, which is the difference
    /// between invalidating one row's body as the pointer crosses a word boundary and
    /// invalidating every visible row's. Written only when the resolved range changes,
    /// rather than once per hover event, for the same reason.
    @State private var marked: Range<String.Index>?

    /// This row's linkable references, resolved once when the row appears rather than on
    /// every hover event: `noteLinks` runs three regexes over the text, and the pointer
    /// crossing a word boundary re-evaluates `body`. Held here for the same reason
    /// `marked` is — it belongs to one row, and a `@State` on the reader would invalidate
    /// every visible row whenever any of them changed.
    ///
    /// If this ever shows up in a profile the real fix is to retain the spans in
    /// `CrossReferenceStore`, which already scans every note once at load.
    @State private var links: [CrossReferenceStore.Hit] = []

    /// The text's own frame, in `DictionaryAnchor.space`.
    ///
    /// A reference box and deliberately **not** `@State`: it is written from geometry and
    /// read only inside the hover handler, never in `body`, so measuring the row can never
    /// invalidate the row it measured. This is what `rowFrames` does one level up, for the
    /// same reason.
    @State private var textFrame = FrameBox()

    /// Row insets. A section heading is centred with a margin either side, so a long one
    /// does not centre across the whole measure. A note is indented on the leading side
    /// only, which is how a printed edition says it is subordinate to the verse above it.
    /// A verse of poetry sits in from the prose margin. The measure itself is the
    /// typeface's, because it is proportional to the type it insets.
    private var insets: (leading: CGFloat, trailing: CGFloat) {
        switch row.kind {
        case .verse: isPoetry ? (typeface.poetryInset, 0) : (0, 0)
        case .sectionHeading: (typeface.sectionInset, typeface.sectionInset)
        case .note: (typeface.noteInset, 0)
        }
    }

    /// Where each *visual* line sits when the text wraps.
    private var textAlignment: TextAlignment {
        row.kind == .sectionHeading ? .center : .leading
    }

    /// Where the text sits inside the row when it does **not** wrap. Neither this nor
    /// `textAlignment` is redundant: one does the work in each case.
    private var frameAlignment: Alignment {
        row.kind == .sectionHeading ? .center : .leading
    }

    /// The same, for the shadow layout. `.natural` and not `.left` for a verse, so the
    /// shipped path in `WordHitTest.layout(_:_:)` stays the shipped path.
    private var hitTestAlignment: CTTextAlignment {
        row.kind == .sectionHeading ? .center : .natural
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(numberLabel)
                // The *face* stays the system's whatever the Bible is set in, because a
                // serif family has no monospaced digits. The *size* does not: it
                // follows the reader's step, so the numbers stay legible beside the
                // verse. Font and width come from the typeface together and never one
                // without the other — the width is a budget for the widest label, so a
                // bigger font in a fixed frame is the clipping case.
                .font(typeface.gutterFont)
                .foregroundStyle(.tertiary)
                .frame(width: typeface.gutterWidth, alignment: .trailing)

            scripture
                .padding(.top, row.kind == .sectionHeading ? typeface.sectionGap : 0)
        }
        // Hit target and chrome, not typography, so neither of these scales with the
        // typeface the way `sectionGap` above does.
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(alignment: .leading) {
            if isSelected {
                ZStack(alignment: .leading) {
                    Rectangle().fill(bandFill)
                    Rectangle()
                        .fill(bandRule)
                        .frame(width: 2)
                }
            }
        }
        .contentShape(Rectangle())
        // The row survives a chapter change — `LazyVStack` reuses it by index — so the
        // spans have to be re-resolved when the row's content changes under it, not only
        // when it first appears.
        .onAppear { links = noteLinks(row) }
        .onChange(of: row) { links = noteLinks(row) }
    }

    /// The text itself, and the only thing in the row a word can be looked up from:
    /// right-clicking the number gutter offers no word, which is correct — it is not
    /// the Bible.
    @ViewBuilder
    private var scripture: some View {
        markedText
            .font(font)
            .foregroundStyle(row.isVerse ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .kerning(row.kind == .sectionHeading ? typeface.sectionTracking : 0)
            .lineSpacing(isPoetry && row.isVerse ? typeface.poetryLineSpacing : 0)
            .multilineTextAlignment(textAlignment)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            textFrame.rect = geometry.frame(
                                in: .named(DictionaryAnchor.space))
                        }
                        .onChange(
                            of: geometry.frame(in: .named(DictionaryAnchor.space))
                        ) { _, frame in
                            textFrame.rect = frame
                        }
                }
            }
            // macOS only, both of them, and for different reasons. Hover is a pointer
            // event a phone does not have; the menu is a *long press* there, which is
            // already how `SweepRecognizer` arms a sweep — the app's primary touch
            // interaction — so wiring word lookup up on iOS is a separate question about
            // which gesture wins, not a matter of dropping these in.
            #if os(macOS)
                // Hover consumes neither clicks nor drags, so nothing about selection
                // changes: click still selects, shift-click extends, double-click takes
                // the period and a drag still sweeps. That is why the word is resolved
                // here rather than from `NSApp.currentEvent` when the menu opens, which
                // would mean converting a window point across AppKit's flipped Y into a
                // SwiftUI space.
                .onContinuousHover(coordinateSpace: .named(DictionaryAnchor.space)) { phase in
                    switch phase {
                    case .active(let point):
                        let resolved = resolvedWord(at: point)
                        if resolved != marked { marked = resolved }
                    case .ended:
                        if marked != nil { marked = nil }
                    }
                }
                .contextMenu { wordMenu }
            #endif
    }

    private var font: Font {
        switch row.kind {
        case .verse: typeface.verse
        case .sectionHeading: typeface.sectionHeading
        case .note: typeface.note
        }
    }

    /// The text, with the catchword set italic, scripture references linked, and the
    /// hovered word underlined.
    ///
    /// An `AttributedString` is built **only** when there is something to say about a run
    /// of the row: with no catchword, no reference and nothing hovered this is
    /// `Text(row.displayText)` on the identical code path ShakespeareReader takes for a
    /// verse. Same move `ReaderTextSize` makes by short-circuiting to the bare text style
    /// at `.default` — the shipped rendering stays what it is rather than becoming
    /// something equivalent to it. That fast path is 35,805 of the corpus's rows.
    ///
    /// The catchword first, the links second and the underline last, so a run that
    /// overlaps another splits it correctly rather than being split by it. A hovered word
    /// inside a linked reference is the case that orders the last two.
    private var markedText: Text {
        let text = row.displayText
        let spans = row.italicSpans
        guard marked != nil || !spans.isEmpty || !links.isEmpty else { return Text(text) }

        var string = AttributedString(text)
        for span in spans {
            guard let range = attributedRange(span, of: text, in: string) else { continue }
            // The run's own `.font`, and deliberately **not**
            // `inlinePresentationIntent = .emphasized`: that hands the italic back to
            // SwiftUI to synthesize and takes Big Caslon's hand-sheared oblique — which
            // is also what the shadow layout is measured against — out of the picture.
            string[range].font = typeface.noteItalic
        }

        // Challoner's own `Gen. 2.24` and `chap. 5.3`, made followable. Only what
        // resolves against this Bible is touched: an unresolved span in a 1750 note is far
        // more likely to be this app mis-parsing him than Challoner citing a verse that
        // does not exist, so it is left exactly as printed rather than struck through the
        // way the model's prose is.
        ReferenceLinks.apply(links, to: &string, of: text)

        if let marked,
            let lower = AttributedString.Index(marked.lowerBound, within: string),
            let upper = AttributedString.Index(marked.upperBound, within: string)
        {
            // An underline rather than a background fill, so the mark does not compete
            // with the selection band, which is already a fill. `Text.LineStyle` and not
            // `NSUnderlineStyle`: both scopes spell this attribute `underlineStyle`, and
            // only the SwiftUI one is the attribute a `Text` draws.
            string[lower ..< upper].underlineStyle = Text.LineStyle.single
        }
        return Text(string)
    }

    /// An italic span, in the coordinates an `AttributedString` is subscripted by. UTF-16
    /// offsets are what crosses the gap, because `displayText` is computed and so hands
    /// out a different `String` instance every time it is asked.
    private func attributedRange(
        _ span: Range<Int>, of text: String, in string: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard span.lowerBound >= 0, span.lowerBound < span.upperBound,
            span.upperBound <= text.utf16.count
        else { return nil }
        let lower = String.Index(utf16Offset: span.lowerBound, in: text)
        let upper = String.Index(utf16Offset: span.upperBound, in: text)
        guard let start = AttributedString.Index(lower, within: string),
            let end = AttributedString.Index(upper, within: string)
        else { return nil }
        return start ..< end
    }

    /// The word under a point, or `nil` — a space, punctuation, or the blank right of a
    /// short line. `nil` marks nothing and offers nothing, which is what makes a
    /// hit-testing near-miss something the reader can see before committing to it.
    private func resolvedWord(at point: CGPoint) -> Range<String.Index>? {
        let frame = textFrame.rect
        // The insets are part of the row, not of the text: the `Text` starts that far
        // in, so both the point and the wrap width are measured from where it starts.
        let local = CGPoint(
            x: point.x - frame.minX - insets.leading, y: point.y - frame.minY)
        guard
            let index = WordHitTest.characterIndex(
                at: local, in: row.displayText, layout: hitTestLayout)
        else { return nil }
        return WordTokenizer.word(at: index, in: row.displayText)
    }

    /// The wrap width the `Text` was given: the row's own frame, less both insets.
    private var textWidth: CGFloat {
        textFrame.rect.width - insets.leading - insets.trailing
    }

    /// The shadow layout, which has to reproduce what SwiftUI drew.
    private var hitTestLayout: WordHitTest.Layout {
        WordHitTest.Layout(
            font: row.kind == .note
                ? typeface.notePlatformFont : typeface.versePlatformFont,
            italicFont: typeface.noteItalicPlatformFont,
            italics: row.italicSpans,
            alignment: hitTestAlignment,
            width: textWidth)
    }

    /// Look Up, Explain, Copy — and nothing at all where no word resolved, so the menu
    /// never names a word the reader was not pointing at.
    ///
    /// **Right-clicking deliberately does not select the row.** macOS convention says it
    /// should, but selecting here commits a generation 350 ms later, which is far too
    /// heavy a side effect for opening a menu. Only "Explain" moves the selection, and
    /// only because it has to have a passage to ask about.
    @ViewBuilder
    private var wordMenu: some View {
        if let marked {
            let term = WordTokenizer.term(for: marked, in: row.displayText)
            if !term.isEmpty {
                // Gated on the dictionary actually having an entry, so `Paralipomenon`
                // is offered no panel rather than an empty one.
                if DictionaryAnchor.hasDefinition(for: term) {
                    Button("Look Up “\(term)”") { lookUp(term, from: marked) }
                }
                Button("Explain “\(term)” in context") { onExplainWord(term, index) }
                Divider()
                Button("Copy “\(term)”") { copyToPasteboard(term) }
            }
        }
    }

    /// The panel is anchored to the start of the word rather than to wherever in it the
    /// reader right-clicked, so it lands the same way twice.
    private func lookUp(_ term: String, from range: Range<String.Index>) {
        let frame = textFrame.rect
        guard
            let origin = WordHitTest.baselineOrigin(
                of: range.lowerBound, in: row.displayText, layout: hitTestLayout)
        else { return }
        onLookUpWord(
            term,
            CGPoint(
                x: origin.x + frame.minX + insets.leading, y: origin.y + frame.minY))
    }

    /// `AnyShapeStyle` because the two branches are different style types, which is the
    /// house idiom (`ContentView.paneToggle`).
    private var bandFill: AnyShapeStyle {
        hasFocus
            ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary)
    }

    private var bandRule: AnyShapeStyle {
        hasFocus ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
    }

    /// **Every verse, always.**
    ///
    /// ShakespeareReader printed a number every fifth line, because a line number in a
    /// play is a citation aid and nothing more. A verse number is how scripture is
    /// addressed: it is the thing a reader looks for, the thing they type into the find
    /// field, and the thing every cross-reference names. Printing four out of five of
    /// them would be worse than printing none.
    ///
    /// The number stays in the **gutter** and out of `row.text`, despite inline
    /// superscript being the printed convention. Inlining it would put a non-word glyph
    /// inside the string that `WordHitTest`, `WordTokenizer` and `QuoteCheck.normalized`
    /// all operate on. The gutter keeps the text a clean string, keeps the number out of
    /// what the reader copies, and keeps it out of what the model is shown.
    private var numberLabel: String {
        row.printedNumber ?? ""
    }
}

/// A frame, held by reference so that writing it is not a view update.
///
/// The `@State` that holds one of these never changes identity, so the row is never
/// invalidated by measuring itself — which is the whole point, since the thing being
/// measured is the text whose height feeds `RowFramesKey`.
@MainActor
final class FrameBox {
    var rect: CGRect = .zero
}
