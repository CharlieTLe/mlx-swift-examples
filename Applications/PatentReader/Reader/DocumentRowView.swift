// Copyright © 2026 Apple Inc.

import CoreText
import SwiftUI

/// One row of the document: the number margin, and the text.
///
/// `LineRow` from ShakespeareReader, and its central contract is carried over unchanged
/// and matters more here. Selected styling is deliberately **size-neutral** — a
/// background fill, a left accent rule, and a colour change, with no weight or size
/// change. Row height feeds `RowFramesKey`, which is written into `@State`, which is read
/// back during layout; anything that makes height depend on selection closes that loop.
/// The hovered word's mark is bound by the same contract, and that is why it is an
/// underline: an underline is drawn inside the line box, where a heavier weight or a
/// larger size would reflow the row the pointer is sitting on.
///
/// **The flash highlight is bound by it too**, and it is the new thing tempted to break
/// it. A citation jump animates this row's background from accent to clear over about a
/// second, and it does so as an *overlay with an opacity animation and no geometry* —
/// never a border that insets, never a scale, never a padding change. An animating height
/// would close the layout loop sixty times a second rather than once.
///
/// Changing the typeface resizes every row and is *not* that loop: `rowFrames` is written
/// from a preference and read **only** inside the drag gesture in
/// `DocumentReaderView.row(_:)`, never in `body`, so a font change is a one-shot relayout
/// that settles.
///
/// **The row has two selections in it, and the margin is the boundary between them.** The
/// prose is system-selectable text, so a drag or a long press on it selects *characters*. The
/// number margin is not prose — a paragraph number can never be part of a quotation — so a
/// press there means "this row", and that is what `DocumentReaderView` arms a passage sweep
/// from. Getting this wrong is not subtle: with the sweep armed from anywhere, one long press
/// on a phone produced grab handles and a five-row selection band at the same time.
@MainActor
struct DocumentRowView: View {
    /// The row's own horizontal inset, shared because `DocumentReaderView` has to know where
    /// the number margin ends in order to tell a passage sweep from a text selection.
    static let rowPadding: CGFloat = 6

    let row: DocumentRow
    let patent: Patent

    /// The styled spans of this row, from `PatentMarkup`. Computed once per document by
    /// `DocumentSpansBox` rather than per row, because `body` re-evaluates on every
    /// selection change and at frame rate through a drag.
    let spans: [PatentMarkup.Span]

    let isSelected: Bool

    /// The find hits in this row, and which of them the reader is on.
    ///
    /// Bound by the same size-neutrality contract as everything else here, and it keeps to
    /// it the same way the flash does — by changing nothing that has a size. A hit is drawn
    /// as an attributed run's `backgroundColor`, which fills the run's existing box; a
    /// heavier weight or a box drawn behind the text with padding would make row height
    /// depend on the query and close the layout loop on every keystroke.
    let highlights: DocumentFind.Highlights

    /// Whether the reader pane holds the keyboard. Focus stays in the library when a
    /// patent is picked there, so the band goes grey to say the arrows are pointed
    /// somewhere else, the way an unfocused `NSTableView` does. Colour **only**: this is
    /// read during layout just as `isSelected` is, so it is bound by the same
    /// size-neutrality contract.
    let hasFocus: Bool

    /// Non-nil while this row is flashing after a citation jump, and changing identity
    /// re-fires the animation — which is what makes a second jump to the same row do
    /// something visible.
    let flash: UUID?

    /// A word of this row, and where its dictionary panel should be popped: the word's
    /// baseline origin in `DictionaryAnchor.space`.
    let onLookUpWord: (String, CGPoint) -> Void

    /// A claim cross-reference the reader clicked on the claim's parent badge.
    ///
    /// Only the badge needs a closure. The cross-references and reference numerals
    /// *inside* the text are links, handled by `ContentView`'s `OpenURLAction`, because
    /// `Text` will not host a `Button`. A badge sits outside the `Text`, so it can be a
    /// real button and gets a proper hit target and accessibility label for it.
    let onOpen: (CitationTarget) -> Void

    @Environment(\.readerTypeface) private var typeface

    /// The word under the pointer, as a range of the row's text.
    ///
    /// Local to the row and **not** on `DocumentReaderView`, which is the difference
    /// between invalidating one row's body as the pointer crosses a word boundary and
    /// invalidating every visible row's.
    @State private var marked: Range<String.Index>?

