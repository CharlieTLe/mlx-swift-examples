# Patent Reader

A SwiftUI app for macOS, iPhone and iPad that answers questions about a library of
patents on-device — and cites the paragraphs it answered from, so **clicking a citation
lands you on the passage**, highlighted, in a document pane that stayed on screen the
whole time. After the initial model download there are no network calls except fetching
patents, and fetching a patent's original PDF the first time you open its PDF tab.

Reading a patent to answer a specific question is miserable in a way that is not the
reader's fault. The answer is almost never in one place: it is a sentence in `[0042]`,
qualified by a limitation in claim 7, which depends on claim 1, which uses a term the
specification defined forty paragraphs earlier. Full-text search and a PDF find bar hand
back positions, not passages, and leave the reader to do the joining. This collapses that
loop.

## Building

One multiplatform target and one scheme in `mlx-swift-examples.xcodeproj` cover Mac,
iPhone and iPad:

```bash
open mlx-swift-examples.xcodeproj    # scheme: PatentReader
```

Pick a destination and Run. The scheme launches and profiles in **Release**; a debug 4B
forward pass is not worth watching. From the command line:

```bash
xcodebuild -scheme PatentReader -destination 'platform=macOS' build
```

Like every other target here the project sets no `DEVELOPMENT_TEAM`, so nobody inherits
anyone else's and the bundle identifier carries the shared `${DISAMBIGUATOR}` from
`Configuration/Build.xcconfig`. Only the iPhone and iPad builds *require* a team; the Mac
build needs none. Both builds need Apple silicon and a full Xcode with the **Metal
toolchain** component installed — the Command Line Tools ship a `metal` that is a stub and
cannot compile mlx-swift's GPU kernels, and a build without them links and launches and
then fails on the first question with `Failed to load the default metallib`.

```bash
xcodebuild -showComponent MetalToolchain      # want: Status: installed
xcodebuild -downloadComponent MetalToolchain  # if it is not
```

**Two models, and one of them you may already have.** First launch downloads
`mlx-community/Qwen3-4B-4bit` (about 2.2 GB) and, on the first import,
`nomic-ai/nomic-embed-text-v1.5` (about 520 MB) into `~/.cache/huggingface`. With the Mac
sandbox off — see below — that directory is shared, so a machine that has run
ShakespeareReader already has the first and a machine that has run
`Tools/embedder-tool` already has the second.

`Applications/PatentReader/tools/wire_target.py` regenerates the target's entry in
`project.pbxproj` from the files on disk. Adding a source file is a re-run rather than a
hand edit; it is idempotent, and running it twice produces a byte-identical file.

There is an app icon: a Big Caslon capital `P`, ink on parchment, in
`Assets.xcassets/AppIcon.appiconset` for the ten macOS sizes and the iOS 1024.
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is the whole of the wiring — actool writes
`CFBundleIconName`, `CFBundleIconFile` and an `AppIcon.icns` into the built bundle itself,
so neither `Info-macOS.plist` nor `Info-iOS.plist` names the icon and neither should. That
setting rides along in the build configurations `wire_target.py` copies from
ShakespeareReader's, so a re-run does not drop it. The PNGs are checked in;
`swift tools/icon/make_icon.swift` regenerates them.

Big Caslon because the reader offers it and it is the only Caslon macOS ships, so the mark
is set in a face the app actually renders patent text in. It is the same script and the
same two colours as ShakespeareReader's `S`, deliberately — sibling apps that should look
like it — and one number differs. `markHeightFraction` measures the glyph's *bounding box*,
and an `S` overshoots the cap line and baseline at both curved ends while a `P` is
flat-topped and sits squarely on the baseline; the same 0.62 therefore buys the `P` a
shorter cap in a tile its narrow silhouette already leaves emptier, so it is 0.65 here.
What made a letterform the right answer at all is the 16pt tile: figure/ground contrast is
the entire design budget there, and a glyph is nothing but one high-contrast shape.
`tools/icon/NOTICE.md` carries the rest of the reasoning.

## What it does

Ask a question of the library and get prose back that cites `[0042]` and `claim 7` the way
a brief does. Every citation is checked, and there are **three** answers rather than two:

- **Supported** — the paragraph exists *and* was among the passages the model was shown.
  A clickable chip.
- **Unretrieved** — the paragraph exists, and the model was never shown it. Rendered as
  plain text, **not a link**. The number is real, so striking it through would be the app
  calling the model a liar about something true; but the model did not read that
  paragraph, so the *connection* is invented, and making it clickable would launder that.
- **Nonexistent** — no such paragraph or claim. Struck through, still legible.

It **reports and never strips**, which is `QuoteCheck`'s doctrine carried over: a bad
citation is evidence about a prompt, and deleting it before anyone sees it spends the
signal to tidy the symptom. Counts by verdict go in the diagnostics strip and in
`--benchmark`'s summary.

**What none of this catches**, and the UI should not imply otherwise: a real, retrieved
paragraph cited for a claim it does not make comes back *supported* and always will. No
string comparison reaches that. What the app can do instead is make checking cheap — one
click puts you in front of the actual paragraph — and that is what the whole design is
for.

### Getting patents in

