// Copyright © 2026 Apple Inc.

import SwiftUI

/// What the reader reads: the citation, the selected verses echoed small, the four
/// sections, the ask rows, and the transcript of anything tapped.
///
/// The ask rows and the transcript are ShakespeareReader's verbatim. What changed is the
/// middle: one flowing paragraph became four labelled sections, **each of which may be
/// absent**. See `Prompts.version` for why the house style was broken, and
/// `Annotation.parseSections` for how a malformed run still reaches the reader.
///
/// **Nothing is shown until it is whole.** `ContentView` holds the model's output and
/// publishes it in one assignment, so every section here is a finished section. The
/// wait is carried by `status` instead, and the assignment lands inside a
/// `withAnimation`, which turns each section's `if` into an animated insertion — hence
/// the `.transition(.opacity)`s below and nothing else. A cache hit is assigned outside
/// any animation and so appears instantly, which is what a cache hit should look like.
@MainActor
struct AnnotationPaneView: View {
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String
    }

    let citation: String?
    let selectedVerses: [PassageContext.Verse]
    /// The model's raw output, whole. Parsed here rather than upstream:
    /// `Annotation.parseSections` is a pure function of the text and needs nothing kept
    /// in step with it, which is why there is no `.section` event on the service.
    let commentary: String
    let followUps: [String]
    let transcript: [Exchange]
    let isBusy: Bool
    /// What the pane says while it waits, from `Phase.label`. `nil` when there is
    /// nothing running, or when the wait is a cache read that will be over before it
    /// could be read.
    let status: String?
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
    /// is a few lines down and for the same reason — it is cheap and pure, and a run cut
    /// short by cancellation or the token budget leaves a half-written string it still
    /// has to be safe on.
    let link: (String) -> AttributedString

    /// The same for **Challoner's** own text, which is a separate closure because it
    /// obeys a different rule: a reference in a 1750 note that fails to resolve is left
    /// completely alone rather than struck, since the likely fault is this app's parser
    /// and not the bishop. See `ReferenceLinks.note`.
    let linkNote: (String) -> AttributedString

    private static let contentID = "content"

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
                            // Conditional so the answer *inserts* when it lands, which
                            // is what makes the transition fire — an empty `Text`
                            // growing into a full one is a content change and animates
                            // nothing. It also keeps the question from sitting above an
                            // empty block while the answer is being written.
                            if !exchange.answer.isEmpty {
                                Text(link(exchange.answer))
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Where the text is about to appear, which is the one position that
                    // is right for both turns: under the header while the first gloss is
                    // written, and under the question just tapped while its answer is.
                    // With nothing arriving a word at a time any more, this is the only
                    // sign the app is working — see the type's own note.
                    if let status {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                // The scroll target is the whole content, which is what the reset to
                // the top scrolls to.
                .id(Self.contentID)
            }
            // The pane is an inspector *sheet* on a phone, so the keyboard the Ask
            // Anything field raises covers the answer it was typed against. Dragging
            // the text down is then the way back, and without this there is none: the
            // sheet has no other empty region to tap.
            #if !os(macOS)
                .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: transcript.count) { old, new in
                guard new > old, let asked = transcript.last else { return }
                // The question the reader just tapped goes to the top, so it stays
                // in view while its answer fills the space underneath.
                scroller.scrollTo(asked.id, anchor: .top)
            }
            .onChange(of: commentary.isEmpty) { _, isEmpty in
                // A new selection, a regenerate and Esc all clear the commentary
                // first, and fresh content should start at its beginning.
                guard isEmpty else { return }
                // Whatever cleared the commentary took the reader somewhere else, so
                // the field's claim on the keyboard is stale — a passage picked mid
                // answer would otherwise have focus yanked out of the reader pane the
                // moment its gloss finished.
                wantsDraftFocus = false
                scroller.scrollTo(Self.contentID, anchor: .top)
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

    // MARK: - Sections

    /// The four sections, and whatever the model wrote outside them.
    ///
    /// Parsed on every render from the whole text — cheap, pure, and the reason there is
    /// no extra event on the service carrying the split.
    ///
    /// **An absent section is absent.** No placeholder, no "not available", no empty
    /// heading. That is `Prompts.wordBudget`'s lesson carried up into the layout: a floor
    /// buys padding and the padding is wrong, and the same is true of a slot. A passage
    /// with no cross-references should look like a passage with three sections, not like
    /// a fourth section that failed.
    ///
    /// The `if`s and the `ForEach` that give that behaviour are also what gives the fade:
    /// they are insertions, so `.transition(.opacity)` is the whole of it.
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
                .transition(.opacity)
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
            .transition(.opacity)
        }

        if !unverifiedCitations.isEmpty, !commentary.isEmpty {
            // A named Father, council or document with a locator on it. Reported rather
            // than removed, for `QuoteCheck`'s reason: the text is evidence, and a reader
            // who can see the app flagging its own output learns more than one shown a
            // silently shortened sentence.
            //
            // Gated on the commentary too, because the checks run a beat before it is
            // revealed and "citations above" with nothing above is a warning about
            // nothing.
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
    /// Three verdicts and three renderings, and the middle one is the interesting case.
    /// A verse that exists but was not supplied means the *connection* is the model's
    /// invention even though the reference is real, so the row is set in secondary text
    /// and carries none of the app's own weight — but it still navigates, because
    /// **navigation resolves on existence everywhere in the app**. The same reference in
    /// running prose is a link a line above; making it dead here taught the reader
    /// nothing except that the pane was inconsistent. What the verdict changes is how
    /// much the row claims, not whether you can go and look.
    ///
    /// A nonexistent reference is struck through and says so, and that one does not
    /// navigate because there is nowhere to go. It is also a deliberate departure from
    /// `QuoteCheck`'s report-never-strip rule: a nonexistent scripture citation shown as
    /// if it were scripture is the app asserting a false fact about the Bible, not merely
    /// relaying a bad quotation. Nothing is deleted, so the signal survives.
    @ViewBuilder
    private var referenceRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(references) { checked in
                switch checked.verdict {
                case .ok, .ungiven:
                    Button {
                        onOpen(checked.reference)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(checked.label)
                                .font(.body.weight(.medium))
                                .foregroundStyle(
                                    checked.verdict == .ok
                                        ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(.secondary))
                            // Linked like every other run of the model's prose: the
                            // "why it connects" is a sentence that can name a third
                            // verse, and this row used to be the one place in the app
                            // where such a name was neither a link nor struck.
                            Text(link(checked.note))
                                .font(.body)
                                .foregroundStyle(
                                    checked.verdict == .ok
                                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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

    @ViewBuilder
    private func header(_ citation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(citation)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

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
        draft = ""
        // The keyboard stays here, so one question can be followed by the next. The
        // cost is that the reader pane's arrows, Esc, ⌘C and ⌘R are dead until focus
        // leaves; clicking a line takes it back through `ChapterReaderView.select(_:)`.
        wantsDraftFocus = true
        onAsk(question)
    }
}
