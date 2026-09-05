#!/usr/bin/env python3
"""Fetch the Douay-Rheims from Project Gutenberg and parse it into the reader's JSON.

Python standard library only, matching the precedent in the repo's own tools/ and in
ShakespeareReader's build_corpus.py, so anyone with network access can run this with
no install step.

    python3 tools/build_corpus.py --all --verify              # stats only, writes nothing
    python3 tools/build_corpus.py --all --out Resources/Books
    python3 tools/build_corpus.py --from-file /tmp/pg1581.txt --all --out Resources/Books
    python3 tools/build_corpus.py --book psalms --verify
    python3 tools/build_corpus.py --dump-chapter psalms:118

The generated JSON is checked in, so the app builds and runs with no network. This
script exists to make the parse reproducible and auditable, not as a build step.

ONE SOURCE, ONE LINEAGE
-----------------------
Ebook 1581, "The Bible, Douay-Rheims, Complete". This is the direct analogue of
ShakespeareReader's "1500-1542 series only" decision, and for the same reason: a single
transcription lineage is what makes one set of patterns viable.

1581 is chosen over the alternatives deliberately. Its own header calls it an improved
and more complete edition than #8300, and it is better corrected than the per-book
series #8301-8373, which carries typos 1581 fixes (that series has "And god made a
firmament" at Genesis 1:7). Swapping in another transcription means re-tuning
PATTERNS and re-checking BOOKS, not editing a URL.
"""

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import timezone, datetime

PARSER_VERSION = 1
SCHEMA_VERSION = 1

EBOOK_ID = 1581
TEXT_URL = f"https://www.gutenberg.org/cache/epub/{EBOOK_ID}/pg{EBOOK_ID}.txt"
EBOOK_URL = f"https://www.gutenberg.org/ebooks/{EBOOK_ID}"

# Every pattern lives here so re-tuning against a new transcription is one place.
# Grounded in the real file rather than guessed at; the comments record what each
# pattern had to survive.
PATTERNS = {
    # Project Gutenberg wraps the work in these. Everything outside is boilerplate and
    # license text.
    "pg_start": re.compile(r"^\*\*\* START OF THE PROJECT GUTENBERG EBOOK"),
    "pg_end": re.compile(r"^\*\*\* END OF THE PROJECT GUTENBERG EBOOK"),
    # A hard stop, and the single most important pattern here after `chapter`.
    #
    # Everything below this marker is the 1610 back matter: the Prayer of Manasses, 3
    # and 4 Esdras, the Douay Preface, and `HARD VVORDES EXPLICATED`. It is not canon,
    # it is set in 1610 orthography, and it does not parse under these rules -- 3
    # Esdras in particular has chapter headings and numbered verses that would file
    # themselves under whatever book happened to be open. `parse_bible` asserts the
    # marker exists rather than tolerating its absence, because a transcription that
    # dropped it would silently append several thousand lines of apocrypha to the
    # Apocalypse.
    "appendices": re.compile(r"^APPENDICES$"),
    # 1,334 hits, which is exactly the Catholic chapter count. `book` is checked
    # against the open book's short name, so a heading that belongs to a book the scan
    # has not reached is an error rather than a silent mis-file.
    "chapter": re.compile(r"^(?P<book>[1-4]? ?[A-Z][A-Za-z ]*) Chapter (?P<n>\d+)$"),
    # 35,780 hits. `c` is checked against the open chapter, which catches a missed
    # chapter heading on the very next verse instead of at the end of the book.
    #
    # Two irregularities are tolerated here rather than left to fail, because both are
    # in the real file and both would drop scripture:
    #
    # `sub` is the lower-case suffix in `9a:1`. Psalm 9 is the one place the Vulgate
    # numbering becomes visible in the text itself: DRB Psalm 9 spans Hebrew Psalms 9
    # and 10, and this transcription prints the second half under the rubric `Psalm 10
    # according to the Hebrews.` with its verses restarting at `9a:1`. Those 18 verses
    # are the only sub-lettered labels in the file, and rejecting them would silently
    # lose them.
    #
    # `\.\s?` rather than `\. ` is for the seven verses across the file whose space
    # after the number was lost in transcription (`19:18.They passed the fords`). They
    # are ordinary verses with a typo, not a different kind of thing.
    "verse": re.compile(
        r"^(?P<c>\d+)(?P<sub>[a-z]?):(?P<v>\d+)\.\s?(?P<text>.*)$"),

    # A Challoner annotation, attached to the verse above it.
    #
    # Anchored on the dot run and NOT on the absence of dots in the catchword, which is
    # the whole subtlety: `Of slime. Bituminis.... Or bitumen...` is real, and a pattern
    # that required a dot-free catchword would take the wrong half of it. The catchword
    # group is non-greedy so it stops at the *first* run of three or more dots, which is
    # what makes that case come out right.
    #
    # The bound of 80 characters is what keeps this off a verse of ordinary prose that
    # happens to contain an ellipsis.
    #
    # Note this pattern only *extracts a catchword*; it does not decide what a note is.
    # Roughly 30 notes in the file carry no ellipsis at all -- `The Lord. That is, an
    # angel speaking in the name of the Lord.` at Job 38:1, `Thou shalt not take, etc.
    # This was to shew them...` at Deuteronomy 22:6 -- and those are notes just the
    # same. `parse_chapter` classifies by position and uses this only for the catchword.
    "note": re.compile(r"^(?P<catchword>.{1,80}?)\.\.\.\.? (?P<text>.*)$"),
}

