# Patent Reader

A SwiftUI app for macOS, iPhone and iPad that answers questions about a library of
patents on-device — and cites the paragraphs it answered from, so **clicking a citation
lands you on the passage**, marked, **in the PDF the office published**. Not in a reading
of it: in the document itself, with its figures, its tables and its own typesetting, in a
pane that stayed on screen the whole time. After the initial model download there are no
network calls except fetching patents — the page, and the PDF beside it.

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

  "Shown" has to mean *everything* the prompt carried, and for a while it did not: the
  retrieved set was built from the retrieved passages alone, while `Prompts` also renders
  an **INDEPENDENT CLAIMS** block that `AnswerContext.Entry` assembles on purpose, so that
  a question about scope is answered against what is claimed. A model that read claim 1
  there and cited it was told it had never been shown claim 1, and lost the chip. It hit
  precisely the question the block was added for — ask what a patent covers and every
  citation in the answer came back dead — which is why `retrieved` now unions the
  independent claims in.
- **Nonexistent** — no such paragraph or claim. Struck through, still legible.

It **reports and never strips**, which is `QuoteCheck`'s doctrine carried over: a bad
citation is evidence about a prompt, and deleting it before anyone sees it spends the
signal to tidy the symptom. Counts by verdict go in the diagnostics strip and in
`--benchmark`'s summary.

**What none of this catches**, and the UI should not imply otherwise: a real, retrieved
paragraph cited for a claim it does not make comes back *supported* and always will. No
string comparison reaches that. What the app can do instead is make checking cheap — one
click puts you in front of the actual paragraph, in the office's own PDF — and that is what
the whole design is for.

An answer also **paints its evidence onto the document**: pale for the passages the model
was shown, solid for the ones it cited, accent for the chip you just clicked. Three
statements a reader needs at once, on the page rather than in a sidebar. A citation the
model produced without being shown the paragraph is painted *nothing*, which is the same
argument that already makes that chip unclickable.

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

**Either way the library keeps the original PDF**, because it is what the reader reads. A
dropped file is copied into the library at import, since a picker URL on iOS is dead after
the next launch and a path on a Mac breaks the moment the file moves. A patent fetched by
number carries a `<meta name="citation_pdf_url">` pointing at the office's own PDF, and
that link is followed **during the import, awaited** — one extra request while the reader is
already waiting, rather than a few megabytes fetched later behind a click. The order is
therefore three-stage: parsed, then readable, then searchable. A patent in the library is
one you can open, offline included.

**Patents imported before any of this existed get it too** — the page they were parsed from
is already on disk, the link is read back out of it, and each gains its PDF the first time
it is opened, with no re-import.

The PDF path refuses rather than importing something wrong in three cases, all of which
produce a document that would look fine and be useless: a PDF with **no text layer** (a
scanned pre-1976 grant), one whose recovered `[nnnn]` numbers are **not ascending**, which
means the two columns were read interleaved and the paragraphs would be shuffled, and one
where a single paragraph comes out holding **most of the document**, which means the
paragraph breaks stopped being found and everything after that point was merged into one
paragraph that every citation would then name.

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
hundred paragraphs are a single paragraph.

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

**And a bracketed number has to be the office's own, down to its width.** USPTO zero-pads
to four, so paragraph 100 is `[0100]`. WIPO writes `00` and then the number, so its
sequence runs `[001]`, `[0010]`, `[00100]` — which `PatentPDFImporter` has said at the top
of the file all along, and is why its marker regex accepts three to five digits. `Citation`
padded every office to four anyway, so on WO 2020247738 A9 the app cited `[0309]` for a
paragraph the publication prints as `[00309]`: 347 of 437 paragraph citations naming a
marker that document does not contain. The 90 that were right are paragraphs 10 to 99, the
band where the two conventions agree, which is why nothing caught it — the defect reads as
correct on every sample small enough to check by eye. It was the failure in the paragraph
above, arriving through the door marked *printed* rather than the one the `¶` guards.
`--selftest` now pins both offices, including that 10-to-99 trap.

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

The reader's field, ⌘F, searches the words of the document on screen, through
`PDFDocument.findString`. That is the question a patent reader actually asks most — *where
does this one say "internal matrix"?* — and `PDFView` ships no find UI on either platform:
Preview's find bar is Preview's own code over the same call. So this app builds one, and
`FindBar` is shared byte for byte with the reader that came before.

