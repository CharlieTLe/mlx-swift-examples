// Copyright © 2026 Apple Inc.

import CoreText
import SwiftUI

/// One line of the play: number gutter, optional speaker heading, the text.
///
/// Selected styling is deliberately **size-neutral** — a background fill, a left
/// accent rule, and a colour change, with no weight or size change. Row height
/// feeds `RowFramesKey`, which is written into `@State`, which is read back during
/// layout; anything that makes height depend on selection closes that loop. The
/// hovered word's mark is bound by the same contract, and that is why it is an
/// underline: an underline is drawn inside the line box, where a heavier weight or a
/// larger size would reflow the row the pointer is sitting on.
///
/// Changing the typeface resizes every row and so is *not* that loop: `rowFrames` is
/// written from a preference and read **only** inside the drag gesture in
/// `SceneReaderView.row(index:line:)`, never in `body`, so a font change is a one-shot
/// relayout that settles. Selection is the thing that has to stay size-neutral,
/// because `isSelected` *is* read during layout.
///
/// The italic runs and the per-line alignment below are in the typeface's category and
/// not selection's: both are derived from the line's own content, so they are constant
/// for the life of the row and settle in one pass. Nothing reads them during layout.
@MainActor
struct LineRow: View {
    let index: Int
    let line: Line

    /// The italic spans of this line, as UTF-16 ranges of `line.plainText`.
    ///
    /// Computed once per scene by `SceneReaderView` rather than per row, because `body`
    /// re-evaluates on every selection change and at frame rate through a drag, and
    /// Hamlet II.ii is ~600 lines. Empty for a stage direction, which is drawn italic
    /// end to end.
    let italics: [Range<Int>]

    let display: String?
    let isSelected: Bool
    let isFirstSelected: Bool

    /// Whether the reader pane holds the keyboard. Focus stays in the navigator when a
    /// scene is picked there, so the band goes grey to say the arrows are pointed
    /// somewhere else, the way an unfocused `NSTableView` does. Colour **only**: this is
    /// read during layout just as `isSelected` is, so it is bound by the same
    /// size-neutrality contract above.
    let hasFocus: Bool

    /// A word of this line, and where its dictionary panel should be popped: the word's
    /// baseline origin in `DictionaryAnchor.space`. Both are macOS-only paths today; on
    /// iOS nothing calls them, because there is no context menu to call them from.
    let onLookUpWord: (String, CGPoint) -> Void

    /// A word of this line, to be asked about in the commentary pane. The line index goes
    /// with it, because the passage may not be the one currently glossed.
    let onExplainWord: (String, Int) -> Void

    @Environment(\.readerTypeface) private var typeface

    /// The word under the pointer, as a range of `line.plainText`.
    ///
    /// Local to the row and **not** on `SceneReaderView`, which is the difference between
    /// invalidating one row's body as the pointer crosses a word boundary and invalidating
    /// every visible row's. Written only when the resolved range changes, rather than once
    /// per hover event, for the same reason.
    @State private var marked: Range<String.Index>?

    /// The verse `Text`'s own frame, in `DictionaryAnchor.space`.
    ///
    /// A reference box and deliberately **not** `@State`: it is written from geometry and
    /// read only inside the hover handler, never in `body`, so measuring the row can never
    /// invalidate the row it measured. This is what `rowFrames` does one level up, for the
    /// same reason.
    @State private var verseFrame = FrameBox()

    /// Verse insets. Gutenberg's own edition gives a centred entrance a 1em margin
    /// either side, so a long one does not centre across the whole measure, and gives
    /// a right-aligned exit none: it hangs off the measure's right edge, which is what
    /// both that edition and a printed one do. Speech has neither. The measure itself
    /// is the typeface's, because it is proportional to the type it insets.
    private var insets: (leading: CGFloat, trailing: CGFloat) {
        switch line.presentation {
        case .verse: (0, 0)
        case .sceneDescription: (typeface.directionInset, typeface.directionInset)
        case .bracketedDirection: (0, 0)
        }
    }

    /// Where each *visual* line sits when the text wraps.
    private var textAlignment: TextAlignment {
        switch line.presentation {
        case .verse: .leading
        case .sceneDescription: .center
        case .bracketedDirection: .trailing
        }
    }

    /// Where the text sits inside the row when it does **not** wrap. Neither this nor
    /// `textAlignment` is redundant: one does the work in each case.
    private var frameAlignment: Alignment {
        switch line.presentation {
        case .verse: .leading
        case .sceneDescription: .center
        case .bracketedDirection: .trailing
        }
    }

    /// The same, for the shadow layout. `.natural` and not `.left` for verse, so the
    /// shipped path in `WordHitTest.layout(_:_:)` stays the shipped path.
    private var hitTestAlignment: CTTextAlignment {
        switch line.presentation {
        case .verse: .natural
        case .sceneDescription: .center
        case .bracketedDirection: .right
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(numberLabel)
                // The *face* stays the system's whatever the play is set in, because a
                // serif family has no monospaced digits. The *size* does not: it
                // follows the reader's step, so the numbers stay legible beside the
                // verse. Font and width come from the typeface together and never one
                // without the other — the width is a budget for three digits'
                // advances, so a bigger font in a fixed frame is the clipping case.
                .font(typeface.gutterFont)
                .foregroundStyle(.tertiary)
                .frame(width: typeface.gutterWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                if line.startsSpeech, let display {
                    Text(display.uppercased())
                        .font(typeface.speakerHeading)
                        .foregroundStyle(.secondary)
                        .kerning(typeface.speakerTracking)
                        .padding(.top, index == 0 ? 0 : typeface.speechGap)
                }
                verse
            }
        }
        // Hit target and chrome, not typography, so neither of these scales with the
        // typeface the way `speechGap` above does.
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
    }