- **By number.** `+` → Add by number, or just type a number into the find field: an
  unmatched number offers a *Fetch* row rather than "No patents match", because a number
  typed into a patent app is a request for that patent. Any spelling works —
  `US10123456B2`, `10,123,456`, `10123456`.
- **By dropping a PDF** on the library, or `+` → Import PDF.

**Google Patents is the primary path and the PDF path is a fallback**, and the gap is
wide. The HTML gives paragraph numbers, the claim dependency graph and reference numerals
as *data*; the PDF gives text, and everything else has to be reconstructed from regular
expressions. Use the number where you have one.

**Either way the library keeps the original PDF**, which is what the reader's second tab
shows. A dropped file is copied into the library at import, because a picker URL on iOS is
dead after the next launch and a path on a Mac breaks the moment the file moves. A patent
fetched by number is *not* downloaded eagerly: the page carries a
`<meta name="citation_pdf_url">` pointing at the office's own PDF, and that link is
followed the first time somebody opens the PDF tab and never again. **Patents imported
before any of this existed get it too** — the page they were parsed from is already on
disk, the link is read back out of it at the next launch, and nothing has to be
re-imported.

The PDF path refuses rather than importing something wrong in three cases, all of which
produce a document that would look fine and be useless: a PDF with **no text layer** (a
scanned pre-1976 grant), one whose recovered `[nnnn]` numbers are **not ascending**, which
means the two columns were read interleaved and the paragraphs would be shuffled, and one
where a single paragraph comes out holding **most of the document**, which means the
paragraph breaks stopped being found and everything after that point was merged into one
row that every citation would then name.

Short of refusing, the paragraph breaks come from whichever of **three readings** the
document supports, tried in order of how much each one claims:

| Reading | What it trusts | When it is reached |
| --- | --- | --- |
| `[nnnn]` markers | the document's own numbering | a grant or publication that prints them |
| blank lines | the extraction's own paragraph breaks | PDFKit gave any |
| line lengths | a line that stops short of the measure ends its paragraph | neither of the above found a break |

The third is the crude one and `Source.note` says when it was used. It is also what makes
a **PCT application as filed** readable: no `[nnnn]` markers are printed in one, the
applicant did not number the paragraphs and no office added them, and PDFKit returns its
pages as one line per printed line with no blank line anywhere — so without it, three
hundred paragraphs are a single row.

Before any of that, the **page furniture** comes off: the running head, the page number,
and the printed line numbers down the margin. None of the three is part of the document
and all three land mid-sentence once the text is extracted — `5 5' untranslated region
(5'UTR)` is a corrupted sentence that would be embedded, retrieved and quoted back with
the margin number still in it, and `10 10. The composition of claim 8` is not recognised
as claim 10, which loses every claim after it. A running head is identified by position
and not only by recurrence, because body text recurs too: one grant repeats a claim
limitation on half of its pages, and a rule that went by recurrence alone would delete it
out of the claims.

Where all of this leaves the two shapes on hand: a **PCT publication** comes out whole,
markers and claims and all. A **grant PDF off Google's own servers** is OCR — `[0001]`
comes out as `0001.` with the brackets gone — so its paragraphs are line-length guesses
and its claims are only found when the OCR left the preamble intact. Those are exactly the
documents to fetch by number instead.

### The markup is not uniform, and that shaped the model

The plan for this app assumed Google Patents' markup was regular because one patent was
checked. It is regular, in **four different ways**, and each one is a fixture in
`--selftest`:

| Shape | Paragraph element | Printed number? | Fixture |
|---|---|---|---|
| A | `<div id="p-0002" num="0001" class="description-paragraph">` | yes, in `num` | `US10123456B2` |
| A′ | the same, but `class="description-line"` | yes | `US20140030575A1` |
| B | `<div num="p-0002" class="description-paragraph">` | **no** — `num` holds the id | `US7654321B2` |
| C | `<div class="description-paragraph">` | no | `US5000000A` |

Three consequences run through the whole app:

- **`num` is a paragraph number only when it is digits.** In shape B it holds `p-0002`,
  and reading that as a number prints `[2]` beside a paragraph the patent numbers
  `[0001]`. In shape A the `id` is offset from the `num` — `id="p-0002"` carries
  `num="0001"` — so the id suffix is not the number either.
- **Missing paragraph numbers are not a pre-2001 problem.** `US7654321B2` is a 2010 grant
  with printed `[0001]`s that this source does not expose. So `Numbering` is a property of
  what arrived, never of the patent's age.
- **`<claim-ref idref>` is not always there.** Where it is, the claim tree is exact data.
  Where it is not — `US5000000A` has `claim-dependent` wrappers and zero `claim-ref`
  elements — the dependency is read from the claim's own wording, and
  `Claim.dependencySource` records which, because a tree drawn from inferred edges should
  say so. The parent badge's tooltip is where it says it.

### Citations tell you whose numbering they are

Roughly half the patents this app can import arrive with no printed paragraph numbers at
all. Where they do, a citation reads `US 10,123,456 B2 · [0042]` and a chip reads
`[0042]`. Where they do not, the importer counts from 1 and says so: `US 6,285,999 B1 ·
¶12 (numbered by this reader)`, with a chip that reads `¶12`. A bracketed number claims
the patent office's authority and a pilcrow does not, so the two never look alike even at
chip size — because a reader who copies `[0042]` into a brief and then opens the printed
grant will not find it, and that would be a wrong citation this app caused.