    /// The text `Text`'s own frame, in `DictionaryAnchor.space`.
    ///
    /// A reference box and deliberately **not** `@State`: it is written from geometry and
    /// read only inside the hover handler, never in `body`, so measuring the row can
    /// never invalidate the row it measured.
    @State private var textFrame = FrameBox()

    /// Fades from 1 to 0 while the flash runs.
    @State private var flashOpacity: Double = 0

    /// How long the landing highlight takes to fade.
    ///
    /// Long enough to be seen after a scroll animation has settled, short enough not to
    /// still be going when the reader starts reading. A jump that lands with no visible
    /// change reads as a jump that did not happen, which is the whole failure this
    /// prevents.
    private static let flashDuration: TimeInterval = 1.2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marginLabel)
                // The *face* stays the system's whatever the patent is set in, because a
                // serif family has no tabular figures and a column of `[0009]` over
                // `[0010]` would not line up. The *size* does follow the reader's step,
                // so the numbers stay legible beside the text. Font and width come from
                // the typeface together and never one without the other — the width is a
                // budget for `[0042]`'s advances, so a bigger font in a fixed frame is
                // the clipping case.
                .font(typeface.gutterFont)
                .foregroundStyle(marginStyle)
                .frame(width: typeface.gutterWidth, alignment: .trailing)
                .accessibilityHidden(marginLabel.isEmpty)

            content
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Self.rowPadding)
        .padding(.top, topGap)
        .background(alignment: .leading) {
            if isSelected {
                ZStack(alignment: .leading) {
                    Rectangle().fill(bandFill)
                    Rectangle().fill(bandRule).frame(width: 2)
                }
            }
        }
        // The landing flash. An overlay rather than a background so it reads over the
        // selection band the jump also sets, and `allowsHitTesting(false)` because it
        // covers the row it is announcing.
        .overlay {
            Rectangle()
                .fill(Color.accentColor)
                .opacity(flashOpacity * 0.28)
                .allowsHitTesting(false)
        }
        .onChange(of: flash) { _, value in
            guard value != nil else { return }
            // Set without animation, then animate to zero: a symmetric fade in and out
            // would take twice as long to say the same thing, and the arrival is the part
            // that has to be instant.
            flashOpacity = 1
            withAnimation(.easeOut(duration: Self.flashDuration)) { flashOpacity = 0 }
        }
        .contentShape(Rectangle())
    }

    /// The space above this row.
    ///
    /// A heading gets more, which is most of what makes the section structure visible;
    /// the first row of the document gets none, so the column does not open with a hole.
    private var topGap: CGFloat {
        guard row.index > 0 else { return 0 }
        return row.isHeading ? typeface.headingGap : typeface.blockGap
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .heading(let text), .claimsHeading(let text):
            // `MarkedText` rather than a bare `Text` only so a find hit in a heading is
            // visible. It short-circuits to `Text(text)` with nothing to say about a run, so
            // an ordinary heading takes the identical path it did before.
            MarkedText(
                text: text, spans: [], marked: nil, highlights: highlights,
                typeface: typeface
            )
            .font(typeface.sectionHeading)
            .tracking(typeface.sectionTracking)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph:
            paragraphText
        case .claim(let claim):
            ClaimRowView(
                claim: claim, patent: patent, spans: spans, highlights: highlights,
                depth: row.claimDepth, onOpen: onOpen)
        }
    }

    /// A specification paragraph, with its spans set and the hovered word underlined.
    @ViewBuilder
    private var paragraphText: some View {
        MarkedText(
            text: row.plainText, spans: spans, marked: marked, highlights: highlights,
            typeface: typeface
        )
        .selectableProse()
        .font(typeface.body)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        textFrame.rect = geometry.frame(
                            in: .named(DictionaryAnchor.space))
                    }
                    .onChange(of: geometry.frame(in: .named(DictionaryAnchor.space))) {
                        _, frame in
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

    // MARK: - The margin

    /// What the margin prints beside this row.
    ///
    /// **Every paragraph number, not every fifth.** A play numbers lines so a citation
    /// can be checked, and a number on every line is noise; a patent's paragraph number
    /// *is* the citation target, and every one of them is a thing the answer pane may
    /// point at. Printing only some would mean a chip that lands on a paragraph with no
    /// number beside it to confirm the landing.
    ///
    /// A synthesized number prints bare and lighter — `42`, not `[0042]` — because the
    /// brackets are the patent office's own convention and this app has no right to
    /// them. That is the same honesty `Citation.string` states in words, in the one
    /// place a reader looks a hundred times an hour.
    private var marginLabel: String {
        switch row.kind {
        case .heading, .claimsHeading: ""
        case .paragraph(let paragraph):
            patent.numbering == .printed
                ? "[\(String(format: "%04d", paragraph.number))]" : "\(paragraph.number)"
        case .claim(let claim): "\(claim.number)."
        }
    }

    private var marginStyle: AnyShapeStyle {
        switch row.kind {
        // A claim number is a heading in the margin rather than a reference: it is how a
        // reader finds claim 12 by scanning, so it is one step less faint.
        case .claim: AnyShapeStyle(.secondary)
        default:
            patent.numbering == .printed
                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)
        }
    }

    // MARK: - Word lookup

    /// The word under a point, or `nil` — a space, punctuation, or the blank right of a
    /// short line. `nil` marks nothing and offers nothing, which is what makes a
    /// hit-testing near-miss something the reader can see before committing to it.
    private func resolvedWord(at point: CGPoint) -> Range<String.Index>? {
        let frame = textFrame.rect
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard
            let index = WordHitTest.characterIndex(
                at: local, in: row.plainText, layout: hitTestLayout)
        else { return nil }
        return WordTokenizer.word(at: index, in: row.plainText)
    }

    /// The shadow layout, which has to reproduce what SwiftUI drew.
    private var hitTestLayout: WordHitTest.Layout {
        WordHitTest.Layout(
            font: typeface.bodyPlatformFont,
            italicFont: typeface.bodyItalicPlatformFont,
            italics: [],
            alignment: .natural,
            width: textFrame.rect.width)
    }

    /// Look Up, Explain, Copy — and nothing at all where no word resolved, so the menu
    /// never names a word the reader was not pointing at.
    ///
    /// **Right-clicking deliberately does not select the row.** macOS convention says it
    /// should, but selection here is what scopes a question, and quietly rescoping the
    /// reader's next question because they opened a menu is a side effect they did not
    /// ask for.
    @ViewBuilder
    private var wordMenu: some View {
        if let marked {
            let term = WordTokenizer.term(for: marked, in: row.plainText)
            if !term.isEmpty {
                // Gated on the dictionary actually having an entry, so a coined claim
                // term is offered no panel rather than an empty one.
                if DictionaryAnchor.hasDefinition(for: term) {
                    Button("Look Up “\(term)”") { lookUp(term, from: marked) }
                }
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
                of: range.lowerBound, in: row.plainText, layout: hitTestLayout)
        else { return }
        onLookUpWord(term, CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY))
    }

    /// `AnyShapeStyle` because the two branches are different style types, which is the
    /// house idiom.
    private var bandFill: AnyShapeStyle {
        hasFocus
            ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary)
    }

    private var bandRule: AnyShapeStyle {
        hasFocus ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
    }
}