Two things about it are worth stating, because each had a plausible alternative:

- **The count is the feature.** `3 of 47` is what tells a reader that a term is used
  throughout rather than once, which turns ⌘G into a survey of how the specification uses
  it. A field that only jumped to the next hit would answer a smaller question.
- **Finding does not select.** A selection here scopes the reader's next question, so a find
  that selected what it landed on would quietly narrow the next question to whatever word
  they were checking the spelling of. Hits go through `PDFView.highlightedSelections` and
  never `setCurrentSelection` — yellow, and orange for the current one.

⌘F therefore belongs to the document, and the library's filter is on **⌥⌘F** to give it
up: two hidden buttons cannot share a shortcut, and of the two fields the document's is the
one ⌘F means everywhere else. ⌘G and ⇧⌘G step, Esc closes, and on a phone — which has none of
those keys — the bar is raised from the overflow menu.

Esc is a ladder: the find bar, then the selection, then whatever the app is doing. It is a
`.keyboardShortcut(.escape)` button rather than `.onExitCommand`, because `PDFView`'s own
document view takes first responder — which is also how the arrows, space and page keys
scroll without this app writing a line of it.

### One reader, and how a paragraph number finds itself in it

There were two until recently, behind a segmented control: a list of parsed rows, and the
office's PDF. The parsed text was always a *means* — it is how the app builds an index,
fills a prompt and names a citation, and it still does all three — and the PDF is the thing
a patent reader actually wants in front of them: figures, tables, chemical structures, the
real typesetting, and the ability to check that `[0042]` is `[0042]`. A **scanned**
pre-1976 grant renders here even though `PatentPDFImporter` refuses to import one, which is
half the point.

The one thing the parsed view could do that the PDF could not was land a citation on a
passage, and this codebase argued at length, in two places, that it never would:

> A paragraph number is a fact about the parsed text; the PDF is paginated by the office's
> typesetting and carries no index this app can resolve `[0042]` against.

**That was wrong.** A paragraph's own first words are an index into the PDF, they are
already in the parse, `PDFDocument.findString` resolves one in about two milliseconds, and
`PDFAnnotation` marks what it finds. What the argument got right is that it is not exact —
so the design is a measurement rather than a claim, and the failures are reported rather
than hidden.

#### The measurements it rests on

Probed against three real patent PDFs — a 163-page PCT publication, a 131-page **two-column**
US grant, a 57-page PCT application as filed — anchoring on text from the app's own parse.
`--anchor <number>` reproduces this on any patent in any library:

| | PCT publication | US grant (2 col) | PCT as filed |
|---|---|---|---|
| numbering, as parsed | **printed** | synthesized | synthesized |
| paragraphs located, **printed marker** | **437/437** | — | — |
| paragraphs located, first **6** words | 428/437 (97%) | 1241/1272 (97%) | 284/289 (98%) |
| of those, **ambiguous** (2–4+ matches) | 0 / 242 | 822 | 63 |
| placed in ascending order after the monotonic pass | **437, 0 stuck** | **1241, 0 stuck** | **284, 0 stuck** |
| placements the monotonic pass *changed* vs first-match | 0 / 179 (42%) | 715 (58%) | 44 (15%) |
| of the placements, **on the right passage** | **437/437** / 368 of 428 | not measurable | not measurable |
| claims, `"7. "` + first **4** words | 113/120 (94%) | 20/20 | 21/21 |
| `findString` cost, warm | ~2 ms per anchor; a whole document 0.3–2.8 s | | |

Where two numbers appear the first is the printed marker and the second is what the
opening-words needle scored on the same document, kept because it is what the other two
columns still do.

**"Placed" was not "placed correctly", and the gap was 60 paragraphs.** The publication
prints `[00355]`-style markers, each unique across all 437, so its placements can be checked
against ground truth rather than merely counted — and 60 of the 428 the opening-words needle
placed were on the wrong passage. Not scattered: runs. `[00374]` through `[00389]` each
landed on the *previous* paragraph and slid up to two pages, because a patent writes "In
some embodiments, the …" for pages at a stretch, so every needle in the run matched its
neighbour. The placements ascended, so `monotonic` had no complaint, and the diagnostics
line read 428/437 with nothing anywhere saying 60 of them were wrong. That is the quietest
failure this feature has, and counting placements can never see it.