### Retrieval, and why there are two legs

`PassageContext.swift` in the sibling reader opens: *"No embeddings: the act / scene /
speaker hierarchy is a better index than a vector store here, and it is exact."* That is
right, and it is right for a reason that does not survive the move. **There, the reader
selects the passage** — the app is never asked to find anything, so the hierarchy is a
better index because the index's only job is to describe what was already pointed at, and
exactness is free when nothing is being searched for. **Here the reader asks a question
and does not know where the answer is.** A patent's hierarchy is just as exact and
completely useless for that: sections are boilerplate, paragraph numbers are ordinal, and
nothing in the structure co-varies with meaning. The exact index still exists — it is what
citations resolve against — it just is not what finds the passage.

Retrieval is **dense plus BM25, fused with reciprocal rank fusion**. The lexical leg is
not optional, and the queries that need it are the *normal* case here rather than an
exotic one:

- **Reference numerals.** "What is 100?" A 768-dimensional embedding puts `100` and `102`
  at nearly the same point. BM25 treats them as distinct rare terms and lands on the
  paragraph that introduces the part. One fixture carries 104 distinct numerals.
- **Terms of art.** `comprising`, `consisting essentially of` and `consisting of` are
  three different claim scopes; an embedding calls them synonyms.
- **Coined vocabulary.** Every patent invents nouns, which is exactly what dense
  retrieval is worst at.

It is a mitigation, not a fix. nomic-embed-text-v1.5 is trained on general web text and
claim language is deliberately unnatural; if retrieval is visibly poor the next lever is a
domain embedder, not more prompt work.

Two chunking corrections keep the retrieval unit and the citation unit the same thing:

- Paragraphs over ~250 words are split at **sentence** boundaries into overlapping windows
  that keep the same paragraph number. Retrieval gets granularity, citations stay
  paragraph-granular, and the windows are collapsed before the model sees anything.
- Claims are one chunk each, embedded with **their parents' text prepended**. "The method
  of claim 6, wherein the seal plugs comprise expansion plugs" embeds as a vector about
  seal plugs and nothing else. The *shown* text stays the claim's own words, so the prompt
  cites `claim 7` and prints claim 7.

**The nomic prefixes are applied.** `search_document: ` at index and `search_query: ` at
query are part of the input that model was fit to, not a convention.
`Tools/embedder-tool` applies neither while defaulting to that model, which is a real
retrieval-quality defect there and worth its own change; this app must not inherit it. The
prefix is recorded in every index file and a mismatch invalidates it.

### Two search fields, and they answer different questions

The library's field reads a query as a request about *documents*: `US10123456` opens that
patent or offers to fetch it, `[0042]` and `claim 7` jump inside the open one, and anything
else filters the list by title, assignee and inventors. It never looks at a word of the
specification.

The reader's field, ⌘F, searches the words. That is the question a patent reader actually
asks most — *where does this one say "internal matrix"?* — and it is the one thing the app
could not do. `DocumentFind` is a value type with the matching rules in it, so `--selftest`
asserts them without a view.

Three things about it are worth stating, because each had a plausible alternative:

- **The count is the feature.** `3 of 47` is what tells a reader that a term is used
  throughout rather than once, which turns ⌘G into a survey of how the specification uses
  it. A field that only jumped to the next hit would answer a smaller question.
- **Matching does not reuse `LibrarySearch`'s folding**, and this is the subtle one. Folding
  is right for a filter, where only the verdict matters, and wrong here because it *rewrites*
  the string — it drops apostrophes and decomposes diacritics — and an offset into a
  rewritten string does not address the original. One `L'Oréal` earlier in the paragraph
  would shift every highlight after it by a character. `range(of:options:)` reports its
  answer in the original's own indices with the same insensitivity, so the offsets are right
  by construction rather than by a compensating calculation. `--selftest` checks every match
  in a real fixture by going back to the text and reading what its offsets address.
- **Finding does not select.** A selection here scopes the reader's next question, so a find
  that selected what it landed on would quietly narrow the next question to whatever word
  they were checking the spelling of. Hits are drawn as a run background — yellow, and orange
  for the current one, deliberately not the accent colour that the selection band, the
  landing flash and the reference numerals already share.

⌘F therefore belongs to the document, and the library's filter moved to **⌥⌘F** to give it
up: two hidden buttons cannot share a shortcut, and of the two fields the document's is the
one ⌘F means everywhere else. ⌘G and ⇧⌘G step, Esc closes, and on a phone — which has none of
those keys — the bar is raised from the overflow menu.

A hit inside a claim is the one case that needed real work. A claim is **one** row whose text
is its preamble and its elements joined, because that is the unit a citation names and ⌘C
copies, but `ClaimRowView` draws those pieces separately — so a highlight has to be cut to
the piece being drawn and rebased onto it. Spans are simply dropped past the preamble, which
is a small loss; a highlight cannot be, because it is what the reader is looking for.

### Two selections, and the margin between them

The prose is **system-selectable text** on both platforms: drag out a clause, copy exactly that
clause. A reader quoting a patent into an email wants the clause, not the paragraph.

It coexists with the *passage* selection — whole rows, banded — which is the one the app can
act on: it scopes a question, keys the answer cache, and produces a citation. There are two
because SwiftUI never reports which characters are in a text selection, so nothing the app does
can be built on one. Not being told about a selection is no reason to deny the reader one; it
only means the app cannot cite it.