# A Latin incipit, e.g. `Beati immaculati.` Psalms only -- see `split_front_matter`.
#
# Deliberately not a general "short paragraph" rule. Every psalm's first paragraph is
# its incipit and its second is Challoner's argument, and the two are shape-identical
# in the general case: `Alleluia.` is a section heading, `Beatus vir.` is an incipit,
# and nothing about either says which. Special-casing the one book where the slot
# exists is what keeps the other 72 from acquiring a phantom `latinIncipit`.
INCIPIT_MAX = 60

# Testament, division and genre are editorial classifications rather than anything the
# transcription says, so they live here where they can be read and argued with.
OLD, NEW = "old", "new"

# The nine navigator groups. Two testament rows expanding to 46 and 27 books is not
# navigation; these are.
PENTATEUCH = "pentateuch"
HISTORICAL = "historical"
WISDOM = "wisdom"
PROPHETS = "prophets"
GOSPELS = "gospels"
ACTS = "acts"
PAULINE = "pauline"
CATHOLIC = "catholic"
APOCALYPSE = "apocalypse"

NARRATIVE, LAW, POETRY, PROPHECY, EPISTLE = (
    "narrative",
    "law",
    "poetry",
    "prophecy",
    "epistle",
)

# The 73 books, in the order the file prints them, which is canonical order.
#
# THE SCAN IS TABLE-DRIVEN, NOT REGEX-DRIVEN, AND THIS TABLE IS WHY.
#
# A naive `^[A-Z ]+$` book-heading regex has real false positives in this text. Every
# one of these is an actual all-caps line in the body:
#
#     JOSEPH.                             (last word of the Genesis preface)
#     BE BLESSED.                         (a wrapped emphatic phrase, Genesis)
#     ALEPH. ... TAU.                     (the 22 stanza headings of Psalm 118)
#     THE PARABLES OF SOLOMON             (a section heading inside Proverbs)
#     THE PROLOGUE.                       (inside Ecclesiasticus)
#     PREFACE                             (inside Lamentations)
#     THE PRAYER OF JEREMIAS THE PROPHET  (Lamentations 5's own heading)
#     SHALL COMPASS A MAN.                (wrapped emphatic phrase, Jeremias)
#     SERVANT THE ORIENT.                 (wrapped emphatic phrase, Zacharias)
#     KING OF THE JEWS. / THE JEWS.       (wrapped, Matthew and Mark)
#     WAS THE WORD.                       (wrapped, the Johannine prologue)
#     KINGS AND LORD OF LORDS.            (wrapped, Apocalypse)
#
# Four of those sit immediately above a book's first chapter heading and would be taken
# for the heading itself: JOSEPH. for Genesis, THE PROLOGUE. for Ecclesiasticus,
# PREFACE for Lamentations, WAS THE WORD. for John. Requiring the 73 known headings in
# canonical order turns every one of these from a silent mis-parse into a no-op.
#
# Columns: id, heading, shortName, testament, division, deuterocanonical, genre, abbreviations.
#
# `shortName` is what the chapter headings use (`Exodus Chapter 1`) and is checked
# against them. `id` is the JSON filename and the stable identifier in ReadingProgress
# and the annotation cache, so it must not be renamed casually.
#
# `deuterocanonical` marks the seven books absent from the Protestant canon. Esther and
# Daniel are marked False even though both carry deuterocanonical *sections* inline
# (Esther 10:4-16:24, Daniel 3:24-90 and 13-14): the flag describes the book as a whole,
# which is what the navigator's dagger annotates, and a book-level flag cannot say
# "partly". The chapter grid is where a reader sees Daniel has 14 chapters.
#
# `abbreviations` ships Protestant and common-English names as aliases, because nobody
# types "Paralipomenon". They feed ReferenceParser, not the UI.
BOOKS = [
    ("genesis", "THE BOOK OF GENESIS", "Genesis", OLD, PENTATEUCH, False, NARRATIVE,
     ["Gen", "Gn", "Ge"]),
    ("exodus", "THE BOOK OF EXODUS", "Exodus", OLD, PENTATEUCH, False, NARRATIVE,
     ["Ex", "Exo", "Exod"]),
    ("leviticus", "THE BOOK OF LEVITICUS", "Leviticus", OLD, PENTATEUCH, False, LAW,
     ["Lev", "Lv"]),
    ("numbers", "THE BOOK OF NUMBERS", "Numbers", OLD, PENTATEUCH, False, NARRATIVE,
     ["Num", "Nm", "Nb"]),
    ("deuteronomy", "THE BOOK OF DEUTERONOMY", "Deuteronomy", OLD, PENTATEUCH, False,
     LAW, ["Deut", "Dt", "Deu"]),
    ("josue", "THE BOOK OF JOSUE", "Josue", OLD, HISTORICAL, False, NARRATIVE,
     ["Jos", "Josh", "Joshua"]),
    ("judges", "THE BOOK OF JUDGES", "Judges", OLD, HISTORICAL, False, NARRATIVE,
     ["Judg", "Jdg", "Jgs"]),
    ("ruth", "THE BOOK OF RUTH", "Ruth", OLD, HISTORICAL, False, NARRATIVE,
     ["Ruth", "Rth", "Ru"]),
    # The heading discloses the dual naming itself, which is convenient: a reader who
    # types `1 Samuel` lands here and sees a title that says so.
    ("1-kings", "THE FIRST BOOK OF SAMUEL, OTHERWISE CALLED THE FIRST BOOK OF KINGS",
     "1 Kings", OLD, HISTORICAL, False, NARRATIVE,
     ["1 Kgs", "1 Kg", "1 Sam", "1 Sm", "1 Samuel", "1Sa", "I Kings", "I Samuel"]),
    ("2-kings", "THE SECOND BOOK OF SAMUEL, OTHERWISE CALLED THE SECOND BOOK OF KINGS",
     "2 Kings", OLD, HISTORICAL, False, NARRATIVE,
     ["2 Kgs", "2 Kg", "2 Sam", "2 Sm", "2 Samuel", "2Sa", "II Kings", "II Samuel"]),
    ("3-kings", "THE THIRD BOOK OF KINGS", "3 Kings", OLD, HISTORICAL, False, NARRATIVE,
     ["3 Kgs", "3 Kg", "1 Kings (Hebrew)", "III Kings"]),
    ("4-kings", "THE FOURTH BOOK OF KINGS", "4 Kings", OLD, HISTORICAL, False,
     NARRATIVE, ["4 Kgs", "4 Kg", "2 Kings (Hebrew)", "IV Kings"]),
    ("1-paralipomenon", "THE FIRST BOOK OF PARALIPOMENON", "1 Paralipomenon", OLD,
     HISTORICAL, False, NARRATIVE,
     ["1 Par", "1 Chr", "1 Chron", "1 Chronicles", "I Paralipomenon"]),
    ("2-paralipomenon", "THE SECOND BOOK OF PARALIPOMENON", "2 Paralipomenon", OLD,
     HISTORICAL, False, NARRATIVE,
     ["2 Par", "2 Chr", "2 Chron", "2 Chronicles", "II Paralipomenon"]),
    ("1-esdras", "THE FIRST BOOK OF ESDRAS", "1 Esdras", OLD, HISTORICAL, False,
     NARRATIVE, ["1 Esd", "Esd", "Ezra", "Ezr", "Esdras"]),
    ("2-esdras", "THE BOOK OF NEHEMIAS, WHICH IS CALLED THE SECOND OF ESDRAS",
     "2 Esdras", OLD, HISTORICAL, False, NARRATIVE,
     ["2 Esd", "Neh", "Nehemias", "Nehemiah", "Ne"]),
    ("tobias", "THE BOOK OF TOBIAS", "Tobias", OLD, HISTORICAL, True, NARRATIVE,
     ["Tob", "Tb", "Tobit"]),
    ("judith", "THE BOOK OF JUDITH", "Judith", OLD, HISTORICAL, True, NARRATIVE,
     ["Jdt", "Jth", "Judt"]),
    ("esther", "THE BOOK OF ESTHER", "Esther", OLD, HISTORICAL, False, NARRATIVE,
     ["Est", "Esth", "Es"]),
    ("job", "THE BOOK OF JOB", "Job", OLD, WISDOM, False, POETRY, ["Job", "Jb"]),
    ("psalms", "THE BOOK OF PSALMS", "Psalms", OLD, WISDOM, False, POETRY,
     ["Ps", "Psa", "Psalm", "Pss"]),
    ("proverbs", "THE BOOK OF PROVERBS", "Proverbs", OLD, WISDOM, False, POETRY,
     ["Prov", "Prv", "Pr"]),
    ("ecclesiastes", "ECCLESIASTES", "Ecclesiastes", OLD, WISDOM, False, POETRY,
     ["Eccl", "Eccles", "Qoh", "Qoheleth", "Ec"]),
    ("canticle-of-canticles", "SOLOMON’S CANTICLE OF CANTICLES",
     "Canticle of Canticles", OLD, WISDOM, False, POETRY,
     ["Cant", "Song", "Song of Songs", "Song of Solomon", "SS", "Sg"]),
    ("wisdom", "THE BOOK OF WISDOM", "Wisdom", OLD, WISDOM, True, POETRY,
     ["Wis", "Ws", "Wisd"]),
    ("ecclesiasticus", "ECCLESIASTICUS", "Ecclesiasticus", OLD, WISDOM, True, POETRY,
     ["Sir", "Sirach", "Ecclus", "Eccli"]),
    ("isaias", "THE PROPHECY OF ISAIAS", "Isaias", OLD, PROPHETS, False, PROPHECY,
     ["Isa", "Is", "Isaiah"]),
    ("jeremias", "THE PROPHECY OF JEREMIAS", "Jeremias", OLD, PROPHETS, False, PROPHECY,
     ["Jer", "Jr", "Jeremiah"]),
    ("lamentations", "THE LAMENTATIONS OF JEREMIAS", "Lamentations", OLD, PROPHETS,
     False, POETRY, ["Lam", "Lm"]),
    ("baruch", "THE PROPHECY OF BARUCH", "Baruch", OLD, PROPHETS, True, PROPHECY,
     ["Bar", "Ba"]),
    ("ezechiel", "THE PROPHECY OF EZECHIEL", "Ezechiel", OLD, PROPHETS, False, PROPHECY,
     ["Ezech", "Ezek", "Eze", "Ezekiel"]),
    ("daniel", "THE PROPHECY OF DANIEL", "Daniel", OLD, PROPHETS, False, PROPHECY,
     ["Dan", "Dn", "Da"]),
    ("osee", "THE PROPHECY OF OSEE", "Osee", OLD, PROPHETS, False, PROPHECY,
     ["Os", "Hos", "Hosea"]),
    ("joel", "THE PROPHECY OF JOEL", "Joel", OLD, PROPHETS, False, PROPHECY,
     ["Joel", "Jl", "Joe"]),
    ("amos", "THE PROPHECY OF AMOS", "Amos", OLD, PROPHETS, False, PROPHECY,
     ["Am", "Amo"]),
    ("abdias", "THE PROPHECY OF ABDIAS", "Abdias", OLD, PROPHETS, False, PROPHECY,
     ["Abd", "Obad", "Ob", "Obadiah"]),
    ("jonas", "THE PROPHECY OF JONAS", "Jonas", OLD, PROPHETS, False, PROPHECY,
     ["Jon", "Jonah", "Jnh"]),
    ("micheas", "THE PROPHECY OF MICHEAS", "Micheas", OLD, PROPHETS, False, PROPHECY,
     ["Mic", "Mi", "Micah"]),
    ("nahum", "THE PROPHECY OF NAHUM", "Nahum", OLD, PROPHETS, False, PROPHECY,
     ["Nah", "Na"]),
    ("habacuc", "THE PROPHECY OF HABACUC", "Habacuc", OLD, PROPHETS, False, PROPHECY,
     ["Hab", "Hb", "Habakkuk"]),
    ("sophonias", "THE PROPHECY OF SOPHONIAS", "Sophonias", OLD, PROPHETS, False,
     PROPHECY, ["Soph", "Zeph", "Zep", "Zephaniah"]),
    ("aggeus", "THE PROPHECY OF AGGEUS", "Aggeus", OLD, PROPHETS, False, PROPHECY,
     ["Agg", "Hag", "Hg", "Haggai"]),
    ("zacharias", "THE PROPHECY OF ZACHARIAS", "Zacharias", OLD, PROPHETS, False,
     PROPHECY, ["Zach", "Zech", "Zec", "Zechariah"]),
    ("malachias", "THE PROPHECY OF MALACHIAS", "Malachias", OLD, PROPHETS, False,
     PROPHECY, ["Mal", "Ml", "Malachi"]),
    # Filed under Historical even though the file prints them after Malachias, which is
    # where Catholic Bibles put them. `canonicalIndex` keeps the file's order, so the
    # navigator lists them last within the division and the reading order is unchanged.
    ("1-machabees", "THE FIRST BOOK OF MACHABEES", "1 Machabees", OLD, HISTORICAL, True,
     NARRATIVE, ["1 Mac", "1 Macc", "1 Mach", "1 Maccabees", "I Machabees"]),
    ("2-machabees", "THE SECOND BOOK OF MACHABEES", "2 Machabees", OLD, HISTORICAL,
     True, NARRATIVE, ["2 Mac", "2 Macc", "2 Mach", "2 Maccabees", "II Machabees"]),
    ("matthew", "THE HOLY GOSPEL OF JESUS CHRIST ACCORDING TO SAINT MATTHEW", "Matthew",
     NEW, GOSPELS, False, NARRATIVE, ["Mt", "Matt", "Mat"]),
    ("mark", "THE HOLY GOSPEL OF JESUS CHRIST ACCORDING TO ST. MARK", "Mark", NEW,
     GOSPELS, False, NARRATIVE, ["Mk", "Mrk", "Mar"]),
    ("luke", "THE HOLY GOSPEL OF JESUS CHRIST ACCORDING TO ST. LUKE", "Luke", NEW,
     GOSPELS, False, NARRATIVE, ["Lk", "Luk", "Lu"]),
    ("john", "THE HOLY GOSPEL OF JESUS CHRIST ACCORDING TO ST. JOHN", "John", NEW,
     GOSPELS, False, NARRATIVE, ["Jn", "Joh", "Jhn"]),
    ("acts", "THE ACTS OF THE APOSTLES", "Acts", NEW, ACTS, False, NARRATIVE,
     ["Ac", "Act", "Acts of the Apostles"]),
    ("romans", "THE EPISTLE OF ST. PAUL THE APOSTLE TO THE ROMANS", "Romans", NEW,
     PAULINE, False, EPISTLE, ["Rom", "Rm", "Ro"]),
    ("1-corinthians", "THE FIRST EPISTLE OF ST. PAUL TO THE CORINTHIANS",
     "1 Corinthians", NEW, PAULINE, False, EPISTLE, ["1 Cor", "1 Co", "I Corinthians"]),
    ("2-corinthians", "THE SECOND EPISTLE OF ST. PAUL TO THE CORINTHIANS",
     "2 Corinthians", NEW, PAULINE, False, EPISTLE,
     ["2 Cor", "2 Co", "II Corinthians"]),
    ("galatians", "THE EPISTLE OF ST. PAUL TO THE GALATIANS", "Galatians", NEW, PAULINE,
     False, EPISTLE, ["Gal", "Ga"]),
    ("ephesians", "THE EPISTLE OF ST. PAUL TO THE EPHESIANS", "Ephesians", NEW, PAULINE,
     False, EPISTLE, ["Eph", "Ep"]),
    ("philippians", "THE EPISTLE OF ST. PAUL TO THE PHILIPPIANS", "Philippians", NEW,
     PAULINE, False, EPISTLE, ["Phil", "Php", "Pp"]),
    ("colossians", "THE EPISTLE OF ST. PAUL TO THE COLOSSIANS", "Colossians", NEW,
     PAULINE, False, EPISTLE, ["Col", "Co"]),
    ("1-thessalonians", "THE FIRST EPISTLE OF ST. PAUL TO THE THESSALONIANS",
     "1 Thessalonians", NEW, PAULINE, False, EPISTLE,
     ["1 Thess", "1 Th", "I Thessalonians"]),
    ("2-thessalonians", "THE SECOND EPISTLE OF ST. PAUL TO THE THESSALONIANS",
     "2 Thessalonians", NEW, PAULINE, False, EPISTLE,
     ["2 Thess", "2 Th", "II Thessalonians"]),
    ("1-timothy", "THE FIRST EPISTLE OF ST. PAUL TO TIMOTHY", "1 Timothy", NEW, PAULINE,
     False, EPISTLE, ["1 Tim", "1 Ti", "I Timothy"]),
    ("2-timothy", "THE SECOND EPISTLE OF ST. PAUL TO TIMOTHY", "2 Timothy", NEW,
     PAULINE, False, EPISTLE, ["2 Tim", "2 Ti", "II Timothy"]),
    ("titus", "THE EPISTLE OF ST. PAUL TO TITUS", "Titus", NEW, PAULINE, False, EPISTLE,
     ["Tit", "Ti"]),
    ("philemon", "THE EPISTLE OF ST. PAUL TO PHILEMON", "Philemon", NEW, PAULINE, False,
     EPISTLE, ["Philem", "Phm", "Phlm"]),
    ("hebrews", "THE EPISTLE OF ST. PAUL TO THE HEBREWS", "Hebrews", NEW, PAULINE,
     False, EPISTLE, ["Heb", "Hbr"]),
    ("james", "THE CATHOLIC EPISTLE OF ST. JAMES THE APOSTLE", "James", NEW, CATHOLIC,
     False, EPISTLE, ["Jas", "Jm", "Jam"]),
    ("1-peter", "THE FIRST EPISTLE OF ST. PETER THE APOSTLE", "1 Peter", NEW, CATHOLIC,
     False, EPISTLE, ["1 Pet", "1 Pt", "1 Pe", "I Peter"]),
    ("2-peter", "THE SECOND EPISTLE OF ST. PETER THE APOSTLE", "2 Peter", NEW, CATHOLIC,
     False, EPISTLE, ["2 Pet", "2 Pt", "2 Pe", "II Peter"]),
    ("1-john", "THE FIRST EPISTLE OF ST. JOHN THE APOSTLE", "1 John", NEW, CATHOLIC,
     False, EPISTLE, ["1 Jn", "1 Jo", "I John"]),
    ("2-john", "THE SECOND EPISTLE OF ST. JOHN THE APOSTLE", "2 John", NEW, CATHOLIC,
     False, EPISTLE, ["2 Jn", "2 Jo", "II John"]),
    ("3-john", "THE THIRD EPISTLE OF ST. JOHN THE APOSTLE", "3 John", NEW, CATHOLIC,
     False, EPISTLE, ["3 Jn", "3 Jo", "III John"]),
    ("jude", "THE CATHOLIC EPISTLE OF ST. JUDE", "Jude", NEW, CATHOLIC, False, EPISTLE,
     ["Jud", "Jde"]),
    ("apocalypse", "THE APOCALYPSE OF ST. JOHN THE APOSTLE", "Apocalypse", NEW,
     APOCALYPSE, False, PROPHECY,
     ["Apoc", "Rev", "Rv", "Revelation", "Revelations"]),
]