Anchoring on the marker the office printed removes the whole class: one candidate each,
ambiguity from 242 to 0, the monotonic pass changing nothing because there is nothing to
resolve, and 437 of 437 on the right passage. The opening words stay as the fallback, for a
document whose brackets the OCR dropped.

Four findings decided the design, each of which had a plausible wrong answer:

- **Read the office's own index before guessing.** Where `Numbering` is `.printed` the
  document carries an exact, unique address for every paragraph and the app spent a release
  inferring one from the prose instead. This is first because it is the one that was wrong
  for the longest, and because the argument against it — "the PDF carries no index this app
  can resolve `[0042]` against" — is the same argument, quoted two sections above, that this
  whole feature already proved false once.

- **Short anchors win**, where prose is what there is to anchor on. Twelve words fell to
  about 50% — line wrap and hyphenation break a long match, and `findString` crosses
  neither. Six is the sweet spot; four for a claim. This still decides both fallbacks and
  every paragraph of a `.synthesized` document.
- **Ambiguity is the norm, and ordering resolves it.** Most anchors match in several places,
  because that is what a patent is: it says "the internal matrix 130" in the summary, again
  in the description, and again in a claim. Every candidate gets a *text-stream* ordinal —
  `(page index, offset within the page)` — and the targets are walked in document order
  taking the earliest candidate after the previous choice. A **geometric** ordinal `(page, y)`
  instead collapses on the two-column grant, 93 of 1241 placed, because reading order there
  is not top-to-bottom. When a target has no candidate after the cursor it is left unplaced
  and **the cursor does not move**: one lost chip beats cascading a stray early match into
  everything after it.
- **A claim anchors on its number plus its preamble.** `Claim.text` has the printed number
  stripped, because the old reader drew it in the margin; the office prints it, so putting
  it back makes the anchor both findable and nearly unique. `Claim.fullText` scores 3/20 and
  must never be used — a claim's elements are separated in the printed document by a hanging
  indent. Claim 1 of the canonical fixture is three words long (`A method comprising:`), so
  the four-word rule is a maximum rather than a minimum: the number is doing the work.
- **And that number must not match inside a longer one.** `findString` has no notion of a
  word boundary, so claim 8's needle `8. The method of claim` matches happily inside
  `108. The method of claim`. On a 120-claim PCT publication that is not a curiosity: claim
  8's own number is set at the end of a line, so the primary needle does not match at claim
  8 at all, the sole candidate is claim 108 forty pages downstream, and the cursor follows
  it there. `monotonic` only ever moves forward, so claims 9-120 were then all *behind* the
  cursor — **13 placed of 120**. Rejecting a candidate whose preceding character is a digit
  restores 113. Two things about that failure are worth keeping: the substring match also
  suppressed the fallback that exists for exactly the line-broken-number case, since a
  fallback only fires when the primary finds nothing at all; and the "getting stuck" rule
  below guards a stray match *before* the cursor while this was a stray match *after* it,
  which is the direction that cascades.
- **`.highlight` annotations render translucently** here, verified by rendering a page with
  and without one and counting surviving dark pixels (0.188 → 0.201). No opaque-box
  workaround was needed. The subtype choice is behind one function so `.underline` is a
  one-line swap if a future release composites differently.

The gap in the evidence, stated plainly: all three probes are PDF-*imported* patents, where
the parse and the PDF are the same document. For a patent fetched by number the text comes
from Google's HTML and the PDF from `patentimages`, so they can diverge — `US10123456B2`
claim 5 reads "wherein fon ling the internal matrix" in Google's OCR. There are no PDF
fixtures in the repo and `--selftest` is PDFKit-free by policy, so `--anchor` is how that
case gets measured.

#### Three channels that cannot collide

| What | Mechanism | Colour |
|---|---|---|
| the answer's evidence | `PDFAnnotation` | retrieved `yellow 0.18`, cited `yellow 0.42`, focused `accent 0.30` |
| find hits | `PDFView.highlightedSelections` | `yellow 0.30`, current `orange 0.55` |
| the reader's selection | `PDFView.currentSelection` | the system's |