Both wanted the same gesture, and the arbitration is a hit test rather than a mode:

- **The prose** belongs to the text selection. Drag it on a Mac, long-press it on a phone.
- **The number margin** belongs to the passage. It prints the paragraph or claim number, which
  is not prose and can never be part of a quotation, so a press there can only mean "this
  row" — and on a phone a long press there still sweeps a range of rows.
- Rows are otherwise selected by clicking, shift-clicking, double-clicking a heading for a whole
  section, and ⇧↑/⇧↓.

Getting that boundary wrong is not subtle. Armed from anywhere, as the sweep first was, one long
press on a phone produced grab handles *and* a five-row selection band at once — two selections
of two different things from one gesture. The Mac accordingly no longer sweeps rows by dragging:
the pointer's drag is the text's now, and click plus shift-click is how a table has always built
a range. Nothing became unreachable.

**A heading is not selectable**, and that one is easy to get wrong in the other direction. Its
job here is to be a handle — double-clicking one takes the heading and every row under it, which
is how a reader scopes a question to the Background — and a selectable heading loses that,
because the text view swallows the double click to select a word. Headings are also the one
thing in the document that cannot be quoted: they carry no citation.

**⌘C therefore stopped being unambiguous, and ⇧⌘C is the answer.** ⌘C is what a reader presses
to copy the phrase they just dragged out, which is the expectation to honour. The
citation-appended quotation is a different thing and cannot be derived from a text selection, so
it has its own key. With a row selected and no text selection — the ordinary case — ⌘C still
copies the passage exactly as it always did.

Two limitations are worth stating rather than discovering:

- **A character selection stops at the paragraph it started in.** Every row is its own `Text`,
  which is what makes rows the unit of everything else, so no selection spans two paragraphs.
  That is less of a hole than it sounds, because the two selections divide the work: characters
  for a phrase inside one paragraph, a passage for a run of them — and the passage is the one
  that comes with a citation, which is what quoting several paragraphs is usually for.
- **Selecting a row does not clear a character selection**, or the reverse. SwiftUI offers no
  way to clear or even observe one, so both can be live at once in different rows. The banded row
  is always the one a question is scoped to.

One diagnosis that was wrong twice is worth leaving written down, because it cost two rounds of
device verification. It looked as though selectable text had broken scrolling: a slow drag over
the prose selected characters and moved the document not one point. Turning selection back off
did not fix it — the same drag still failed to scroll, and swept rows instead. The culprit was
`SweepRecognizer`'s own long press, which a *synthesized* drag arms because it dwells at its
start point where a finger keeps moving, and the threshold sat exactly at its 0.3s
`minimumPressDuration`. Scrolling was never the text's fault. The same round of measurement did
find a real bug in that recognizer: it subtracted the content offset without the adjusted content
inset, so every press landed about an inset — ~136pt, two rows — further down the document than
the finger, which is fixed.

### Two views of one patent

A segmented control at the head of the reader pane: **Reader text** and **Original PDF**.

The reader text is this app's argument — rows, paragraph numbers in the margin, a claim
tree, citation chips that land on a passage — and it is a *reading* of the document. The
PDF is the document. A figure, a table, a chemical structure, a signature block and the
office's own typesetting are all things the parse cannot carry, and "is `[0042]` really
`[0042]` in the printed grant?" is a question only the original answers. A **scanned**
pre-1976 grant renders perfectly here even though `PatentPDFImporter` refuses to import
one, which is half the point.

Everything the app *does* addresses the parsed text, and the division is worth stating
plainly because it is what a reader has to hold:

- **A citation click always switches you to the text**, deliberately. A paragraph number
  is a fact about the parse; the PDF is paginated by the office's typesetting and carries
  no index this app can resolve `[0042]` against. So the tab moves with the jump rather
  than the jump quietly doing nothing behind a PDF. Same for a reference numeral, a claim
  cross-reference, `[0042]` typed into the library field, a section picked from the
  outline, and ⌘[ / ⌘].
- **⌘F switches too**, and raises the reader's find bar. `PDFView` ships no find UI on
  either platform — Preview's find bar is Preview's own code — so a ⌘F left unbound would
  be a working shortcut that silently stopped working on one tab. The macOS header button
  and the iOS overflow row do the same.
- **⇧⌘C is absent on the PDF tab.** A citation needs rows, and a `PDFSelection` cannot be
  mapped back to a paragraph. **⌘C is PDFKit's own** and copies the selection *uncited*,
  because no truthful citation can be attached to it.
- **Esc does nothing there.** Esc means "put that away" in a ladder — find bar, selection,
  cancel — and a tab is not a thing you put away.
- The PDF tab is PDFKit and nothing else: no find bar, no row selection, no chips drawn
  over it. Continuous vertical scroll, its own zoom and selection, opened at page 1 and
  remembering its page per patent for the launch.

One reader is in the hierarchy at a time — a `switch`, not a hidden `ZStack` — which is
what guarantees there are never two ⌘Fs and never a several-hundred-row `LazyVStack` and a
`PDFDocument` resident at once. It costs two things, both accepted: the find bar and its
query do not survive a trip to the PDF, and a hand-panned scroll position is lost, though
a reader with a row selected lands back on it.

