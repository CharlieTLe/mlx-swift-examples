# Patent Reader

A SwiftUI app for macOS, iPhone and iPad that answers questions about a library of
patents on-device — and cites the paragraphs it answered from, so **clicking a citation
lands you on the passage**, highlighted, in a document pane that stayed on screen the
whole time. After the initial model download there are no network calls except fetching
patents.

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

The PDF path refuses rather than importing something wrong in two cases, both of which
produce a document that would look fine and be useless: a PDF with **no text layer** (a
scanned pre-1976 grant) and one whose recovered `[nnnn]` numbers are **not ascending**,
which means the two columns were read interleaved and the paragraphs would be shuffled.

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

`--selftest` is model-free and network-free and covers nineteen suites, including:

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
printed document by eye; and citation chips clicked in each of the three verdict states,
including one that crosses patents, with ⌘[ back.

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
- **The library is one JSON file per patent**, with the fetched HTML beside it, under
  `~/Library/Application Support/PatentReader/`. The HTML is what makes a
  `parserVersion` bump a re-parse rather than another request to somebody else's server.
  `NOTICE.md` there is rewritten on every change and records what was fetched, from where,
  and when.
- **Index invalidation is six fields**, recorded per file: schema, source digest, parser
  version, chunker version, model id and embedding prefix. Any mismatch reindexes that
  patent and no others.

## Provenance and terms

Patent text is a public record and, in the United States, not subject to copyright. The
page markup these documents are parsed from, and the OCR in older ones, are Google's. This
app fetches one page per patent, on request, and does not crawl.

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