Separate mechanisms, so closing the find bar cannot disturb an answer's marks and a
selection cannot disturb either. Retrieved is deliberately quieter than a find hit: "the
model was shown this" is weaker evidence than "you searched for this".

**In memory only. `.source.pdf` is never rewritten.** No `write(to:)`, no
`dataRepresentation()`, no autosave. Those bytes are what `NOTICE.md` describes and what the
app promises are the office's, and the manual checklist `cmp`s the file before and after a
session of highlighting. `PatentPDFMarks` also tracks exactly the annotations it added and
removes only those: an office PDF ships its own link annotations, and clearing
`page.annotations` wholesale would vandalise the document on screen.

One annotation per printed **line**, via `selectionsByLine()`. Not an optimisation — it makes
more objects — but correctness: a multi-line selection's `bounds(for:)` is one union
rectangle, which on a two-column grant covers the neighbouring column.

#### When a passage cannot be located

None of a document that prints its markers, since the marker is always there to be found;
3% of paragraphs where it does not, and about 6% of claims either way. It is **reported,
three times over**, in the three
places this app already reports things:

1. the reader is scrolled to the nearest passage that *was* found, and it is marked focused;
2. a transient band over the document: *"`[0042]` is in this patent, but it could not be
   found in the office's PDF. The nearest passage that could is `[0041]`."*;
3. a third line in the diagnostics tally, beside "cited but not retrieved" and "cited and
   does not exist": **"cited and not found in the PDF"**.

Deliberately *not* a fourth `CitationCheck.Verdict`. The verdicts are model-free, PDFKit-free
and decided at commit time inside `CitationScanner`, and a case that depended on a document
being open — and on a map having finished walking it — would break all three at once. A chip
whose paragraph exists and was retrieved is a good citation whatever this app can do with a
PDF; that it cannot land on it is a fact about the app, and it is reported as one.

Plus one document-wide diagnostics line, `anchored 428/437 paragraphs · 106/120 claims`, so a
new document shape that drops to 60% is visible rather than mysterious. That failure is
otherwise *quiet*: chip by chip it looks exactly like a handful of unlucky paragraphs.

#### The rest of the reader

- **Every jump lands here**: a citation chip, `[0042]` typed into the library field, a
  section picked from the outline, a claim cross-reference, and ⌘[ / ⌘]. A section has no
  heading row to scroll to in a PDF, so it aims at the section's **first passage** — `claim 1`
  for the Claims sentinel — which puts the heading one line above the fold and inherits the
  placement the whole document already computed. A reference numeral keeps its pure "first
  paragraph that mentions it" search over the parse and then narrows *within that paragraph's
  own bracket* of the document, so the reader lands on the numeral rather than near it.
- **⇧⌘C copies the selection with its citation.** Two legs: the anchor map's ordinals are
  binary-searched for the passages the drag's two ends fall inside — which never compares a
  character, so hyphenation and OCR cannot break it — and `PassageAnchors.target(containing:)`
  is the textual fallback where the map has no bracket. What is copied is **what was
  selected**, not the paragraphs it fell inside: a drag across half a sentence is a request to
  quote half a sentence. When both legs fail the text is copied uncited **and says so**, in
  the copied text, where it is still true after the paste.
- **⌘C is PDFKit's own** and copies uncited — the system copy, left alone deliberately so that
  ⇧⌘C is the one that means "with the citation".
- **A selection scopes a question** to the open patent, exactly as a row selection used to.
  Deliberately not narrowed to the selected passages: `Retriever`'s scope is a
  `Set<PatentKey>`, and narrowing retrieval to a span inside one document is a different
  feature with its own ranking question.
- Continuous vertical scroll, PDFKit's own zoom and selection, opened at page 1 and
  remembering its page per patent for the launch. The **reading position** that is persisted is
  a `CitationTarget` and not a page: a paragraph number survives a re-downloaded PDF and a page
  number does not.
- **An unavailable PDF is reported, never hidden**, and there is no second view to fall back
  to. Four ways to have none, each naming itself and what to do: the page carried no
  `citation_pdf_url`; the stored page is gone, so remove the patent and fetch it again; a PDF
  import whose copy was not kept, so import the file again; and a text import, which never had
  one. A download that fails reports the underlying error **verbatim** with a **Try again**
  button, and does not re-request itself every time you come back to the patent.