    /// The play text itself, and the only thing in the row a word can be looked up from:
    /// right-clicking the number gutter or the speaker heading offers no word, which is
    /// correct — neither is the play.
    @ViewBuilder
    private var verse: some View {
        markedText
            .font(line.isDirection ? typeface.direction : typeface.verse)
            .foregroundStyle(line.isDirection ? .secondary : .primary)
            .multilineTextAlignment(textAlignment)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            verseFrame.rect = geometry.frame(
                                in: .named(DictionaryAnchor.space))
                        }
                        .onChange(
                            of: geometry.frame(in: .named(DictionaryAnchor.space))
                        ) { _, frame in
                            verseFrame.rect = frame
                        }
                }
            }
            // macOS only, both of them, and for different reasons. Hover is a pointer
            // event a phone does not have; the menu is a *long press* there, which is
            // already how `SweepRecognizer` arms a sweep — the app's primary touch
            // interaction — so wiring word lookup up on iOS is a separate question about
            // which gesture wins, not a matter of dropping these in.
            #if os(macOS)
                // Hover consumes neither clicks nor drags, so nothing about selection changes:
                // click still selects, shift-click extends, double-click takes the speech and
                // a drag still sweeps. That is why the word is resolved here rather than from
                // `NSApp.currentEvent` when the menu opens, which would mean converting a
                // window point across AppKit's flipped Y into a SwiftUI space.
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

    /// The verse, with its italic spans set and the hovered word underlined.
    ///
    /// An `AttributedString` is built **only** when there is something to say about a
    /// run of the line: with no span and nothing hovered this is `Text(line.plainText)`
    /// on the identical code path the app has always taken. Same move `ReaderTextSize`
    /// makes by short-circuiting to the bare text style at `.default` — the shipped
    /// rendering stays what it is rather than becoming something equivalent to it.
    ///
    /// Italic runs first and the underline second, so an underline that overlaps a span
    /// splits it correctly rather than being split by it.
    private var markedText: Text {
        let text = line.plainText
        guard marked != nil || !italics.isEmpty else { return Text(text) }

        var string = AttributedString(text)
        for span in italics {
            guard let range = attributedRange(span, of: text, in: string) else { continue }
            // The run's own `.font`, and deliberately **not**
            // `inlinePresentationIntent = .emphasized`: that hands the italic back to
            // SwiftUI to synthesize and takes Big Caslon's hand-sheared oblique — which
            // is also what the shadow layout is measured against — out of the picture.
            string[range].font = typeface.verseItalic
        }

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

    /// A `GutenbergMarkup` span, in the coordinates an `AttributedString` is subscripted
    /// by. UTF-16 offsets are what crosses the gap, because `plainText` is computed and
    /// so hands out a different `String` instance every time it is asked.
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
        let frame = verseFrame.rect
        // The insets are part of the row, not of the text: the `Text` starts that far
        // in, so both the point and the wrap width are measured from where it starts.
        let local = CGPoint(
            x: point.x - frame.minX - insets.leading, y: point.y - frame.minY)
        guard
            let index = WordHitTest.characterIndex(
                at: local, in: line.plainText, layout: hitTestLayout)
        else { return nil }
        return WordTokenizer.word(at: index, in: line.plainText)
    }

    /// The wrap width the `Text` was given: the row's own frame, less both insets.
    private var textWidth: CGFloat {
        verseFrame.rect.width - insets.leading - insets.trailing
    }

    /// The shadow layout, which has to reproduce what SwiftUI drew. A direction carries
    /// no spans, so `italicFont` is inert there — passed unconditionally rather than
    /// branched on, since a branch would only be a second thing to keep in step.
    private var hitTestLayout: WordHitTest.Layout {
        WordHitTest.Layout(
            font: line.isDirection
                ? typeface.directionPlatformFont : typeface.versePlatformFont,
            italicFont: typeface.verseItalicPlatformFont,
            italics: italics,
            alignment: hitTestAlignment,
            width: textWidth)
    }

    /// Look Up, Explain, Copy — and nothing at all where no word resolved, so the menu
    /// never names a word the reader was not pointing at.
    ///
    /// **Right-clicking deliberately does not select the line.** macOS convention says it
    /// should, but selecting here commits a generation 350 ms later, which is far too heavy
    /// a side effect for opening a menu. Only "Explain" moves the selection, and only
    /// because it has to have a passage to ask about.
    @ViewBuilder
    private var wordMenu: some View {
        if let marked {
            let term = WordTokenizer.term(for: marked, in: line.plainText)
            if !term.isEmpty {
                // Gated on the dictionary actually having an entry, so `undiscover’d` is
                // offered no panel rather than an empty one.
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
        let frame = verseFrame.rect
        guard
            let origin = WordHitTest.baselineOrigin(
                of: range.lowerBound, in: line.plainText, layout: hitTestLayout)
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

    private var numberLabel: String {
        guard let number = line.number else { return "" }
        // Every fifth line, as printed editions do: a number on every line is
        // noise, and none at all makes the citation unverifiable.
        return number % 5 == 0 || isFirstSelected ? "\(number)" : ""
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