**Both segments are always there and always enabled**, even with no PDF to show, because a
disabled segment states the fact and withholds the reason and the pane's chrome would
change shape as you click down the library. There are four ways to have no PDF and each
one names itself and what to do: the page carried no `citation_pdf_url`; the stored page
is gone, so remove the patent and fetch it again; a PDF import whose copy was not kept, so
import the file again; and a text import, which never had one. A download that fails
reports the underlying error **verbatim** with a **Try again** button, and does not
re-request itself every time you touch the control.

### Typography

- **Every paragraph number in the margin**, tabular figures, system face for its digits.
  Every one, not every fifth: a play numbers lines so a citation can be checked and a
  number on every line is noise, where a patent's paragraph number *is* the citation
  target and every one of them is something the answer pane may point at.
- **Claims as a hanging-indent tree.** One indent level per step from an independent
  claim, a `⌐6` badge naming the parent, and the words "claim 6" inside the text linked to
  the same place. This is the biggest legibility win available and it costs nothing,
  because the dependency data is exact. A claim set is a tree that every patent prints as
  a flat list, and reconstructing it by hand is a reader's first job on opening one.
- **Claim elements hang** at their own nesting depth, at body size rather than a step
  down — they are not an aside, they are the claim.
- **Reference numerals** are tinted and set in tabular figures **only when the source
  tagged them**, from `figure-callout`. Never a regex guessing that every three-digit
  number is a part. Hovering one names it; clicking goes to where it is introduced.
- **Front page as a card**: title, number, dates, assignee, inventors, CPC with the
  office's own gloss, abstract — and the provenance, including anything the importer had
  to admit to.
- Measure capped at 640pt, about 70 characters, scaled with the type.

Four typefaces and five sizes, from the same `Aa` menu, remembered between launches, and
setting the **patent text only** — the library, the answers and the chrome stay on the
system face.

## Latency

Measured on this machine over the six `--benchmark` questions, against a three-patent
library (302 chunks):

| question | chunks | retrieval | prompt tok | TTFT | decode tok/s | words | cited ✓/?/✗ |
|---|---|---|---|---|---|---|---|
| how is the internal matrix formed? | 8 | 182 ms | 1870 | 2.55 s | 136.5 | 110 | 5/1/0 |
| what does claim 7 require that claim 1 does not? | 8 | 9 ms | 1509 | 1.02 s | 139.7 | 83 | 7/3/0 |
| what is 100? | 8 | 8 ms | 1760 | 1.14 s | 137.7 | 97 | 5/1/0 |
| is the heat sink claimed as comprising a matrix, or consisting of one? | 8 | 9 ms | 1557 | 1.01 s | 138.6 | 123 | 7/1/0 |
| does the patent claim the missile, or only the heat sink? | 8 | 9 ms | 1493 | 1.00 s | 138.6 | 105 | 1/2/0 |
| what does this patent say about lithium-ion battery chemistry? | 8 | 8 ms | 2151 | 1.42 s | 135.1 | 79 | 5/0/0 |

Mean 1,723 prompt tokens, 1.36 s to first token, 138 tok/s decode, 3.57 GB peak.
**Retrieval is 8-9 ms** once the embedder is resident; the 182 ms on the first row is it
loading. A flat `vDSP` scan over 302 chunks is three orders of magnitude below the model's
time to first token, so nothing here wants an approximate index.

Prompts run 1,500-2,200 tokens against ShakespeareReader's 526-1,023, which is what
retrieved patent prose costs. The first thing to shed if that grows is the chunk count
(8 → 6), not the independent claims.

Indexing a 41-paragraph patent, a 164-paragraph one and a 58-paragraph one — 302 chunks —
took **21 s including the embedder download**, and the documents were readable the whole
time.

### What the first measured run says about answer quality

Two defects, both visible in the table above and both recorded rather than tuned away,
because a measured baseline is worth more than an unmeasured improvement:

- **The "cite nothing" rule is not obeyed.** Asked something the library cannot answer,
  the model correctly said *"This patent does not mention lithium-ion battery chemistry"*
  — and then cited five paragraphs anyway, against an explicit instruction to cite none.
  This is the row that matters most in the sample and it is the one that fails.
- **Eight citations of thirty-eight were `unretrieved`.** Real paragraphs the model was
  not shown. That is the verdict doing its job — none of them is clickable — and it is
  also a signal that the model reaches past its passages more than the prompt asks it to.

Zero citations were invented across the run, which is the failure the check was most
expected to catch.

`Prompts.version` is 1 and both of these are where prompt iteration would start. The
sibling reader's twenty-version history says this takes several measured rounds; the
discipline is the same here — a change bumps the version and regenerates the golden render
that `--selftest` compares against.

## On iPhone and iPad

Pick your team under **Signing & Capabilities** and Run. One universal build, iOS 18.0 and
up. The entitlements file asks for one thing,
`com.apple.developer.kernel.increased-memory-limit`.