**Two-column selection is PDFKit's to get wrong**, and the app says so rather than pretending
otherwise: a drag down one column can pick up the other in text-stream order. The bracket
lookup copes and produces a range citation, which is *true* — the selection really does span
those passages — but the copied text reads scrambled. A span of many passages from a small
amount of text raises the same band.

### What went with the parsed reader, and what it costs

A pure subtraction of about 3,500 lines, and three of the losses are real rather than
bookkeeping:

- **Accessibility.** The parsed reader gave Dynamic Type over the body text, four typefaces,
  five sizes, system text selection, and a document VoiceOver could read. A PDF reflows for
  nobody; pinch-zoom on a two-column grant is not a substitute, and annotations announce
  nothing. The answer pane's chips remain the accessible route to a passage. This is the one
  item that would argue for keeping the parsed view behind a preference, and it was decided
  rather than discovered.
- **Word lookup.** Double-clicking a term of art and getting the system dictionary is gone
  with `DictionaryLookup`; PDFKit's own long-press menu has **Look Up** on iOS.
- **In-document links.** Reference numerals and claim cross-references were tinted, tappable
  runs in the parsed prose. There is nowhere to hang a link on typeset PDF text, so they
  survive only in the answer pane. `ContentView.showNumeral(_:)` still answers the question —
  it is what a `patentreader://numeral/130` URL routes to — but nothing emits one now.

Also gone, and unmissed: the front-page card, the row band and its sweep gesture, the
hanging-indent claim tree, and the paragraph-number margin — all of which the office's own
document draws better, or prints for itself.

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

  That count was taken before `retrieved` included the independent claims, so an unknown
  share of those eight were citations to claims the prompt did in fact carry, and the
  number is an upper bound rather than a measurement. It is left as it was recorded, with
  this note, because the run is a dated baseline and quietly restating it against a
  different build is how a baseline stops meaning anything. The next `--benchmark` is what
  replaces it.

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
"$APP" --anchor US10123456B2         # anchor its stored PDF and report how well it went
"$APP" --show-prompt --patent US10123456B2 --ask "how is the matrix formed?"
"$APP" --benchmark
"$APP" --greedy        # temperature 0, for prompt A/B work
```

The flags are read by `EntryPoint` before SwiftUI starts, so they need the executable
inside the bundle rather than `open`, and not `./mlx-run PatentReader ...`, which
backgrounds an app scheme with `&` and loses the exit code.

`--selftest` is model-free, network-free and **PDFKit-free**, and covers twenty-one
suites, including:

- **`originalPDFLink`** — the `citation_pdf_url` read out of each of the four fixtures,
  asserted down to the filename, plus the rejections: `http:`, `file:` and `javascript:`
  URLs, an empty meta, a page with no such meta, and an entity-escaped query proving the
  decoding is `HTMLScanner`'s. The assertion that earns it its place is that **at least one
  fixture's PDF filename is not its patent number**: `US10123456B2` publishes
  `US10123456.pdf` but `US20140030575A1` publishes `US20140030575A1.pdf`, all four behind
  an opaque content hash. Constructing that URL from the number is right for three
  documents in four, which is exactly the shape of change that gets made as a
  simplification and then 404s for a quarter of a library.
- **`passageAnchors`** — the needles, which is where the app's central promise is defended
  in a form a build can check. Where the office printed markers a paragraph's needle is that
  marker, asserted to be the very string the chip shows — the two rendering a width
  differently would name one paragraph and land on another — with the six words demoted to
  the fallback and keeping every rule they had. Where it printed none, the six words are
  still the needle and there is no fallback, which is the branch that must not go looking
  for `[0001]` in a document that never contained one. A claim's is `"7. "` plus four words
  and **never** spills into
  `elements` — the 20/20-against-3/20 measurement, pinned so that a "simplification" fails
  the build. No anchor for paragraph 0, which is `Chunker`'s synthetic front matter and
  exists in no document. Anchors ascend in document order, which is what the placement pass
  requires of its input. And the count of paragraphs too short to anchor is a pinned number
  per fixture, because that number *is* the promise's failure rate.
- **`passagePlacement`** — the ordering rule, over synthetic candidate lists, since there is
  no PDF in this repository and `--anchor` is how the real thing gets measured. Identity when
  unambiguous; `[[A1,A5],[A2,A6],[A7]]` → A1, A2, A7, which is the case naive first-match
  gets wrong; a target placed late forcing the next past its own first candidate; stuck →
  unplaced with the cursor unmoved and later targets still placing; empty → unplaced;
  `Candidate(page: 1, offset: 9000) < Candidate(page: 2, offset: 0)`. And over a thousand
  seeded random shapes, the one invariant that is the whole guarantee: **every placed ordinal
  is strictly greater than the one before it.** Plus the find cursor's wrap, lifted verbatim
  out of the deleted `DocumentFind` so its assertions outlived it.
- **`highlightPlan`** — precedence, and the three exclusions that are the interesting half:
  `.unretrieved` and `.nonexistent` citations get no mark, because painting one would be the
  app endorsing a connection the model invented in the most authoritative place it has; front
  matter gets none; another patent's passages are dropped.
- **`passageLookup`** — fixture text run through a synthetic mangler — re-wrapped, a hyphen
  inserted across a break, doubled spaces — still resolves to the right `ParagraphKey`, and a
  foreign string returns `nil` rather than a nearest guess.
- **`originalPDFAvailability`** — every state the PDF can be in, driven through a pure
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
- Plus `patentNumbers`, `citations` — extended for the quotation a PDF selection copies,
  including the uncited one that says so — `chunking`, `lexicalRetrieval`,
  `pdfParagraphRecovery`, `librarySearch`, `goldenPromptRender`, and the ported
  `quoteCheck`, `followUpParsing` and `readingProgress`.

**`--fetch` and `--anchor` are the checks `--selftest` cannot be.** The fixtures are checked
in, which is what makes the self test fast and hermetic and also means it can only detect
drift that has already been captured. Fetching a patent that is not a fixture is what catches
Google Patents changing its markup *today*. And `--anchor` is the only way to measure
anchoring at all, since there is no PDF in this repository and `--selftest` touches no
PDFKit — in particular it is the only way to see the HTML-imported case, where the parse came
from Google and the PDF from `patentimages` and the two can genuinely disagree:

```
US 11,028,179 B2 — 131 pages
  placed 1241/1272 paragraphs · claims 20/20 · ambiguous 822 · monotonic changed 715
  0 too short to anchor · 0 fell back · 2.75s
  not found: ¶89, ¶94, ¶107, ¶339, … and 27 more