# The chapter count each book must produce. Not derived from the parse -- that would
# make the check vacuous -- but the Catholic canon's own numbers, so a book that comes
# up short fails loudly at the point of the miss.
EXPECTED_CHAPTERS = {
    "genesis": 50, "exodus": 40, "leviticus": 27, "numbers": 36, "deuteronomy": 34,
    "josue": 24, "judges": 21, "ruth": 4, "1-kings": 31, "2-kings": 24, "3-kings": 22,
    "4-kings": 25, "1-paralipomenon": 29, "2-paralipomenon": 36, "1-esdras": 10,
    "2-esdras": 13, "tobias": 14, "judith": 16, "esther": 16, "job": 42, "psalms": 150,
    "proverbs": 31, "ecclesiastes": 12, "canticle-of-canticles": 8, "wisdom": 19,
    "ecclesiasticus": 51, "isaias": 66, "jeremias": 52, "lamentations": 5, "baruch": 6,
    "ezechiel": 48, "daniel": 14, "osee": 14, "joel": 3, "amos": 9, "abdias": 1,
    "jonas": 4, "micheas": 7, "nahum": 3, "habacuc": 3, "sophonias": 3, "aggeus": 2,
    "zacharias": 14, "malachias": 4, "1-machabees": 16, "2-machabees": 15,
    "matthew": 28, "mark": 16, "luke": 24, "john": 21, "acts": 28, "romans": 16,
    "1-corinthians": 16, "2-corinthians": 13, "galatians": 6, "ephesians": 6,
    "philippians": 4, "colossians": 4, "1-thessalonians": 5, "2-thessalonians": 3,
    "1-timothy": 6, "2-timothy": 4, "titus": 3, "philemon": 1, "hebrews": 13,
    "james": 5, "1-peter": 5, "2-peter": 3, "1-john": 5, "2-john": 1, "3-john": 1,
    "jude": 1, "apocalypse": 22,
}