/// Text with its markup spans set, the find hits lit, and the hovered word underlined.
///
/// Split out of the row because a claim needs it too, at three indent levels.
///
/// **The text is system-selectable**, so a reader can drag out a phrase and copy exactly
/// that. That was not always true, and what changed is worth recording: the row-based
/// `PassageSelection` exists because SwiftUI will not tell the app which characters are
/// selected, and for a while the conclusion drawn from that was that character selection
/// should be off entirely so the two could not be confused. That was the wrong conclusion.
/// A reader quoting a patent into an email wants the clause, not the paragraph, and the app
/// not being *told* about a selection is no reason to deny the reader one — it only means
/// the app cannot build a citation from it, which is what ⇧⌘C and the passage selection are
/// still for.
///
/// An `AttributedString` is built **only** when there is something to say about a run: with
/// no spans, nothing hovered and nothing found this is `Text(text)` on the identical code
/// path a plain paragraph would take. Same move `ReaderTextSize` makes by short-circuiting
/// to the bare text style at `.default` — the common case stays what it is rather than
/// becoming something equivalent to it.
/// **Selectability is the caller's to grant, and `Text` is not selectable by default**, which
/// is why this applies no `.textSelection` of its own. The prose says `.enabled`; a *heading*
/// deliberately does not, and that is not fussiness. A heading's job in this app is to be a
/// handle — double-clicking one takes the heading and every row under it, which is how a
/// reader scopes a question to the Background — and a selectable heading loses that, because
/// the text view swallows the double click to select a word. Headings are also the one thing
/// here that cannot be quoted: `DocumentRow.target(in:)` gives them no citation.
@MainActor
struct MarkedText: View {
    let text: String
    let spans: [PatentMarkup.Span]
    let marked: Range<String.Index>?
    let highlights: DocumentFind.Highlights
    let typeface: ReaderTypeface

