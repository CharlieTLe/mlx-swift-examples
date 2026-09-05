# BibleReader

A three-pane reader for the **Douay-Rheims Bible (Challoner revision)** with an
on-device LLM commentary pane. macOS, iPhone and iPad. The corpus ships with the app, so
after the model download there are no network calls.

It is a sibling of [ShakespeareReader](../ShakespeareReader/README.md) and shares almost
all of its reading chrome — the typeface and size menus, sweep-to-select, word hover and
dictionary lookup, the `HSplitView` / `NavigationSplitView`+`.inspector` split, the
diagnostics strip. What is different is the corpus and the annotation layer, and one fact
about the corpus drives most of the difference.

## The one thing worth knowing

**This edition ships with its own commentary.** Bishop Challoner's 1750s revision carries
a preface to every book, an argument to almost every chapter, and 1,772 verse-anchored
interpretive notes. All of it is public domain, all of it is Catholic, and all of it is
already in the text.

That changes what the model is for. ShakespeareReader had to *infer* the things it put in
its prompt — who was on stage, what a scene was about — and its one inferred field is
labelled approximate all the way through. Here the prompt hands the model authored text
and asks it to explain it:

```
BOOK: The Book of Genesis — Old Testament, Pentateuch
ABOUT THIS BOOK: <Challoner, verbatim>
CHAPTER: Genesis 14
WHAT THIS CHAPTER COVERS: <Challoner's argument, verbatim>
NOTES FROM THIS EDITION (these are the authority where they apply):
  - "Of slime. Bituminis": <Challoner's note, verbatim>
CROSS-REFERENCES (already verified against this Bible — explain these and no others):
  - Genesis 11:3 — "And each one said to his neighbour: Come let us make brick…"
THE FOUR SENSES: literal … allegorical … moral … anagogical …
BEFORE / SELECTED PASSAGE / AFTER
THE MOMENT: <facts>
<closing: the four sections, their word budgets, and their shape>
```