TOTAL_CHAPTERS = 1334
# 35,805 rather than the 35,780 a naive `^\d+:\d+\. ` scan reports. The difference is
# exactly the 25 verses such a scan cannot see: the 18 of Psalm 9's Hebrew-10 half,
# labelled `9a:1` through `9a:18`, and the 7 across the file whose space after the verse
# number was lost in transcription. Both are ordinary scripture, and the larger number
# is the correct one.
TOTAL_VERSES = 35805


def split_lines(text):
    """Split on any line terminator.

    The file is CRLF throughout. This is the one detail that silently breaks every
    `$`-anchored pattern, so it is handled once here rather than in every pattern.
    """
    return re.split(r"\r\n|\r|\n", text)


def paragraphs(lines):
    """Blank-line-delimited paragraphs, with intra-paragraph wrapping undone.

    The transcription hard-wraps at about 72 columns and separates every unit -- verse,
    note, heading, argument -- with a blank line. That makes the paragraph the natural
    record, and unwrapping here is what lets every pattern below be anchored with `^`
    and `$` against a whole unit rather than against its first physical line.
    """
    result = []
    current = []
    for line in lines:
        stripped = line.strip()
        if stripped:
            current.append(stripped)
        elif current:
            result.append(" ".join(current))
            current = []
    if current:
        result.append(" ".join(current))
    return result