    /// Every hit in the row, and the one the reader is on.
    ///
    /// **Deliberately not the accent colour**, which is the obvious choice and the wrong
    /// one: the selection band, the landing flash, the reference numerals and the claim
    /// cross-references are all accent-tinted already, so an accent-tinted find hit would be
    /// the fifth thing wearing the same colour and the first one a reader has to tell apart
    /// from the other four. Yellow is what every find field in every app has meant since
    /// before this one existed, and spending the convention here costs nothing.
    ///
    /// Two weights rather than one, because the count in the bar is only half the answer:
    /// `3 of 47` says how many there are, and the darker fill says which of them you are
    /// looking at. The text keeps its own colour under both — a foreground change would make
    /// a hit inside a reference numeral lose the tint that says it is a numeral.
    private static let hit = Color.yellow.opacity(0.30)
    private static let currentHit = Color.orange.opacity(0.55)

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        guard marked != nil || !spans.isEmpty || !highlights.isEmpty else {
            return AttributedString(text)
        }

        var string = AttributedString(text)
        for span in spans {
            guard let range = attributedRange(span.range, in: string) else { continue }
            switch span {
            case .referenceNumeral(_, let numeral, let label):
                // Tabular figures and the accent tint. The numeral is the one thing in a
                // patent's prose that is not prose — it is a pointer into a drawing — and
                // this is what makes a paragraph full of them scannable rather than
                // speckled.
                string[range].font = typeface.referenceNumeral
                string[range].foregroundColor = .accentColor
                // The term the source says this numeral labels, which is the whole reason
                // `calloutNumerals` is carried on the patent: a reader who has forgotten
                // what 214 is gets told without leaving the paragraph.
                string[range].link = ReaderLink.numeral(numeral).url
                string.setToolTip(label, on: range)
            case .figureReference:
                string[range].foregroundColor = .accentColor
            case .claimReference(_, let claim):
                string[range].foregroundColor = .accentColor
                string[range].underlineStyle = Text.LineStyle.single
                string[range].link = ReaderLink.claim(claim).url
            }
        }

        // After the spans, so a hit inside a reference numeral is drawn behind the numeral
        // rather than instead of it — the two are a background and a foreground and both
        // facts survive.
        for hit in highlights.ranges {
            guard let range = attributedRange(hit, in: string) else { continue }
            string[range].backgroundColor =
                hit == highlights.current ? Self.currentHit : Self.hit
        }

        if let marked,
            let lower = AttributedString.Index(marked.lowerBound, within: string),
            let upper = AttributedString.Index(marked.upperBound, within: string)
        {
            // An underline rather than a background fill, so the mark does not compete with
            // the selection band, which is already a fill.
            string[lower ..< upper].underlineStyle = Text.LineStyle.single
        }
        return string
    }

    /// A UTF-16 span, in the coordinates an `AttributedString` is subscripted by.
    ///
    /// UTF-16 offsets are what crosses the gap, because the row's text is computed and so
    /// hands out a different `String` instance every time it is asked.
    private func attributedRange(
        _ span: Range<Int>, in string: AttributedString
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
}

/// A link inside the document text, as a URL SwiftUI can carry on an attributed run.
///
/// The same mechanism the answer pane's citation chips use, and deliberately the same:
/// `Text` will not host a `Button`, so a tappable run inside flowing prose has to be a
/// link, and one scheme handled in one place beats two conventions. See
/// `ContentView`'s `OpenURLAction`.
enum ReaderLink {
    case numeral(Int)
    case claim(Int)

    static let scheme = "patentreader"

    var url: URL? {
        switch self {
        case .numeral(let value): URL(string: "\(Self.scheme)://numeral/\(value)")
        case .claim(let value): URL(string: "\(Self.scheme)://claim/\(value)")
        }
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
