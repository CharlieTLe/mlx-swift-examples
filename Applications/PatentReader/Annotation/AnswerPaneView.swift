// Copyright © 2026 Apple Inc.

import SwiftUI

/// What the reader reads: the question, the cited answer, the questions to ask next, and
/// a field for one of their own.
///
/// `AnnotationPaneView`, with its scroll state machine — `isFollowing`, `isJumping`,
/// `track(_:)`, the `pinSlack`/`scrollSlack` pair — ported essentially verbatim, because
/// that machinery solves a problem that has nothing to do with the subject: telling "the
/// content moved because the reader scrolled" from "the content moved because a token
/// arrived underneath them".
///
/// What is new is the answer itself. `AnnotationPaneView` renders `Text(commentary)`,
/// one flat string. Here every citation in that string is a chip the reader can click to
/// land on the passage, which is the whole product — see `answerText`.
@MainActor
struct AnswerPaneView: View {
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        /// Parsed as it streams, so a citation is a chip the moment it is whole.
        var runs: [AnswerRun]
        var tail: String
    }

    let question: String?
    let runs: [AnswerRun]
    /// The unresolved suffix of the stream — see `CitationScanner`. Rendered as plain
    /// text so a half-emitted `[00` reads as characters rather than as a chip that then
    /// changes into a different one.
    let tail: String
    let followUps: [String]
    let transcript: [Exchange]
    let isBusy: Bool
    let isLexicalOnly: Bool
    let retrievedCount: Int
    let numbering: Numbering
    /// Bumped by ⌘L to put the keyboard in the Ask field.
    ///
    /// A counter rather than a `Bool`, so a second ⌘L while the field already has focus
    /// still registers as a change — a flag would already be `true` and `onChange` would
    /// not fire. The same reason `FlashHighlight` carries a `UUID`.
    let focusRequest: Int
    /// A question to ask. `isSuggestion` distinguishes a tapped row from a typed one,
    /// which is what decides whether it is answered from the same passages or searches
    /// again — see `ContentView.ask(_:isSuggestion:)`.
    let onAsk: (String, Bool) -> Void

    private static let space = "answer"
    private static let contentID = "content"

    /// Within two lines of body text of the end still counts as "at the end", so a reader
    /// who flicks down without landing exactly at the bottom gets following back.
    private static let pinSlack: CGFloat = 40

    /// Layout rounding moves the content top by a fraction of a point; only a real scroll
    /// moves it further than this.
    private static let scrollSlack: CGFloat = 4

    @State private var isFollowing = true
    @State private var contentFrame: CGRect = .zero
    @State private var viewportHeight: CGFloat = 0
    @State private var lastTop: CGFloat = 0
    @State private var lastHeight: CGFloat = 0

    /// Following the stream is opt-in. The first answer is meant to be read from the top,
    /// so the pane stays put and only chases the end of the content once the reader has
    /// tapped an ask row.
    @State private var isArmed = false

    /// Set while one of the pane's own jumps is in flight. Those move the content top
    /// exactly the way a reader scrolling up does, so without this they would turn
    /// following off the instant they land.
    @State private var isJumping = false

    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool

    /// Set from sending a typed question until the keyboard has been handed back to the
    /// field. A reader who types one question usually has a second, so focus stays in the
    /// field across the exchange — but the field is `.disabled` while the answer runs and
    /// a disabled field cannot be first responder, so keeping the keyboard means asking
    /// for it again when the answer lands rather than merely declining to give it up.
    @State private var wantsDraftFocus = false

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let question {
                        header(question)
                    } else {
                        placeholder
                    }

                    if !runs.isEmpty || !tail.isEmpty {
                        answerText(runs: runs, tail: tail)
                    }

                    ForEach(transcript) { exchange in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exchange.question)
                                .font(.callout.weight(.semibold))
                            answerText(runs: exchange.runs, tail: exchange.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(exchange.id)
                    }

                    // Last, always: the ask block follows whatever was most recently
                    // written. Keeping it in a fixed slot above the transcript put the
                    // next set of questions back where the reader tapped, above the
                    // answer they had just asked for.
                    //
                    // The **field** is unconditional and the suggestion rows are not, and
                    // that split is not cosmetic. In the sibling reader the ask field was
                    // part of a block that only appeared once there was something to
                    // follow up on, because there the reader started an exchange by
                    // *selecting a passage* — typing was always a second step. Here
                    // typing a question is the primary interaction and the only way to
                    // start one, so hiding the field until an answer exists leaves an app
                    // with no way in. That is exactly how it shipped for an afternoon
                    // before anyone ran it.
                    askBlock
                }
                .padding(14)
                // The scroll target is the whole content with a `.bottom` anchor, which
                // puts the end of the ask rows at the end of the viewport rather than
                // needing a sentinel row and the stack spacing that would come with it.
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
            // The pane is an inspector *sheet* on a phone, so the keyboard the Ask field
            // raises covers the answer it was typed against. Dragging the text down is
            // then the way back, and without this there is none.
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
                // The question the reader just tapped goes to the top, so it stays in
                // view while its answer fills the space underneath.
                jump { scroller.scrollTo(asked.id, anchor: .top) }
            }
            .onChange(of: runs.isEmpty) { _, isEmpty in
                // A new question and Esc both clear the answer first, and fresh content
                // should start at its beginning.
                guard isEmpty else { return }
                isArmed = false
                wantsDraftFocus = false
                jump { scroller.scrollTo(Self.contentID, anchor: .top) }
            }
            .onChange(of: focusRequest) {
                // ⌘L. The pane may have just been revealed by the same keystroke, so the
                // field exists by the time this lands.
                isDraftFocused = true
            }
            .onChange(of: isBusy) { _, busy in
                // The field is live again: give it the keyboard back, so the next
                // question can be typed without clicking into it first.
                guard !busy, wantsDraftFocus else { return }
                wantsDraftFocus = false
                isDraftFocused = true
            }
        }
    }

    /// One value for "something grew", so following needs a single `onChange` rather than
    /// one per streamed field.
    private var streamTick: Int {
        runs.count + tail.count + followUps.count
            + transcript.reduce(0) { $0 + $1.runs.count + $1.tail.count }
    }

    private var distanceBelowFold: CGFloat { contentFrame.maxY - viewportHeight }

    private func jump(_ scroll: () -> Void) {
        isFollowing = true
        isJumping = true
        scroll()
    }

    private func follow(_ scroller: ScrollViewProxy) {
        // `isBusy` is what separates a live stream from a cache hit, which lands the
        // whole answer in one assignment and should be read from the top.
        guard isArmed, isBusy, isFollowing, distanceBelowFold > 0 else { return }
        // Unanimated, deliberately: this runs once per decoded token, and an animated
        // scroll per token queues sixty overlapping animations a second.
        scroller.scrollTo(Self.contentID, anchor: .bottom)
    }

    /// Content grows downward, so the top edge only moves when someone actually scrolls.
    /// That is what separates the reader scrolling up to re-read from another token
    /// arriving underneath them.
    ///
    /// Two things move the top with no reader involved: one of the pane's own jumps, and
    /// the content getting shorter, which makes the scroll view clamp its offset. Both
    /// are excluded, or following would keep switching itself off.
    private func track(_ frame: CGRect) {
        contentFrame = frame
        defer {
            lastTop = frame.minY
            lastHeight = frame.height
        }

        // Reports arrive a layout pass behind, so a jump is still in flight until
        // something actually changes; that report is the jump landing, and it is the one
        // whose moved top has to be forgiven.
        let landing = isJumping
        if frame.minY != lastTop || frame.height != lastHeight {
            isJumping = false
        }

        if !landing, frame.height >= lastHeight, frame.minY > lastTop + Self.scrollSlack {
            isFollowing = false
        } else if frame.maxY - viewportHeight <= Self.pinSlack {
            isFollowing = true
        }
    }

    // MARK: - The answer

    /// The answer, with its citations as inline chips.
    ///
    /// **One `Text` and not an `HStack` of chips.** A citation belongs in the sentence it
    /// supports — "the matrix is formed in one piece [0019] with the shells" — so it has
    /// to flow and wrap with the prose around it. A stack would put the citations in a
    /// row of their own, which is a bibliography rather than a citation, and it would
    /// break the line wherever a chip fell.
    ///
    /// `Text` will not host a `Button`, so a clickable run has to be a `link` on an
    /// attributed run, intercepted in `ContentView` by an `OpenURLAction`. That is a
    /// slightly odd mechanism for something that never leaves the app, and it is the only
    /// one SwiftUI offers for a tappable span inside flowing text — which is why the
    /// document's reference numerals use it too.
    ///
    /// The three verdicts are three renderings, and each one is the argument in
    /// `CitationCheck` made visible:
    ///
    /// - `.supported` — tinted, underlined, clickable. The model was shown this passage.
    /// - `.unretrieved` — tinted grey, **no link**. The paragraph is real, so it is not
    ///   struck through; the connection is invented, so it does not click.
    /// - `.nonexistent` — struck through, still legible. Reported, never removed.
    @ViewBuilder
    private func answerText(runs: [AnswerRun], tail: String) -> some View {
        Text(attributed(runs: runs, tail: tail))
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(runs: [AnswerRun], tail: String) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            switch run {
            case .text(let text):
                out += AttributedString(text)
            case .citation(let citation):
                var chip = AttributedString(citation.literal)
                let range = chip.startIndex ..< chip.endIndex
                switch citation.verdict {
                case .supported:
                    chip.foregroundColor = .accentColor
                    chip.underlineStyle = Text.LineStyle.single
                    chip.link = CitationLink(citation.target).url
                    chip.setToolTip(
                        Citation.string(citation.target, numbering: numbering), on: range)
                case .unretrieved:
                    chip.foregroundColor = .secondary
                    chip.setToolTip(
                        "This paragraph exists, but it was not among the passages the "
                            + "model was shown — so nothing supports the connection.",
                        on: range)
                case .nonexistent:
                    chip.foregroundColor = .secondary
                    chip.strikethroughStyle = Text.LineStyle.single
                    chip.setToolTip(
                        "There is no such paragraph or claim in this library.", on: range)
                }
                out += chip
            }
        }
        // The tail, always plain. See `CitationScanner`.
        if !tail.isEmpty { out += AttributedString(tail) }
        return out
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(question)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The only sign that work is in flight when the diagnostics strip is
                // hidden, and retrieval plus a cold prefill can run for seconds.
                // Unlabelled, and gone the moment text starts arriving, so it never
                // competes with the stream.
                if isBusy, runs.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if retrievedCount > 0 {
                    Label(
                        "\(retrievedCount) passage\(retrievedCount == 1 ? "" : "s")",
                        systemImage: "doc.text.magnifyingglass")
                }
                // Never hidden by the diagnostics preference. An answer written from
                // keyword matches alone is a *different* answer, and letting it look like
                // a normal one would be the app quietly overstating what it did.
                if isLexicalOnly {
                    Label("keyword search only", systemImage: "textformat.abc")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask a question")
                .font(.headline)
            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Named after the gestures each platform actually has.
    private var instructions: String {
        #if os(macOS)
            "Ask about the library, or select rows first to ask about a passage. ⌘L "
                + "puts the keyboard here. Answers cite the paragraphs they come from; "
                + "click a citation to go there, and ⌘[ to come back."
        #else
            "Ask about the library, or select rows first to ask about a passage. "
                + "Answers cite the paragraphs they come from; tap a citation to go "
                + "there."
        #endif
    }

    /// The suggestions, when there are any, and the field, always.
    ///
    /// Full-width vertical rows with a chevron and dividers, which is what the reference
    /// UI actually is — and it avoids needing a flow layout.
    @ViewBuilder
    private var askBlock: some View {
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
                        onAsk(question, true)
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

                    if index < followUps.count - 1 { Divider() }
                }

                // Closes the list off, so the field reads as its own thing rather than as
                // another suggestion.
                Divider()
            }
            askField
        }
    }

    @ViewBuilder
    private var askField: some View {
        HStack(spacing: 8) {
            TextField("Ask Anything", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isDraftFocused)
                .onSubmit { submitDraft() }
                #if !os(macOS)
                    .submitLabel(.send)
                #else
                    // Esc belongs to the field while it holds the keyboard: it abandons
                    // the draft. It does not reach `DocumentReaderView.onExitCommand`,
                    // which would clear the selection the draft was written against — the
                    // pane is that view's sibling, not its descendant, and commands only
                    // travel to ancestors.
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

    private func submitDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        isArmed = true
        draft = ""
        // The keyboard stays here, so one question can be followed by the next.
        wantsDraftFocus = true
        onAsk(question, false)
    }
}