class ParseStats:
    def __init__(self):
        self.verses = 0
        self.notes = 0
        self.uncued_notes = 0
        self.sections = 0
        self.arguments = 0
        self.incipits = 0
        self.prefaces = 0
        self.unclassified = []


def is_note(paragraph):
    return PATTERNS["note"].match(paragraph) is not None


def body_row(paragraph, stats):
    """Classify one non-verse paragraph from inside a chapter.

    Shared by the body walk and by the tail of the front matter, so Psalm 118 -- whose
    argument is followed by `Alleluia.`, `ALEPH.` and then a long note, all before verse
    1 -- classifies those three the same way it would if they sat further down.
    """
    # `ALEPH.` through `TAU.` in Psalm 118, `THE PARABLES OF SOLOMON` in Proverbs,
    # `Alleluia.`, `A gradual canticle.`, and `Psalm 10 according to the Hebrews.` in
    # Psalm 9 are the whole population, and all are short.
    if len(paragraph) <= 60 and not is_note(paragraph):
        stats.sections += 1
        return {"kind": "sectionHeading", "text": paragraph}

    note = PATTERNS["note"].match(paragraph)
    stats.notes += 1
    if note is None:
        stats.uncued_notes += 1
    return {
        "kind": "note",
        "text": note.group("text") if note else paragraph,
        "catchword": note.group("catchword") if note else None,
    }