**Two models share one memory ceiling, and that is the thing to know.**
`AnswerService.tuneMemory(added:)` caps MLX at `min(6 GB, physicalMemory / 2)` — inherited
unchanged from the sibling app, including the iPad8,10 story that produced it. On an 8 GB
phone that is 4 GB against a measured 3.57 GB peak for the LLM plus ~520 MB of embedder:
inside the budget with nothing spare. On a 6 GB device the ceiling is 3 GB and the pair
does not fit. **That is arithmetic over measured parts, not a measurement of the two
running together on a device**, and the honest expectation on a small device is
backpressure and slowness, or a reported failure, rather than success.

So on iOS the embedder is a **transient**: loaded for an import or a question and dropped
60 seconds after it was last used, and immediately when an import finishes or a memory
warning arrives. A reader asking three questions in a row pays the load once. On macOS it
loads lazily and stays, because 2.8 GB against a 48 GB ceiling makes eviction a pure cost.

`tuneMemory` also changed shape. The sibling read `Memory.snapshot().activeMemory` right
after loading and branched on 8 GB, which worked precisely because exactly one model was
ever resident — resident size *was* the model's size. With two, that proxy measures the
sum. It does not misfire today, which is exactly why it was worth fixing before it does:
it now takes a delta against a baseline read before the load.

On the **Simulator** everything except the two models works, and that is more useful here
than next door: MLX has no Metal device there, so the app degrades to **lexical-only
retrieval**, which needs no GPU. BM25 answers reference-numeral and term-of-art questions
well on its own, the answer pane says *keyword search only* rather than letting a thinner
search look like a normal one, and the whole library, reader and citation-chip UI can be
developed there.

## Verifying

```bash
xcodebuild -scheme PatentReader -destination 'platform=macOS' build
xcodebuild -scheme PatentReader -destination 'platform=iOS Simulator,name=iPhone 17' build
APP=$(xcodebuild -configuration Release -showBuildSettings -scheme PatentReader \
  | sed -n 's/.*BUILT_PRODUCTS_DIR = //p' | head -1)/PatentReader.app/Contents/MacOS/PatentReader

"$APP" --selftest      # "selftest: all checks passed"; no model, no network
"$APP" --metal-check   # "metal: ok"; one array on the GPU
"$APP" --fetch US10123456B2          # live fetch + index; the only live-parse check
"$APP" --patent US10123456B2 --paragraph 19
"$APP" --patent US10123456B2 --claim 7
"$APP" --show-prompt --patent US10123456B2 --ask "how is the matrix formed?"
"$APP" --benchmark
"$APP" --greedy        # temperature 0, for prompt A/B work
```

The flags are read by `EntryPoint` before SwiftUI starts, so they need the executable
inside the bundle rather than `open`, and not `./mlx-run PatentReader ...`, which
backgrounds an app scheme with `&` and loses the exit code.

`--selftest` is model-free and network-free and covers twenty-two suites, including:

- **`originalPDFLink`** — the `citation_pdf_url` read out of each of the four fixtures,
  asserted down to the filename, plus the rejections: `http:`, `file:` and `javascript:`
  URLs, an empty meta, a page with no such meta, and an entity-escaped query proving the
  decoding is `HTMLScanner`'s. The assertion that earns it its place is that **at least one
  fixture's PDF filename is not its patent number**: `US10123456B2` publishes
  `US10123456.pdf` but `US20140030575A1` publishes `US20140030575A1.pdf`, all four behind
  an opaque content hash. Constructing that URL from the number is right for three
  documents in four, which is exactly the shape of change that gets made as a
  simplification and then 404s for a quarter of a library.
- **`originalPDFAvailability`** — every state of the PDF tab, driven through a pure
  constructor with a real stored page, including **the retroactive case**: a patent
  imported before this feature existed, with nothing on disk but the page it was parsed
  from, recovers a working PDF link. The four unavailable reasons are asserted for their
  copy as well as their verdict — the two with a remedy have to still name it, so a reword
  that drops "fetch it again" fails the build rather than a reader's afternoon.
- **`googlePatentsParse`** — four checked-in HTML fixtures, one per markup shape, asserted
  against measured counts. The markup-drift alarm. Counts rather than a byte-compared
  golden document, deliberately: a golden would also fail for the hundred cosmetic
  differences a whitespace fix makes, and a test that fails cosmetically gets regenerated
  without being read.
- **`claimTree`** — every dependency resolves, nothing cycles, nothing depends forward,
  and **every dependent claim reaches an independent one**. The last is the one worth
  having: a claim whose chain does not terminate draws flush left as though it were
  independent, which is a false statement about the patent's scope and is otherwise
  invisible.
- **`citationScanner`** — the streaming state machine fed **one character at a time**, and
  again whole, asserted to agree. That is the point rather than thoroughness for its own
  sake: a citation arrives split at an arbitrary byte boundary, and feeding whole strings
  exercises none of it. This suite found two real bugs — a complete citation at the end of
  a stream rendering as plain text, and `[0019] of US 10,123` committing against a patent
  that does not exist because the serial had not finished arriving.
- **`indexIntegrity`** — over synthetic deterministic vectors, so it stays model-free:
  every entry names something that exists, every indexable paragraph has an entry,
  dimensions agree, no non-finite values, every vector is unit length, and the base64
  round trip is exact. What breaks silently about an index is its structure, not its
  numbers.
- **`citationCheck`** — all three verdicts, including a paragraph of a *different* patent
  in the library (real, so `unretrieved`) and one of a patent that is not (so
  `nonexistent`).