Three of the four annotation layers are therefore *retrieve-and-explain* tasks, which a
4B model does well, rather than *recall* tasks, which it does badly. The exception is
`THE TRADITION`, and it is labelled in the pane as generated and unverified — see
[Limitations](#limitations).

There is also a structural saving. ShakespeareReader generates a synopsis of every scene
in the background, with a prewarm task, a partial-coverage state and half a cache behind
it. Challoner already wrote one for every chapter, so all of that machinery is simply
absent here.

## Four sections, not one paragraph

ShakespeareReader forbids headings and produces one flowing paragraph. This app
deliberately breaks that house style, and `Prompts.version` records why at length. The
short version: the requirement changed. Four distinct kinds of annotation is a different
product, and ShakespeareReader's own graded history establishes by measurement that a 4B
model silently drops rules that sit far from the end of a prompt. A single paragraph asked
to cover four bases will lose one or two of them *invisibly* — a missing cross-reference
section reads exactly like a passage with no cross-references.

Four fixed markers make the omission visible instead. `Annotation.parseSections` splits on
them, tolerating missing, reordered, bolded, un-colonned and repeated labels, and the pane
renders an absent section as absent rather than padding it.

Measured over the thirteen benchmark passages at `Prompts.version = 2`:

| section | produced |
|---|---|
| `PLAIN SENSE` | 13/13 |
| `CONTEXT` | 13/13 |
| `SEE ALSO` | 10/13 — and the three misses are the three passages that had no cross-references to list, so it is 10/10 |
| `THE TRADITION` | 13/13 |

## Keeping a 4B model honest

Four checks run over every annotation. None of them needs the model, and none costs
measurable latency.

| check | question | what it does |
|---|---|---|
| `QuoteCheck` | is this quotation in the selected passage? | reports, never strips |
| `ReferenceCheck.quotedVerse` | is this quotation anywhere in the Bible? | reports, never strips |
| `ReferenceCheck.check` | does this scripture reference exist, and was it supplied? | **the only one the reader sees** |
| `PatristicCheck` | is this a named Father, work or council with a locator on it? | reports, marks unverified |

`ReferenceCheck` is the one that departs from ShakespeareReader's report-never-strip rule,
and the departure is deliberate. A misquoted line is evidence, and half of what that app
learned came from reading them. A *nonexistent scripture citation shown as if it were
scripture* is a different category: `Hezekiah 4:2` looks exactly as authoritative as
`Isaias 7:14` in the same typeface, and the reader has no way to check either. So the
three verdicts render differently:

- **`ok`** — exists and was supplied. A tappable link; ⌘[ comes back.
- **`ungiven`** — the verse is real but was not supplied, so the *connection* is invented.
  Plain text, no link.
- **`nonexistent`** — struck through, "not in this Bible".

Nothing is deleted in any case, and counts of all three land in the diagnostics strip.
Over the benchmark run the model produced 5 `ok`, 6 `ungiven` and 0 `nonexistent`
references, which is the check doing exactly what it exists for: six invented connections
that the pane will not present as links.

## Every reference is somewhere you can go

`SEE ALSO` was the only tappable reference in the app and is the smallest share of them.
The model writes references in running prose throughout the other three sections and,
above all, in answers to follow-up questions; Challoner's notes are full of his own
`Gen. 2.24` and `chap. 5.3`. `ReferenceLinks` makes all of them links — an
`AttributedString` run carrying a `drb://` URL that `ContentView`'s `OpenURLAction`
intercepts before the system, so nothing is registered in either `Info.plist` and the
link never leaves the process. ⌘[ comes back.

**Inline links resolve on existence, not on provenance**, which is the one place they
part company with the three verdicts above. The supplied/`ungiven` distinction earns its
keep in `SEE ALSO`, where the *connection* is the claim being made; in running prose the
only question is whether the passage is in this Bible, and an answer about the parables
reaches outside the supplied set by definition. A reference that does not resolve is
struck through, for `ReferenceCheck`'s reason.

**Challoner is exempt from the strike.** If a reference in a 1750 note fails to resolve
the likely fault is our parser, not the bishop, so an unresolved span in a note is left
exactly as printed. Only model output is struck.

## Measurements

Qwen3-4B-4bit, M-series Mac, `--benchmark`, `Prompts.version = 2`.

| passage | prompt tok | prefill tok/s | TTFT | decode tok/s | words | sections |
|---|---|---|---|---|---|---|
| Genesis 1:1-5 | 1154 | 1541 | 0.77 s | 141.8 | 172 | 4/4 |
| Genesis 3:14-15 | 1497 | 1586 | 0.98 s | 139.4 | 141 | 4/4 |
| Genesis 15:6 | 1243 | 1615 | 0.79 s | 140.2 | 97 | 3/4 |
| Exodus 20:1-17 | 2041 | 1581 | 1.34 s | 135.8 | 168 | 4/4 |
| Psalms 22:1-6 | 1258 | 1595 | 0.82 s | 140.0 | 116 | 3/4 |
| Psalms 118:1-8 | 1543 | 1565 | 1.01 s | 139.0 | 165 | 4/4 |
| Job 38:1-7 | 1254 | 1592 | 0.82 s | 139.9 | 156 | 4/4 |
| Isaias 7:14 | 1340 | 1609 | 0.87 s | 139.8 | 164 | 4/4 |
| Wisdom 2:12-20 | 1531 | 1584 | 1.00 s | 138.8 | 148 | 4/4 |
| Daniel 13:1-9 | 1429 | 1548 | 0.95 s | 139.4 | 112 | 4/4 |
| Matthew 16:13-19 | 2551 | 1379 | 1.89 s | 131.5 | 195 | 4/4 |
| John 1:1-5 | 1099 | 1475 | 0.77 s | 140.1 | 127 | 3/4 |
| 1 Machabees 1:1-9 | 1560 | 1448 | 1.11 s | 139.6 | 151 | 4/4 |

**Mean: 1,500 prompt tokens · 1,548 tok/s prefill · 1.01 s to first token · 139 tok/s
decode · 147 words. Peak memory 3.19 GB. A cache hit is 2 ms.**

Against ShakespeareReader's 864–1,418 prompt tokens and 0.74 s TTFT, that is a real
regression and a modest one: the extra 600 tokens are the preface, the argument, the notes
and the cross-reference verse texts, which is precisely the material that makes the
annotation worth reading.

Two of the plan's three latency mitigations are implemented: `ABOUT THIS BOOK` is
truncated to two sentences, and `CROSS-REFERENCES` is capped at five entries of at most
25 quoted words each.

**The per-chapter prefix cache is not implemented**, and the reason is worth recording
rather than leaving as a to-do. `ChatSession(_:instructions:cache:)` does exist and would
work, but the chapter-invariant blocks live *inside* the user message, and `respond(to:)`
applies the chat template per turn — so there is no token boundary for a cached prefix to
end on. Getting one means either splitting the request into two user turns, which changes
the prompt shape the table above validates and would need re-grading, or dropping below
`ChatSession` to raw token-level prefill. At 1.01 s mean TTFT neither is worth doing
speculatively; the measurement is here so the next person can decide against a number.

Matthew 16:13-19 is the outlier at 2,551 tokens, and it is the block working as designed:
Challoner's note on "Thou art Peter" runs to 343 words and is polemically explicit, which
is exactly the mitigation the dogmatically loaded passages need. Truncating it would spend
the design's strongest asset to save a second.

## The corpus

Parsed from Project Gutenberg ebook 1581 by `tools/build_corpus.py`. Full provenance,
including the source SHA-256 and why this ebook rather than another, is in
[`Resources/Books/NOTICE.md`](Resources/Books/NOTICE.md).

| | |
|---|---|
| books | 73 — the full Catholic canon, deuterocanon inline in canonical order |
| chapters | 1,334 |
| verses | 35,805 |
| Challoner notes | 1,772 |
| chapter arguments | 1,296 |
| book prefaces | 71 |
| Latin incipits | 150 — every psalm |
| JSON on disk | 7.0 MB, against ShakespeareReader's 18 MB of plays |

The parser is **table-driven, not regex-driven**, and that is its most important decision.
A naive all-caps heading rule has real false positives in this text — `JOSEPH.` closes the
Genesis preface, `PREFACE` sits inside Lamentations, `WAS THE WORD.` is a wrapped phrase in
the Johannine prologue — and four of them sit immediately above a book's first chapter
heading, where they would be taken for the heading itself. Requiring 73 known headings in
canonical order turns every one into a no-op.

## Vulgate numbering

This edition numbers the psalms with the Vulgate and names the books with it, and the app
never quietly translates either. Every citation says so: `Genesis 15:6 · Douay-Rheims
(Challoner), Vulgate numbering`.

The two places a reader will actually be caught out get a hint in the find field, rendered
as a secondary row and **never as an auto-redirect**:

- `Ps 23` opens DRB 23, which is a real psalm and almost certainly not the one they meant.
  The hint offers DRB 22, the shepherd psalm.
- `1 Kings` opens the DRB book, which is 1 Samuel — correct for this edition and wrong
  against every expectation. The hint says so and points at 3 Kings 18 for Elias.

Sending them somewhere else silently would be the app deciding which Bible they meant, and
would teach them nothing.

`PsalmNumbering.swift` carries the chapter-level map between the two systems. It is
consulted only by that hint and by the cross-reference importer; the corpus and every
citation the app emits are pure DRB.

## Running it

```bash
xcodebuild -scheme BibleReader -destination 'platform=macOS' build

APP=$(xcodebuild -scheme BibleReader -destination 'platform=macOS' -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

"$APP/Contents/MacOS/BibleReader" --selftest       # model-free, no network, no GPU
"$APP/Contents/MacOS/BibleReader" --metal-check
"$APP/Contents/MacOS/BibleReader" --show-prompt    # assembled prompts + exact token counts
"$APP/Contents/MacOS/BibleReader" --benchmark
"$APP/Contents/MacOS/BibleReader" --benchmark --passage genesis:15:6
```

`--passage` takes `book:chapter:firstVerse-lastVerse`.

Rebuilding the corpus needs nothing installed beyond Python 3:

```bash
python3 tools/build_corpus.py --all --verify              # counts only, writes nothing
python3 tools/build_corpus.py --all --out Resources/Books
python3 tools/build_corpus.py --dump-chapter psalms:118
```

## Keyboard

| | |
|---|---|
| ⌘1 / ⌘2 | show or hide the book list / the commentary |
| ⌘F | find a book or type a reference |
| ⌘A | select the whole chapter |
| ⌘R | regenerate |
| ⌘[ | back, after following a cross-reference |
| ⌘C | copy the passage with its citation |
| ↑ ↓ | move the selection; shift extends; running off the end rolls into the next chapter |
| Esc | clear |

Double-click selects the whole **syntactic period** rather than one verse, which matters
more here than the equivalent did for a speech: Douay-Rheims verses are frequently
mid-sentence. Genesis 15:19-21 is literally *"The Cineans, and Cenezites, the
Cedmonites," / "And the Hethites…" / "And the Amorrhites…"* — three verses, one list.

## Limitations

These are real and none of them is a to-do in disguise.

**`THE TRADITION` is the weakest of the four layers**, and the pane labels it *generated,
unverified* for that reason. It is the one section where the model is the *source* of a
claim rather than a reader of one: there is no curated dataset behind it the way
Challoner's notes stand behind the other three. A 4B model also drifts toward the
Protestant commonplace on exactly the contested passages where this section matters most —
Matthew 16:18, James 2:24, the "she"/"he" of Genesis 3:15 — which is mitigated
structurally rather than rhetorically, by feeding Challoner's own note on those verses and
instructing that it is the authority. The real fix is a checked-in, human-curated
`Resources/Tradition.json` of a few hundred entries keyed by reference range, which would
make this layer retrieve-and-explain like the others.

**Cross-references come from Challoner's own notes only.** That is roughly a hundred
verse-anchored references across the corpus: Catholic, zero licensing risk, and the only
source that touches the deuterocanon at all — but small. The intended second tier is the
Treasury of Scripture Knowledge, and **it is not implemented because its licence is
unresolved.** The 1830s work is unambiguously public domain; a particular digitization of
it may not be, and openbible.info is unreachable from the sandbox this was built in. That
question has to be answered before `tools/build_crossrefs.py` is written, not after.
`crossReferences` in `SelfTest` is already the integrity check that import will need: it
sweeps every reference the app would put in a prompt and resolves it against the corpus.

**Poetry has no line breaks, and this app does not invent any.** Psalms, Job, Proverbs,
Ecclesiastes, Canticle of Canticles, Wisdom, Ecclesiasticus and Lamentations come through
this transcription as wrapped prose, identical in shape to Genesis. Splitting a verse on
its colons to synthesize hemistichs would be a parser inventing a text, and it would be
wrong exactly where a reader would notice. What the app does instead is typography: for a
`.poetry` book it narrows the measure to 480pt, loosens the leading, and insets the verse,
so a psalm reads as a stanza rather than a paragraph without asserting a single break the
source does not have. A true turn-line hanging indent is not reachable either — SwiftUI's
`Text` does not honour an `NSParagraphStyle`'s `headIndent`. Recovering real stichometry
would need an edition that carries it; whether one exists under a compatible licence is
unverified.

**No full-text search.** The find field takes a book name, an abbreviation or a reference.
Searching the text of 35,805 verses is a different mechanism — an index, not a substring
scan over 5 MB — with no ShakespeareReader analogue, and half-building it would be worse
than saying so.

**No deuterocanonical cross-references, ever, from TSK.** Even once that dataset lands it
has zero coverage of Tobias, Judith, Wisdom, Ecclesiasticus, Baruch, 1–2 Machabees or the
Greek additions — which is precisely the part that makes this a Catholic Bible. The app
degrades to Challoner's own references there, and `wisdom:2:12-20` is in the benchmark set
to keep that path measured.

**OCR typos in the transcription reach the reader and the prompt.** Recording the source
SHA-256 is the mitigation; correcting the text is not this project's business. Ebook 1581
is a live file, and a re-fetch that changes it changes every book's `source.textSHA256`,
which invalidates cached annotations and stored reading positions rather than silently
mismatching them.

## Self test

`--selftest` runs model-free and covers the two things that break silently — a corpus that
decodes but is subtly wrong, and prompt drift.

| suite | what it pins |
|---|---|
| `corpus` | 73 / 1,334 / 35,805 as literal regression targets, per-book chapter counts, the nine divisions, 1,772 notes, 1,296 arguments, Psalm 9's `9a` labels, Psalm 118's stanza headings |
| `psalmNumbering` | DRB 22 ↔ Hebrew 23, DRB 9 spanning Hebrew 9–10, `nil` where undefined, and a round trip over all 150 |
| `references` | the parser's shapes and aliases, both disambiguation hints, garbage, and a round trip over all 73 book names |
| `navigator` | the two-level accordion and the find field's sum type |
| `selection` | the period rule, against Genesis 15:19-21 |
| `readerFonts`, `readerTextSizes` | the size ladder, and that Default is byte-for-byte the unset rendering |
| `wordTokenizer` | that word ranges tile every row of Genesis, Psalms and John |
| `quoteCheck` | the apostrophe fold, pooled quote marks, the length floor |
| `sectionParsing` | well-formed, missing, reordered, bolded, partial, repeated, and empty-label runs |
| `referenceCheck` | all three verdicts, Protestant aliases, and the quoted-verse haystack |
| `patristicCheck` | the generic/specific line, drawn on the same Father in the same sentence |
| `crossReferences` | **every** reference the app would put in a prompt, swept across the whole corpus |
| `followUpParsing` | every way the model breaks "four numbered lines and nothing else" |
| `goldenPromptRender` | one assembled prompt, byte for byte — **regenerate on every `Prompts.version` bump** |

The golden render uses Genesis 14:10 rather than the app's canonical Genesis 15:6, and
deliberately: 15:6 is too clean, carrying neither a note nor a Challoner reference, so two
of the seven blocks would be missing and drift in them would go unnoticed. 14:10 exercises
all of them, and its catchword is `Of slime. Bituminis` — the case the parser's dot-run
anchoring exists for.