/// A citation, as a URL SwiftUI can carry on an attributed run.
///
/// The scheme is this app's own and never leaves it: `ContentView` intercepts every
/// `patentreader://` URL with an `OpenURLAction` and returns `.handled`, so nothing is
/// ever passed to the system. See `ReaderLink`, which uses the same scheme for the
/// document's own reference numerals and claim cross-references.
struct CitationLink {
    let target: CitationTarget

    init(_ target: CitationTarget) {
        self.target = target
    }

    var url: URL? {
        let patent = target.patent.slug
        switch target {
        case .paragraph(let key):
            return URL(string: "\(ReaderLink.scheme)://cite/\(patent)/p/\(key.number)")
        case .claim(let key):
            return URL(string: "\(ReaderLink.scheme)://cite/\(patent)/c/\(key.number)")
        }
    }

    /// Reads one back. Returns `nil` for anything that is not a citation URL, which is
    /// what lets `ContentView` route numerals and claims through the same handler.
    static func target(from url: URL) -> CitationTarget? {
        guard url.scheme == ReaderLink.scheme, url.host() == "cite" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, let key = PatentNumberParser.parse(parts[0]),
            let number = Int(parts[2])
        else { return nil }
        switch parts[1] {
        case "p": return .paragraph(ParagraphKey(patent: key, number: number))
        case "c": return .claim(ClaimKey(patent: key, number: number))
        default: return nil
        }
    }
}

/// The pane's content frame and its viewport height, in the pane's own coordinate space.
/// Following the stream needs to know how far the end of the content is from the end of
/// the viewport, and on macOS 14 a `PreferenceKey` is how you learn that:
/// `onScrollGeometryChange` and `ScrollPosition` are 15+.
private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    /// Only one view reports a real frame, but sibling subviews — the scroll view's own
    /// background layer among them — all contribute the default, and they are not visited
    /// in any guaranteed order. So keep whichever value is not the default rather than
    /// the one that happens to come last.
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
