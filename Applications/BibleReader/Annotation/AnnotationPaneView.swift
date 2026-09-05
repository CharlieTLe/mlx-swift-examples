// Copyright © 2026 Apple Inc.

import SwiftUI

/// What the reader reads: the citation, the selected verses echoed small, the four
/// streamed sections, the ask rows, and the transcript of anything tapped.
///
/// The scroll-following machinery, the ask rows and the transcript are ShakespeareReader's
/// verbatim. What changed is the middle: one flowing paragraph became four labelled
/// sections, **each of which may be absent**. See `Prompts.version` for why the house
/// style was broken, and `Annotation.parseSections` for how a malformed run still
/// reaches the reader.
@MainActor
struct AnnotationPaneView: View {
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String
    }

    let citation: String?
    let selectedVerses: [PassageContext.Verse]
    /// The model's raw output. Parsed here rather than upstream, which is what makes the
    /// sections stream: `Annotation.parseSections` is a pure function of the accumulated
    /// text and is safe on a partial string, so a half-written section renders as a
    /// half-written section and the four appear one at a time as the model reaches them.
    /// Nothing has to be kept in step with anything.
    let commentary: String
    let followUps: [String]
    let transcript: [Exchange]
    let isBusy: Bool
    /// Cross-references the model named, with their verdicts. Phase 4.
    let references: [CheckedReference]
    /// Specific patristic or magisterial citations the model produced. Phase 4.
    let unverifiedCitations: [String]
    let onAsk: (String) -> Void
    /// Following a validated cross-reference into the text. Phase 4.
    let onOpen: (ScriptureReference) -> Void

    /// A run of the model's prose, with every reference in it linked or struck through.
    ///
    /// A closure and not the corpus, which is the shape this pane already has: it takes
    /// precomputed `[CheckedReference]` and callbacks and knows nothing about what is in
    /// this Bible. Run on every render, exactly as `Annotation.parseSections(commentary)`
    /// is a few lines down and for the same reason — it is cheap, pure, and safe on the
    /// half-written string a streamed token leaves behind.
    let link: (String) -> AttributedString

    /// The same for **Challoner's** own text, which is a separate closure because it
    /// obeys a different rule: a reference in a 1750 note that fails to resolve is left
    /// completely alone rather than struck, since the likely fault is this app's parser
    /// and not the bishop. See `ReferenceLinks.note`.
    let linkNote: (String) -> AttributedString

    private static let space = "annotation"
    private static let contentID = "content"

    /// Within two lines of body text of the end still counts as "at the end", so a
    /// reader who flicks down without landing exactly at the bottom gets following
    /// back.
    private static let pinSlack: CGFloat = 40

    /// Layout rounding moves the content top by a fraction of a point; only a real
    /// scroll moves it further than this.
    private static let scrollSlack: CGFloat = 4

    @State private var isFollowing = true
    @State private var contentFrame: CGRect = .zero
    @State private var viewportHeight: CGFloat = 0
    @State private var lastTop: CGFloat = 0
    @State private var lastHeight: CGFloat = 0

    /// Following the stream is opt-in. The first gloss of a selection is meant to be
    /// read from the top, so the pane stays put and only chases the end of the
    /// content once the reader has tapped an ask row.
    @State private var isArmed = false

    /// Set while one of the pane's own jumps is in flight. Those move the content
    /// top exactly the way a reader scrolling up does, so without this they would
    /// turn following off the instant they land.
    @State private var isJumping = false

    /// The Ask Anything field's contents, and whether it holds the keyboard.
    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool

    /// Set from sending a typed question until the keyboard has been handed back to
    /// the field. A reader who types one question usually has a second, so focus
    /// stays in the field across the exchange — but the field is `.disabled` while
    /// the answer runs and a disabled field cannot be first responder, so keeping the
    /// keyboard means asking for it again when the answer lands rather than merely
    /// declining to give it up.
    @State private var wantsDraftFocus = false

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let citation {
                        header(citation)
                    } else {
                        placeholder
                    }

                    sections

                    ForEach(transcript) { exchange in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exchange.question)
                                .font(.callout.weight(.semibold))
                            Text(link(exchange.answer))
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Last, always: the ask block follows whatever was most recently
                    // written. Keeping it in a fixed slot above the transcript put the
                    // next set of questions back where the reader tapped, above the
                    // answer they had just asked for.
                    //
                    // Gated on there being a passage and **not** on there being
                    // suggestions. The two used to travel together, and the field went
                    // with them: the suggestions are model output that legitimately runs
                    // out — `AnnotationService` discards a refresh that yields fewer than
                    // two questions the reader has not already been offered, which by the
                    // third exchange is the common case — and losing them took away the
                    // only way to type a question of your own, with nothing but
                    // re-selecting the passage to get it back.
                    if citation != nil {
                        askRows
                    }
                }
                .padding(14)
                // The scroll target is the whole content with a `.bottom` anchor,
                // which puts the end of the ask rows at the end of the viewport
                // rather than needing a sentinel row and the stack spacing that
                // would come with it.
                .id(Self.contentID)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ContentFrameKey.self,
                            value: geometry.frame(in: .named(Self.space)))
                    }
                )
            }
            .coordinateSpace(name: Self.space)
            // The pane is an inspector *sheet* on a phone, so the keyboard the Ask
            // Anything field raises covers the answer it was typed against. Dragging
            // the text down is then the way back, and without this there is none: the
            // sheet has no other empty region to tap.
            #if !os(macOS)
                .scrollDismissesKeyboard(.interactively)
            #endif
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ViewportHeightKey.self, value: geometry.size.height)
                }
            )
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
            .onPreferenceChange(ContentFrameKey.self) { track($0) }
            .onChange(of: streamTick) { follow(scroller) }
            .onChange(of: transcript.count) { old, new in
                guard new > old, let asked = transcript.last else { return }
                // The question the reader just tapped goes to the top, so it stays
                // in view while its answer fills the space underneath.
                jump { scroller.scrollTo(asked.id, anchor: .top) }
            }
            .onChange(of: commentary.isEmpty) { _, isEmpty in
                // A new selection, a regenerate and Esc all clear the commentary
                // first, and fresh content should start at its beginning.
                guard isEmpty else { return }
                isArmed = false
                // Whatever cleared the commentary took the reader somewhere else, so
                // the field's claim on the keyboard is stale — a passage picked mid
                // answer would otherwise have focus yanked out of the reader pane the
                // moment its gloss finished.
                wantsDraftFocus = false
                jump { scroller.scrollTo(Self.contentID, anchor: .top) }
            }
            .onChange(of: isBusy) { _, busy in
                // The answer is done and the field is live again: give it the keyboard
                // back, so the next question can be typed without clicking into it first.
                //
                // Unconditional now that the field outlives the suggestions. It used to
                // be `isDraftFocused = !followUps.isEmpty`, because a refresh turn that
                // produced no new questions took the field away with them and there was
                // nothing to focus — which is exactly the case where a reader most wants
                // to type one of their own.
                guard !busy, wantsDraftFocus else { return }
                wantsDraftFocus = false
                isDraftFocused = true
            }
        }
    }

    /// One value for "something grew", so following needs a single `onChange` rather
    /// than one per streamed field. The ask rows count too: they arrive in one piece
    /// once the gloss is done, and they are what the reader wants to see next.
    private var streamTick: Int {
        commentary.count + followUps.count + transcript.reduce(0) { $0 + $1.answer.count }
    }

    // MARK: - Sections

    /// The four sections, and whatever the model wrote outside them.
    ///
    /// Parsed on every render from the accumulated text — cheap, pure, and the reason
    /// the sections stream one at a time with no extra event on the service.
    ///
    /// **An absent section is absent.** No placeholder, no "not available", no empty
    /// heading. That is `Prompts.wordBudget`'s lesson carried up into the layout: a floor
    /// buys padding and the padding is wrong, and the same is true of a slot. A passage
    /// with no cross-references should look like a passage with three sections, not like
    /// a fourth section that failed.
    @ViewBuilder
    private var sections: some View {
        let annotation = Annotation.parseSections(commentary)

        if let preamble = annotation.preamble {
            // The model ignored the format, or has not reached the first label yet.
            // Shown as ordinary prose rather than discarded: an unparseable annotation
            // the reader can still read beats a blank pane, and it is also the evidence
            // that says the format is slipping.
            Text(link(preamble))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(annotation.present, id: \.self) { section in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(section.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)

                    if section == .tradition {
                        // **Labelled, and not quietly.** `THE TRADITION` is the weakest
                        // of the four layers by a distance: it is the one the model is
                        // the *source* of rather than a reader of, because there is no
                        // curated dataset behind it the way Challoner's notes stand
                        // behind the other three. A 4B model also drifts toward the
                        // Protestant commonplace on exactly the contested verses where
                        // this section matters most. Shipping it unmarked would be the
                        // app asserting something it cannot check.
                        Text("generated, unverified")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                if section == .seeAlso, !references.isEmpty {
                    referenceRows
                } else if let body = annotation[section] {
                    Text(link(body))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !unverifiedCitations.isEmpty {
            // A named Father, council or document with a locator on it. Reported rather
            // than removed, for `QuoteCheck`'s reason: the text is evidence, and a reader
            // who can see the app flagging its own output learns more than one shown a
            // silently shortened sentence.
            Label(
                unverifiedCitations.count == 1
                    ? "One citation above is unverified: \(unverifiedCitations[0])"
                    : "Unverified citations above: "
                        + unverifiedCitations.joined(separator: ", "),
                systemImage: "questionmark.circle"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The `SEE ALSO` section, rendered from the checked references rather than from the
    /// model's own lines.
    ///
    /// Three verdicts, three renderings, and the middle one is the interesting case: a
    /// verse that exists but was not supplied means the *connection* is the model's
    /// invention even though the reference is real, so it is shown as plain text and does
    /// not navigate. A nonexistent reference is struck through and says so — which is a
    /// deliberate departure from `QuoteCheck`'s report-never-strip rule, because a
    /// nonexistent scripture citation shown as if it were scripture is the app asserting
    /// a false fact about the Bible, not merely relaying a bad quotation. Nothing is
    /// deleted, so the signal survives.
    @ViewBuilder
    private var referenceRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(references) { checked in
                switch checked.verdict {
                case .ok:
                    Button {
                        onOpen(checked.reference)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(checked.label)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            Text(checked.note)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                case .ungiven:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(checked.label).font(.body.weight(.medium))
                        Text(checked.note).font(.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)

                case .nonexistent:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(checked.label)
                            .font(.body.weight(.medium))
                            .strikethrough()
                        Text("not in this Bible")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How far the end of the content sits past the end of the viewport.
    private var distanceBelowFold: CGFloat {
        contentFrame.maxY - viewportHeight
    }

    /// Re-arms following and scrolls somewhere other than the end.
    private func jump(_ scroll: () -> Void) {
        isFollowing = true
        isJumping = true
        scroll()
    }

    private func follow(_ scroller: ScrollViewProxy) {
        // `isBusy` is what separates a live stream from a cache hit, which lands the
        // whole gloss in one assignment and should be read from the top.
        guard isArmed, isBusy, isFollowing, distanceBelowFold > 0 else { return }
        // Unanimated, deliberately: this runs once per decoded token, and an
        // animated scroll per token queues 60 overlapping animations a second.
        scroller.scrollTo(Self.contentID, anchor: .bottom)
    }

    /// Content grows downward, so the top edge only moves when someone actually
    /// scrolls. That is what separates the reader scrolling up to re-read from
    /// another token arriving underneath them.
    ///
    /// Two things move the top with no reader involved: one of the pane's own jumps,
    /// and the content getting shorter, which makes the scroll view clamp its
    /// offset. Both are excluded, or following would keep switching itself off.
    private func track(_ frame: CGRect) {
        contentFrame = frame
        defer {
            lastTop = frame.minY
            lastHeight = frame.height
        }

        // Reports arrive a layout pass behind, so a jump is still in flight until
        // something actually changes; that report is the jump landing, and it is the
        // one whose moved top has to be forgiven.
        let landing = isJumping
        if frame.minY != lastTop || frame.height != lastHeight {
            isJumping = false
        }

        if !landing, frame.height >= lastHeight,
            frame.minY > lastTop + Self.scrollSlack
        {
            isFollowing = false
        } else if frame.maxY - viewportHeight <= Self.pinSlack {
            isFollowing = true
        }
    }

    @ViewBuilder
    private func header(_ citation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(citation)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                // The only sign that work is in flight when the status strip is
                // hidden, and a cold reasoning phase can run for seconds. Unlabelled, and gone the moment text starts arriving, so it
                // never competes with the stream.
                if isBusy, commentary.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }

            // The selected lines are echoed so the reader does not lose the anchor
            // while reading the gloss.
            //
            // `.textSelection(.enabled)` here, as on the citation above and the commentary
            // and transcript below: this is the one place in the app where a word can be
            // swept out with the pointer and looked up through the system's own menu,
            // because it is the one place where no selection gesture is competing for the
            // drag. In the text itself a drag sweeps a passage, and hovering a word is what
            // stands in for highlighting it.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(selectedVerses.enumerated()), id: \.offset) { _, verse in
                    Text(echo(verse))
                        .font(verse.kind == .verse ? .caption : .caption2.italic())
                        .foregroundStyle(
                            verse.kind == .verse
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(.quaternary).frame(width: 2)
            }
        }
    }

    /// A selected row as the echo prints it. The verse number goes back in here, as it
    /// does in the prompt render, because the echo has no gutter to keep it out of.
    ///
    /// A note's own references are linked, the way they are in the reader pane; nothing
    /// else in the echo is, because scripture does not cite scripture and a heading is
    /// three words. The `[note]` marker is prefixed *after* linking so its brackets can
    /// never land inside a span.
    private func echo(_ verse: PassageContext.Verse) -> AttributedString {
        switch verse.kind {
        case .verse:
            guard let number = verse.number else { return AttributedString(verse.text) }
            return AttributedString("\(number). \(verse.text)")
        case .sectionHeading:
            return AttributedString(verse.text)
        case .note:
            return AttributedString("[note] ") + linkNote(verse.text)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select verses to annotate")
                .font(.headline)
            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Named after the gestures each platform actually has. Esc, ⌘R and shift-click
    /// are macOS instructions, and telling a phone reader about them would be telling
    /// them about keys they do not have; press-and-hold is the touch equivalent of
    /// shift-click, and dismissing this sheet is the equivalent of Esc.
    private var instructions: String {
        #if os(macOS)
            "Click a verse, shift-click to extend, double-click for the whole "
                + "sentence, or drag. ⌘A takes the chapter. Esc clears. ⌘R regenerates."
        #else
            "Tap a verse, double-tap for the whole sentence, or press and hold to "
                + "select a passage."
        #endif
    }

    /// The suggestions and the Ask Anything field.
    ///
    /// Full-width vertical rows with a chevron and dividers, which is what the reference
    /// UI actually is — and it avoids needing a flow layout.
    ///
    /// **The field outlives the suggestions.** They are model output and run out; it is
    /// the reader's own way in and is always here once there is a passage to ask about.
    /// Only the caption, the rows and the rule that closes them off come and go.
    @ViewBuilder
    private var askRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !followUps.isEmpty {
                Text("People also ask")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                ForEach(Array(followUps.enumerated()), id: \.offset) { index, question in
                    Button {
                        // Tapping is the reader asking to be carried along with the
                        // answer; until then the pane leaves the scroll position alone.
                        isArmed = true
                        onAsk(question)
                    } label: {
                        HStack(spacing: 8) {
                            Text(question)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    if index < followUps.count - 1 {
                        Divider()
                    }
                }

                // Closes the list off, so the field reads as its own thing rather than as
                // another suggestion. Inside the `if` with the list it closes: a rule
                // above a field with nothing above *it* is a line across the pane.
                Divider()
            }

            HStack(spacing: 8) {
                TextField("Ask Anything", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isDraftFocused)
                    .onSubmit { submitDraft() }
                    // Return sends rather than inserting a newline, which the software
                    // keyboard has to be told: without it the key reads "return" and a
                    // reader has no reason to expect it to submit.
                    #if !os(macOS)
                        .submitLabel(.send)
                    #endif
                    // Esc belongs to the field while it holds the keyboard: it
                    // abandons the draft. It does not reach
                    // `ChapterReaderView.onExitCommand`, which would clear the selection
                    // and wipe the pane the draft was written against — the pane is
                    // that view's sibling, not its descendant, and commands only
                    // travel to ancestors.
                    #if os(macOS)
                        .onExitCommand {
                            draft = ""
                            isDraftFocused = false
                        }
                    #endif

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submitDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
            .padding(.top, 8)
            .disabled(isBusy)
        }
    }

    private func submitDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        // Same as tapping a row: asking is the reader opting into being carried along
        // with the answer.
        isArmed = true
        draft = ""
        // The keyboard stays here, so one question can be followed by the next. The
        // cost is that the reader pane's arrows, Esc, ⌘C and ⌘R are dead until focus
        // leaves; clicking a line takes it back through `ChapterReaderView.select(_:)`.
        wantsDraftFocus = true
        onAsk(question)
    }
}

/// The pane's content frame and its viewport height, in the pane's own coordinate
/// space. Following the stream needs to know how far the end of the content is
/// from the end of the viewport, and on macOS 14 a `PreferenceKey` is how you
/// learn that: `onScrollGeometryChange` and `ScrollPosition` are 15+.
private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    /// Only one view reports a real frame, but sibling subviews — the scroll
    /// view's own background layer among them — all contribute the default, and
    /// they are not visited in any guaranteed order. So keep whichever value is
    /// not the default rather than the one that happens to come last, the same
    /// reason `ViewportHeightKey` reduces with `max`.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