```

### Checked by hand, because CI builds no app targets

`.github/workflows/pull_request.yml` builds the package and four CLI tool schemes and no
app targets — ShakespeareReader is not in it and neither is this. So: both platform
builds; a real iOS *device* run, since Metal, the memory ceiling and the
increased-memory-limit entitlement are all device-only; and everything below, none of which
`--selftest` can reach.

- **The marks.** Ask a question and confirm pale marks on the eight retrieved passages,
  solid on the ones the answer cited, and the accent on the chip you just clicked. An
  `.unretrieved` chip paints nothing, which is the point. Then `cmp` the `.source.pdf`
  before and after a session of highlighting: **the bytes must not have moved.**
- **The jump.** Click each chip and land on the paragraph, ⌘[ back. A cross-patent citation.
  `[0042]` in the library field. A section from the outline. A claim cross-reference. And a
  chip whose paragraph cannot be located — force one by editing a `.json` paragraph's first
  words — which must scroll to the neighbour, raise the band naming it, and add the third
  tally line.
- **Anchoring, on shapes the probes did not cover.** `--anchor` a patent fetched by number
  (parse from Google, PDF from `patentimages`) and one imported from a PDF, and read the
  rate. A **scanned** pre-1976 grant with no text layer: everything reports, the diagnostics
  line reads `anchored 0/n`, and nothing crashes.
- **Find.** ⌘F with the count, ⌘G/⇧⌘G stepping and wrapping, the query surviving a click down
  the library, and Esc's ladder — bar, then selection, then cancel.
- **Selection.** Drag text → "ask about this" scopes to the patent. ⇧⌘C copies with a
  citation; a **front-page** selection copies uncited *and says so*; a drag down one column of
  a two-column grant raises the implausible-span band. ⌘C stays PDFKit's own.
- **Storage and the eager download.** Fetch a patent and check the library directory: a
  `.json`, a `.source.html` **and** a `.source.pdf`, all three there before the patent is
  readable. Then turn the Wi-Fi off and open it — it must read, offline. Drop a PDF and the
  `.source.pdf` `cmp`s equal to the file dropped. Delete the patent and all four files go,
  index included. `NOTICE.md` names the PDF.
- **The retroactive case.** Import two patents on `main`, switch to this branch, launch: both
  gain a working PDF from HTML already on disk, with no re-import, one at a time as they are
  opened.
- **The four no-PDF states**, made by hand: strip the `citation_pdf_url` meta from a
  `.source.html`; delete a `.source.html`; delete a `.source.pdf` for a PDF-imported patent;
  and turn the Wi-Fi off for a fetch, which must report the real `URLError` text, offer
  **Try again**, and *not* re-request every time you come back to the patent.
- **Layout.** The Mac at the 1100pt window minimum with three panes open. iPhone portrait,
  iPad regular, and iPad in **Slide Over**, which is the size-class transition to survive.
- **PDFKit itself**, on a **real iOS device and not the Simulator**: pinch zoom, the
  long-press edit menu including **Look Up**, momentum scroll, and memory with a large grant
  PDF plus a loaded model — the one thing the Simulator can say nothing about. On the Mac,
  ⌘-scroll zoom and right-click Copy.
- **The map's cost, on a device.** Anchoring the 1272-paragraph grant is 2.8 s of main-actor
  work on a warm desktop, yielded every 32 anchors. Scroll and select while it runs and
  confirm it stays smooth; `PatentPDFMap.build(in:limitedTo:)` is the escape hatch if it does
  not.

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
  same `patentreader://` scheme also addresses reference numerals and claim
  cross-references, and `ContentView.open(_:)` still routes them, though nothing draws one
  now that the parsed prose is gone. Citations **flow and wrap with the prose** rather than
  sitting in a row of chips, which is what a citation has to do.