def split_front_matter(book_id, block):
    """Split a chapter's pre-first-verse paragraphs into incipit, argument and the rest.

    The order is fixed across the whole file: incipit (Psalms only), then Challoner's
    argument, then anything the chapter opens with before its first verse -- Psalm 118
    has `Alleluia.`, `ALEPH.` and a long note there; Psalm 131 has `A gradual canticle.`

    Every psalm has an incipit, and asserting that is what caught the two where the
    transcription lost the blank line between the incipit and the argument and ran them
    into one paragraph (`Confitebor tibi, Domine. The church praiseth God for his
    protection...`, Psalms 9 and 56). Those are split at the incipit's own period rather
    than left to file a Latin phrase as the opening of Challoner's English summary.
    """
    incipit = None
    argument = None
    rest = list(block)

    if book_id == "psalms" and rest:
        head = rest[0]
        if len(head) <= INCIPIT_MAX:
            incipit = rest.pop(0)
        else:
            latin, separator, remainder = head.partition(". ")
            if separator and len(latin) <= INCIPIT_MAX:
                incipit = latin + "."
                rest[0] = remainder

    if rest and not is_note(rest[0]):
        argument = rest.pop(0)
    return incipit, argument, rest


def parse_chapter(book, number, block, stats):
    """One chapter: its incipit, its argument, and its render array of rows.

    `rows` is heterogeneous on purpose -- verses, section headings and notes in reading
    order -- because that is what lets the reader render Challoner's commentary inline
    where it belongs and still treat the whole chapter as one selectable list.

    Classification after the first verse is BY POSITION, not by pattern. A paragraph
    there is a verse if it is numbered, a section heading if it is short, and otherwise
    a note. Requiring the catchword ellipsis to recognise a note instead would drop the
    ~30 notes that carry no ellipsis, and dropping a note is worse than the alternative
    failure: there is nothing else a paragraph in that position can be, so a wrong guess
    still lands the text in front of the reader, merely styled as commentary.
    """
    rows = []
    front = []
    seen_verse = False

    for paragraph in block:
        verse = PATTERNS["verse"].match(paragraph)
        if verse:
            if int(verse.group("c")) != number:
                raise SystemExit(
                    f"{book['id']} {number}: verse {verse.group('c')}:"
                    f"{verse.group('v')} is numbered for another chapter; a chapter "
                    f"heading was missed"
                )
            seen_verse = True
            sub = verse.group("sub")
            rows.append(
                {
                    "kind": "verse",
                    "number": int(verse.group("v")),
                    # Only the 18 verses of Psalm 9's Hebrew-10 half carry one. Set
                    # where the printed label is not just the number, so the gutter and
                    # the citation can both say what the edition says rather than
                    # renumbering it.
                    "label": f"{number}{sub}:{verse.group('v')}" if sub else None,
                    "text": verse.group("text"),
                }
            )
            stats.verses += 1
            continue

        if not seen_verse:
            front.append(paragraph)
            continue

        rows.append(body_row(paragraph, stats))

    incipit, argument, leading = split_front_matter(book["id"], front)
    if incipit:
        stats.incipits += 1
    if argument:
        stats.arguments += 1
    rows = [body_row(paragraph, stats) for paragraph in leading] + rows

    return {
        "number": number,
        "latinIncipit": incipit,
        "argument": argument,
        "rows": rows,
    }


