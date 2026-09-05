# Corpus provenance

The 73 book files in this directory are parsed from a single Project Gutenberg
transcription by `tools/build_corpus.py`. Every JSON file records its own `source`
block with the ebook ID, the URL, the retrieval date, and the SHA-256 of the source
text as downloaded, so any file here can be traced back to an exact input.

| | |
|---|---|
| edition | Douay-Rheims, Challoner revision |
| ebook | 1581 — *The Bible, Douay-Rheims, Complete* |
| source | https://www.gutenberg.org/ebooks/1581 |
| text | https://www.gutenberg.org/cache/epub/1581/pg1581.txt |
| retrieved | 2026-09-05 |
| SHA-256 | `7d10da78d8ec97db53b4e2bd8719cc01e16106b44937a673ba34aa534a04c007` |

## Why ebook 1581 and not another

One ebook, one transcription lineage — the direct analogue of ShakespeareReader's
"1500-1542 series only" decision, and for the same reason: a single lineage is what
makes one set of patterns viable.

1581 is chosen over the alternatives deliberately. Its own header calls it an improved
and more complete edition than #8300, and it is better corrected than the per-book
series #8301–8373, which carries typos 1581 fixes — that series has "And god made a
firmament" at Genesis 1:7. Swapping in another transcription means re-tuning `PATTERNS`
and re-checking `BOOKS`, not editing a URL.

The Douay-Rheims is in the public domain. This transcription comes from Project
Gutenberg and carries no additional copyright in the United States. The PG header and
license footer are stripped during the parse, so no part of the PG license text is
redistributed here — only the Bible.

## What is in the corpus

| | |
|---|---|
| books | 73 — the full Catholic canon, deuterocanon inline in canonical order |
| chapters | 1,334 |
| verses | 35,805 |
| Challoner book prefaces | 71 |
| Challoner chapter arguments | 1,296 (38 chapters have none) |
| Challoner annotations | 1,772 (17 of them with no catchword) |
| Latin incipits | 150 — every psalm |
| section headings | 61 |
| unclassified paragraphs | 0 |

**The most important fact about this edition: it ships with its own commentary.** A
Challoner introduction per book, an argument per chapter, and 1,772 verse-anchored
interpretive notes — public domain, Catholic, already in the corpus. That is what lets
the annotation layer explain material it was handed rather than recall material it was
not.

## What is cut, and why

Everything below the `APPENDICES` marker. That is the 1610 back matter — the Prayer of
Manasses, 3 and 4 Esdras, the Douay Preface, and `HARD VVORDES EXPLICATED`. It is not
canon, it is set in 1610 orthography, and it does not parse under these rules: 3 Esdras
in particular has chapter headings and numbered verses that would file themselves under
whatever book happened to be open. The parser asserts the marker exists rather than
tolerating its absence, because a transcription that dropped it would silently append
several thousand lines of apocrypha to the Apocalypse.

## Numbering

**Vulgate numbering throughout, and every citation the app emits says so.** DRB Psalms
are offset from Hebrew/Protestant numbering for most of the psalter: DRB 22 is Hebrew
23, the shepherd psalm. Book names differ too — 1–2 Kings are 1–2 Samuel, 3–4 Kings are
1–2 Kings, Paralipomenon is Chronicles, Ecclesiasticus is Sirach, Apocalypse is
Revelation. `PsalmNumbering.swift` carries a chapter-level map between the two, used
only for navigator hints and for importing cross-references; the corpus itself is pure
DRB.

Two structural details of this transcription are worth recording, because both are
places a naive scan loses scripture:

**Psalm 9 is where the Vulgate numbering becomes visible in the text.** DRB Psalm 9
spans Hebrew Psalms 9 and 10, and this transcription prints the second half under the
rubric `Psalm 10 according to the Hebrews.` with its verses restarting at `9a:1`. Those
18 verses are the only sub-lettered labels in the file. They are kept with their printed
labels rather than renumbered to 9:22–39, so the gutter and the citation both say what
the edition says.

**Seven verses lost the space after their number** in transcription (`19:18.They passed
the fords`). They are ordinary verses with a typo, and the parser accepts them.

Together those two account for the whole difference between the 35,805 verses here and
the 35,780 a naive `^\d+:\d+\. ` scan reports.

## Known limitations

**No stichic line breaks.** Psalms, Job, Proverbs, Canticle of Canticles and
Lamentations come through as wrapped prose, identical in shape to Genesis. Poetry layout
is not recoverable from this source, and the reader does not fake it — it marks those
books `genre: poetry` and narrows the measure, loosens the leading and hangs
continuation lines, which is typography rather than invented structure. Recovering real
stichometry would need an edition that carries it; whether one exists under a compatible
licence is unverified.

**Esther's Greek additions are inline at 10:4–16:24, and Daniel has 14 chapters** with
3:24–90 inline. Neither needs special-casing; they parse as ordinary chapters, which is
why the chapter grid shows Daniel with 14.

**`deuterocanonical` is a book-level flag** and so cannot say "partly". Esther and Daniel
are marked `false` even though both carry deuterocanonical sections, because the flag is
what the navigator's dagger annotates and the book as a whole is protocanonical.

**OCR typos in the transcription will occasionally reach the reader and the prompt.**
Recording the source SHA-256 is the mitigation; correcting the text is not our business.
Ebook 1581 is a live file, and a re-fetch that changes the text changes every book's
`source.textSHA256`, which invalidates cached annotations and stored reading positions
rather than silently mismatching them.