- **A jump carries a fresh identity, not a target.** `PassageFocus` holds a `UUID`, so
  clicking the same chip twice moves the reader twice; a bare `CitationTarget` would be "no
  change" the second time and the click would appear to do nothing. The old row reader's
  `FlashHighlight` carried the same `UUID` for the same reason.
- **A programmatic jump does not select.** `PDFView.go(to: PDFSelection)` scrolls and leaves
  `currentSelection` alone, which is what keeps the three channels apart: a jump must not
  scope the reader's next question, exactly as a find hit must not. Selecting **starts
  nothing** either — a selection scopes the next question and no more — so there is no
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
- **The PDF's page position is in memory only, and so is its anchor map.** What is persisted
  is a `CitationTarget`, stamped with `contentSHA256`. A page number, or a `(page, offset)`
  placement, would be restored against bytes that may have been re-downloaded and put the
  reader on page 40 of a different document while looking exactly like a restored position. A
  paragraph number survives that — and the stamp catches the case where it does not, since
  under `.synthesized` numbering the numbers are the parser's own count and a re-parse can
  renumber the whole document.
- **Index invalidation is six fields**, recorded per file: schema, source digest, parser
  version, chunker version, model id and embedding prefix. Any mismatch reindexes that
  patent and no others.

## Provenance and terms

Patent text is a public record and, in the United States, not subject to copyright. The
page markup these documents are parsed from, and the OCR in older ones, are Google's. This
app fetches one page per patent, on request, and does not crawl.

There is a second host. The original PDF comes from
`patentimages.storage.googleapis.com`, at the URL the page itself names in its
`citation_pdf_url` meta — one file per patent, as that patent is imported, never crawled. It
is fetched eagerly now, which is a change worth naming here rather than only in the code:
the PDF is the document the app shows, so a patent whose bytes have not arrived is a patent
nobody can read. Still one request per patent, still only for patents a reader asked for by
number. The same unclear-terms caveat below applies to it, and the app names the host on
screen while it is downloading rather than pinning it in code, so a moved bucket reports
honestly instead of silently looking like a patent with no PDF.

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