def parse_bible(text, retrieved, stats):
    """Walk the body once, emitting 73 books.

    The scan is driven by BOOKS: it expects heading N+1 next and will not accept
    heading N+3, so a transcription that dropped a book fails here rather than
    producing a corpus that is quietly one book short.
    """
    lines = split_lines(text)
    start = next(
        (i for i, line in enumerate(lines) if PATTERNS["pg_start"].match(line)), None
    )
    end = next(
        (i for i, line in enumerate(lines) if PATTERNS["pg_end"].match(line)), None
    )
    if start is None or end is None:
        raise SystemExit("could not find the Project Gutenberg markers")
    body = lines[start + 1 : end]

    cut = next(
        (i for i, line in enumerate(body) if PATTERNS["appendices"].match(line.strip())),
        None,
    )
    if cut is None:
        raise SystemExit(
            "no APPENDICES marker; refusing to parse, because everything after it is "
            "1610 back matter that would be filed as canon"
        )
    body = body[:cut]

    blocks = paragraphs(body)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()

    # Index every book heading and every chapter heading up front, so the walk below is
    # a slice per chapter rather than a state machine with three open scopes.
    heading_at = {}
    for index, paragraph in enumerate(blocks):
        heading_at.setdefault(paragraph, index)

    starts = []
    for entry in BOOKS:
        at = heading_at.get(entry[1])
        if at is None:
            raise SystemExit(f"{entry[0]}: heading {entry[1]!r} not found")
        if starts and at <= starts[-1][1]:
            raise SystemExit(
                f"{entry[0]}: heading {entry[1]!r} is out of canonical order"
            )
        starts.append((entry, at))

    books = []
    for position, (entry, at) in enumerate(starts):
        book_id, heading, short, testament, division, deutero, genre, abbrev = entry
        stop = starts[position + 1][1] if position + 1 < len(starts) else len(blocks)
        books.append(
            parse_book(
                {
                    "id": book_id,
                    "name": short,
                    "title": title_for(heading),
                    "testament": testament,
                    "division": division,
                    "canonicalIndex": position + 1,
                    "deuterocanonical": deutero,
                    "genre": genre,
                    "abbreviations": abbrev,
                },
                blocks[at + 1 : stop],
                digest,
                retrieved,
                stats,
            )
        )
    return books


def title_for(heading):
    """The reader-facing title, from the transcription's all-caps heading.

    Title-cased rather than left in caps, because the heading is set in caps as
    typography and `THE BOOK OF GENESIS` in a navigator row is shouting. The small
    words and the abbreviations that must stay as they are get an explicit pass.
    """
    keep = {"OF", "THE", "TO", "AND", "IS", "WHICH", "CALLED", "OTHERWISE"}
    upper = {"ST.", "A.D."}
    words = []
    for index, word in enumerate(heading.split()):
        if word in upper:
            words.append(word.title() if word == "ST." else word)
        elif index > 0 and word.rstrip(",") in keep:
            words.append(word.lower())
        else:
            words.append(word.capitalize())
    return " ".join(words)


def parse_book(book, blocks, digest, retrieved, stats):
    """Split one book's paragraphs at its chapter headings."""
    chapter_at = []
    for index, paragraph in enumerate(blocks):
        match = PATTERNS["chapter"].match(paragraph)
        if not match:
            continue
        if match.group("book") != book["name"]:
            # A chapter heading naming another book inside this book's span means the
            # BOOKS table and the file disagree about where a book ends.
            raise SystemExit(
                f"{book['id']}: chapter heading {paragraph!r} names another book"
            )
        chapter_at.append((index, int(match.group("n"))))

    if not chapter_at:
        raise SystemExit(f"{book['id']}: no chapter headings found")

    # Everything above the first chapter heading is Challoner's introduction to the
    # book. Lamentations' `PREFACE` and Ecclesiasticus' `THE PROLOGUE.` land here, which
    # is where they belong: both are front matter to their book, not part of chapter 1.
    preface = blocks[: chapter_at[0][0]]
    if preface:
        stats.prefaces += 1

    chapters = []
    for position, (index, number) in enumerate(chapter_at):
        if number != position + 1:
            raise SystemExit(
                f"{book['id']}: chapter {number} arrived at position {position + 1}"
            )
        stop = chapter_at[position + 1][0] if position + 1 < len(chapter_at) else None
        chapters.append(
            parse_chapter(book, number, blocks[index + 1 : stop], stats)
        )

    expected = EXPECTED_CHAPTERS[book["id"]]
    if len(chapters) != expected:
        raise SystemExit(
            f"{book['id']}: parsed {len(chapters)} chapters, expected {expected}"
        )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": book["id"],
        "name": book["name"],
        "title": book["title"],
        "testament": book["testament"],
        "division": book["division"],
        "canonicalIndex": book["canonicalIndex"],
        "deuterocanonical": book["deuterocanonical"],
        "genre": book["genre"],
        "abbreviations": book["abbreviations"],
        "preface": preface,
        "source": {
            "kind": "gutenberg",
            "ebookID": EBOOK_ID,
            "url": EBOOK_URL,
            "retrieved": retrieved,
            "textSHA256": digest,
            "parserVersion": PARSER_VERSION,
            "note": "Douay-Rheims (Challoner revision). Public domain in the US. "
            "PG header/footer and the 1610 appendices stripped.",
        },
        "chapters": chapters,
    }