- **`documentFind`** — the offsets, checked by going back to each row's text and reading
  what they address, over every hit for a term that occurs 60-odd times in a real fixture.
  That is the assertion worth having: a wrong count is visible on screen and a broken wrap
  goes nowhere, but a match addressed one character to the left just draws a highlight that
  looks slightly off, which is the kind of wrong that ships. Also the wrap in both
  directions, the reading-position anchor, and the claim clipping that puts a hit in the
  element it is actually in.
- Plus `patentNumbers`, `citations`, `chunking`, `lexicalRetrieval`,
  `pdfParagraphRecovery`, `librarySearch`, `goldenPromptRender`, and the ported
  `quoteCheck`, `selection`, `followUpParsing`, `readerFonts`, `readerTextSizes`,
  `readingProgress` and `wordTokenizer`.

**`--fetch` is the check `--selftest` cannot be.** The fixtures are checked in, which is
what makes the self test fast and hermetic and also means it can only detect drift that
has already been captured. Fetching a patent that is not a fixture is what catches Google
Patents changing its markup *today*.

### Checked by hand, because CI builds no app targets

`.github/workflows/pull_request.yml` builds the package and four CLI tool schemes and no
app targets — ShakespeareReader is not in it and neither is this. So: both platform
builds; a real iOS *device* run, since Metal, the memory ceiling and the
increased-memory-limit entitlement are all device-only; a PDF drop checked against the
printed document by eye; citation chips clicked in each of the three verdict states,
including one that crosses patents, with ⌘[ back; ⌘F over a claim, since a hit inside a
claim element is the one highlight whose offsets are rebased rather than used as they are;
and the two selections — a phrase dragged out of the prose and copied with ⌘C, a row swept
from the number margin and copied with ⇧⌘C — since neither is anything `--selftest` can see.
**The touch sweep in particular wants a real finger**: a synthesized drag arms its long press
where a finger keeps moving, which is what made scrolling look broken on a simulator twice.

The PDF tab adds a list of its own, none of which `--selftest` can reach:

- **Storage.** Fetch a patent and check the library directory: a `.json` and a
  `.source.html` and **no** `.source.pdf` — nothing was downloaded. Open its PDF tab: a
  spinner, then the document, and no second request when you switch away and back. Drop a
  PDF on the library and the `.source.pdf` is there *immediately*, before the tab is
  opened, and `cmp`s equal to the file dropped. Delete the patent and all four files go —
  `.json`, `.source.html`, `.source.pdf`, `Index/<slug>.json`. `NOTICE.md` names the PDF
  and its column is right for a mix of patents.
- **The retroactive case.** Import two patents on `main`, switch to this branch, launch:
  both gain a working PDF tab from HTML already on disk, with no re-import.
- **Layout.** The Mac at the 1100pt window minimum with three panes open — the control is
  not clipped and does not stretch. iPhone portrait, iPad regular, and iPad in **Slide
  Over**, which is the size-class transition the bar has to survive. Nothing open: no tab
  bar at all.
- **Keys.** ⌘F from the PDF tab switches to the text *and* leaves the keyboard in the find
  field — type without clicking. The header button and the overflow row do the same. On the
  PDF: ⇧⌘C does nothing, ⌘C copies uncited, arrows and space scroll, Esc does nothing,
  ⌘[ ⌘] ⌘L ⌘1 ⌘2 all still work. Back on the text, nothing fires twice.
- **The jump.** With the PDF up: click a supported chip, type `[0042]` into the library
  field, pick a section from the outline, follow a cross-patent citation — each one flips
  the tab and lands on the paragraph, flashing, with ⌘[ to undo it.
- **The four no-PDF states**, made by hand: strip the `citation_pdf_url` meta from a
  `.source.html`; delete a `.source.html`; delete a `.source.pdf` for a PDF-imported
  patent; and turn the Wi-Fi off, which must report the real `URLError` text, offer **Try
  again**, and *not* re-request on every tab switch while it is failed.
- **PDFKit itself**, on a **real iOS device and not the Simulator**: pinch zoom, long-press
  selection with the system edit menu, momentum scroll, and memory with a large grant PDF
  plus a loaded model, which is the one thing the Simulator can say nothing about. On the
  Mac, ⌘-scroll zoom, drag-select and right-click Copy. And a **scanned** pre-1976 grant,
  which renders here even though the importer refuses it.
- **Regressions the new bar could cause.** The dictionary popover still appears over the
  word rather than offset by the bar's height — both the reporter and the anchor use the
  pane's own coordinate space, but the bar moved the pane's origin. The touch sweep from
  the number margin still selects rows and still scrolls.

## Notes

- **App Sandbox is off on macOS**, as it is for ShakespeareReader and for the same reason:
  sandboxing redirects `~/.cache/huggingface` into the container and re-downloads weights
  already on disk — 2.75 GB here rather than 2.2, and shared with two other targets in
  this repo. The consequence worth stating is that **network access and dropped-file reads
  need no entitlement either**: `com.apple.security.network.client` and
  `files.user-selected.read-only` exist to *re-permit* what the sandbox removed, and are
  inert without one. `PatentReader-macOS.entitlements` is deliberately an empty dict and
  its comment carries the whole argument, including the counter-argument — an app that
  fetches arbitrary URLs and parses somebody else's HTML is a good candidate for a
  sandbox, and if this shipped outside an examples repo it should have one.
- **`SpecSection`, not `Section`.** `SwiftUI.Section` is used by every `List` here, and an
  unqualified `Section` in a view body resolves to whichever is in scope. The sibling has
  the same collision with `Scene` and qualifies its one use site; here it would recur at
  every list, so the model type yields.
- **A citation is a `link`, not a `Button`.** `Text` will not host a button, so a tappable
  run inside flowing prose has to be an attributed `link`, intercepted by an
  `OpenURLAction` that returns `.handled` so nothing reaches the system. The document's
  reference numerals and claim cross-references use the same `patentreader://` scheme and
  the same handler, because from the reader's side they are one interaction: a thing in
  the text that takes you to the thing it names. Citations therefore **flow and wrap with
  the prose** rather than sitting in a row of chips, which is what a citation has to do.
- **The flash highlight animates opacity and nothing else.** `DocumentRowView`'s
  size-neutrality contract — row height feeds `RowFramesKey`, which is written into
  `@State`, which is read back during layout — makes any animating geometry a layout loop
  running at 60 Hz. The overlay's `id` changes per jump so a second jump to the same row
  re-fires; a bare row index would be "no change" and the reader would click and see
  nothing.
- **A programmatic jump is not a selection.** `DocumentReaderView.select(_:)` requests
  keyboard focus; the jump writes `selection` directly. And unlike the sibling, selecting
  a row here **starts nothing** — a selection scopes the next question — so there is no
  debounced commit for a jump to trip.
- **A follow-up does not re-retrieve.** It runs on the same session against the same
  passages, so a citation in the follow-up refers to the same set as the answer above it,
  and the KV cache is reused. A question that needs different passages is a new question.
- **The answer cache keys on the question *and* the retrieved passages.** Keying on the
  question alone would serve an old answer whose citations point at a set the model was
  not shown — manufacturing the `unretrieved` failure the app exists to surface.
- **`--fetch` on a patent already in the library is not an error**, unlike the same action
  in the app. From a terminal it is how a library gets rebuilt, often over the same list,
  so it converges rather than failing — and still indexes anything unindexed.
- **The library is one JSON file per patent**, with the fetched HTML beside it and, where
  there is one, the original PDF as `<number>.source.pdf`, under
  `~/Library/Application Support/PatentReader/`. The HTML is what makes a
  `parserVersion` bump a re-parse rather than another request to somebody else's server.
  `remove` drops all three together with the patent's index file, for the reason it always
  has: what is left behind is invisible, because nothing lists that directory — and an
  orphaned PDF is invisible *and* several megabytes. `NOTICE.md` there is rewritten on
  every change and records what was fetched, from where, when, and whether its PDF is kept.
- **The PDF link is not a field on `Patent`**, and that is three arguments rather than one.
  An *optional* field would be `nil` for every patent already imported, so the read-it-back-
  out-of-the-page fallback has to exist anyway, and the field becomes a second source of
  truth that can disagree with it. A *required* field is a decode failure for every library
  file on disk, and `LibraryStore.load` names-and-skips those, so a reader's whole library
  would come back as warnings. And either one invites a `GooglePatentsParser.version` bump,
  which is the index's invalidation lever — every patent in every library reindexed, tens
  of GPU-seconds each, to store a string. `Source.url` is no help either: it is the Google
  *page* on one path and a possibly-gone local file on the other.
- **The PDF's page position is in memory only.** `ReadingProgress` is stamped with
  `contentSHA256`, which is a digest over the *text*; an unstamped page number could be
  restored against a PDF that has since been replaced and put the reader on page 40 of a
  different document while looking exactly like a restored position. The reading position
  that matters is the text's, and that one is stamped.
- **Index invalidation is six fields**, recorded per file: schema, source digest, parser
  version, chunker version, model id and embedding prefix. Any mismatch reindexes that
  patent and no others.

## Provenance and terms

Patent text is a public record and, in the United States, not subject to copyright. The
page markup these documents are parsed from, and the OCR in older ones, are Google's. This
app fetches one page per patent, on request, and does not crawl.

There is a second host. The original PDF comes from
`patentimages.storage.googleapis.com`, at the URL the page itself names in its
`citation_pdf_url` meta — one file per patent, only when a reader opens that patent's PDF
tab, never crawled and never fetched ahead of being asked for. The same unclear-terms
caveat below applies to it, and the app names the host on screen while it is downloading
rather than pinning it in code, so a moved bucket reports honestly instead of silently
looking like a patent with no PDF.

**Terms of service for programmatic access to `patents.google.com` have not been cleared
by this project**, and that is worth your own read before relying on this beyond personal
use. There is no engineering fix for that question; what the design does instead is keep
the answer changeable. `Ingest/PatentSource.swift` is one protocol with one implementation,
`parserVersion` is pinned and stored on every document, the fetched bytes are kept so a
re-parse needs no second request, and USPTO's Open Data Portal would be a new conformance
with nothing downstream of it moving.

The OCR is worth one more note: `US10123456B2` claim 5 reads "wherein fon ling the
internal matrix" in Google's own text. A model will silently correct that to "forming",
at which point the quotation is not in the passage — and `QuoteCheck` reports it, which is
the right outcome, because the app should not quietly assert that the patent says
something it does not.