# ---------------------------------------------------------------------------
# reporting


def verify(books, stats):
    chapters = sum(len(book["chapters"]) for book in books)
    verses = sum(
        1
        for book in books
        for chapter in book["chapters"]
        for row in chapter["rows"]
        if row["kind"] == "verse"
    )
    print(f"books            {len(books)}")
    print(f"chapters         {chapters}")
    print(f"verses           {verses}")
    print(f"arguments        {stats.arguments}")
    print(f"notes            {stats.notes} ({stats.uncued_notes} with no catchword)")
    print(f"section headings {stats.sections}")
    print(f"latin incipits   {stats.incipits}")
    print(f"prefaces         {stats.prefaces}")
    print(f"unclassified     {len(stats.unclassified)}")
    for line in stats.unclassified[:20]:
        print(f"    {line}")

    ok = True
    if len(books) != len(BOOKS):
        print(f"FAIL {len(books)} books, expected {len(BOOKS)}")
        ok = False
    if chapters != TOTAL_CHAPTERS:
        print(f"FAIL {chapters} chapters, expected {TOTAL_CHAPTERS}")
        ok = False
    if verses != TOTAL_VERSES:
        print(f"FAIL {verses} verses, expected {TOTAL_VERSES}")
        ok = False
    if stats.unclassified:
        print(f"FAIL {len(stats.unclassified)} unclassified paragraphs")
        ok = False
    empty = [
        f"{book['id']} {chapter['number']}"
        for book in books
        for chapter in book["chapters"]
        if not any(row["kind"] == "verse" for row in chapter["rows"])
    ]
    if empty:
        print(f"FAIL chapters with no verses: {', '.join(empty)}")
        ok = False
    return ok


def dump_chapter(books, spec):
    book_id, _, number = spec.partition(":")
    book = next((b for b in books if b["id"] == book_id), None)
    if book is None:
        raise SystemExit(f"no book {book_id!r}")
    chapter = next(
        (c for c in book["chapters"] if c["number"] == int(number)), None
    )
    if chapter is None:
        raise SystemExit(f"no chapter {spec}")
    print(f"{book['title']} — {book['name']} {chapter['number']}")
    if chapter["latinIncipit"]:
        print(f"   [{chapter['latinIncipit']}]")
    if chapter["argument"]:
        print(f"   {chapter['argument']}")
    print()
    for row in chapter["rows"]:
        if row["kind"] == "verse":
            print(f"{row['label'] or row['number']:>7} | {row['text']}")
        elif row["kind"] == "note":
            cue = f"{row['catchword']}: " if row["catchword"] else ""
            print(f"        |     * {cue}{row['text'][:100]}")
        else:
            print(f"        | == {row['text']}")


# ---------------------------------------------------------------------------


def read_source(from_file, attempts=4):
    """Read the source text from disk or fetch it.

    `--from-file` stays a first-class path because gutenberg.org needs a network
    allowlist entry here, and a future reader may not have one. Note that `www.` is
    required: bare `gutenberg.org` is not reachable from this sandbox.

    An incomplete body is treated as a failure rather than parsed. A cut-off response
    decodes perfectly and yields a Bible that is simply missing its last books, so the
    PG end marker is checked here.
    """
    if from_file:
        with open(from_file, "rb") as handle:
            return handle.read().decode("utf-8")
    for attempt in range(1, attempts + 1):
        print(f"fetching {TEXT_URL}", file=sys.stderr)
        try:
            with urllib.request.urlopen(TEXT_URL, timeout=180) as response:
                text = response.read().decode("utf-8")
            if not any(PATTERNS["pg_end"].match(line) for line in split_lines(text)):
                raise ValueError("response has no PG end marker; body was truncated")
            return text
        except (urllib.error.URLError, OSError, ValueError) as error:
            if attempt == attempts:
                raise SystemExit(f"giving up after {attempts} attempts: {error}")
            delay = 2**attempt
            print(f"  {error}; retrying in {delay}s", file=sys.stderr)
            time.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="every book")
    parser.add_argument("--book", help="write or verify one book by id")
    parser.add_argument("--from-file", help="read the source text from disk")
    parser.add_argument("--out", help="directory to write JSON into")
    parser.add_argument("--verify", action="store_true", help="print stats")
    parser.add_argument("--dump-chapter", help="print one chapter, e.g. psalms:118")
    parser.add_argument(
        "--retrieved",
        default=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        help="retrieval date recorded in the JSON (default: today, UTC)",
    )
    args = parser.parse_args()

    if not (args.all or args.book or args.dump_chapter):
        parser.error("pass --all, --book or --dump-chapter")

    # The whole file is parsed even for one book: the BOOKS walk is what locates a
    # book's span, and a single-book parse that skipped it could not tell where the
    # book ends.
    text = read_source(args.from_file)
    stats = ParseStats()
    books = parse_bible(text, args.retrieved, stats)

    if args.dump_chapter:
        dump_chapter(books, args.dump_chapter)
        return 0

    selected = books if args.all else [b for b in books if b["id"] == args.book]
    if not selected:
        parser.error(f"no book {args.book!r}")

    if args.verify:
        return 0 if verify(books, stats) else 1

    if args.out:
        for book in selected:
            path = f"{args.out.rstrip('/')}/{book['id']}.json"
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(book, handle, ensure_ascii=False, separators=(",", ":"))
                handle.write("\n")
            print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
