// Copyright © 2026 Apple Inc.

import Foundation
import SwiftUI

/// Model-free assertions, run by `--selftest`. No download, no network, no GPU.
///
/// They live in the executable because there is only one target: a test target would
/// need the corpus resources and the app's types duplicated or exported. What they are
/// for is the two things that break silently — a corpus that decodes but is subtly
/// wrong, and prompt drift.
enum SelfTest {

    /// Collects failures rather than trapping, so one run reports everything that is
    /// wrong instead of only the first thing. A local object rather than static state:
    /// mutable global state would need concurrency annotations it has no business
    /// needing.
    final class Log {
        private(set) var failures: [String] = []

        func fail(_ message: String) { failures.append(message) }

        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { fail(message()) }
        }

        func equal<T: Equatable>(
            _ lhs: T, _ rhs: T, _ label: @autoclosure () -> String
        ) {
            if lhs != rhs { fail("\(label()): expected \(rhs), got \(lhs)") }
        }
    }

    static func run() -> Bool {
        let log = Log()

        corpus(log)
        psalmNumbering(log)
        references(log)
        navigator(log)
        selection(log)
        readingProgress(log)
        readerFonts(log)
        readerTextSizes(log)
        wordTokenizer(log)
        quoteCheck(log)
        sectionParsing(log)
        referenceCheck(log)
        referenceLinks(log)
        patristicCheck(log)
        crossReferences(log)
        randomPassage(log)
        followUpParsing(log)
        goldenPromptRender(log)

        if log.failures.isEmpty {
            print("selftest: all checks passed")
            return true
        }
        for failure in log.failures {
            print("selftest FAIL: \(failure)")
        }
        print("selftest: \(log.failures.count) failure(s)")
        return false
    }

    // MARK: - Corpus

    /// Exact counts, measured on the real Gutenberg file. They are regression targets,
    /// not estimates.
    ///
    /// 35,805 verses rather than the 35,780 a naive `^\d+:\d+\. ` scan reports. The
    /// difference is exactly the 25 verses such a scan cannot see: the 18 of Psalm 9's
    /// Hebrew-10 half, which this edition labels `9a:1` through `9a:18`, and the 7
    /// across the file whose space after the verse number was lost in transcription.
    /// Both are ordinary scripture, and the larger number is the correct one.
    private static let totalBooks = 73
    private static let totalChapters = 1334
    private static let totalVerses = 35805

    /// Per-book chapter counts worth pinning individually, because each one is a place
    /// the canon and the parse could disagree without moving the total much.
    ///
    /// Psalms 150 is the psalter intact. Esther 16 and Daniel 14 are the
    /// deuterocanonical additions parsing as ordinary chapters rather than being
    /// dropped — a Protestant Esther has 10 and a Protestant Daniel 12. Baruch 6 is the
    /// Letter of Jeremias kept as chapter 6 rather than split off. Abdias 1 is the
    /// single-chapter case, which is where an off-by-one in the chapter walk shows up
    /// first.
    private static let chapterCounts: [String: Int] = [
        "genesis": 50, "psalms": 150, "esther": 16, "daniel": 14, "baruch": 6,
        "abdias": 1, "isaias": 66, "matthew": 28, "john": 21, "apocalypse": 22,
        "1-machabees": 16, "wisdom": 19, "ecclesiasticus": 51, "philemon": 1,
    ]

    private static func corpus(_ log: Log) {
        let bible: Bible
        do {
            bible = try CorpusLoader.load()
        } catch {
            log.fail("corpus did not load: \(error.localizedDescription)")
            return
        }

        log.equal(bible.books.count, totalBooks, "book count")
        log.equal(bible.chapterKeys.count, totalChapters, "chapter count")

        let verses = bible.books.reduce(0) { total, book in
            total + book.chapters.reduce(0) { $0 + $1.verseCount }
        }
        log.equal(verses, totalVerses, "verse count")

        for (id, count) in chapterCounts.sorted(by: { $0.key < $1.key }) {
            guard let book = bible.book(id) else {
                log.fail("corpus: no book \(id)")
                continue
            }
            log.equal(book.chapters.count, count, "\(id) chapter count")
        }

        // Canonical order and indices, which is what the navigator lists by and what
        // `books(in:)` sorts on. A gap here reorders the whole Bible.
        for (offset, book) in bible.books.enumerated() {
            log.equal(book.canonicalIndex, offset + 1, "\(book.id) canonicalIndex")
        }
        log.equal(bible.books.first?.id, "genesis", "first book")
        log.equal(bible.books.last?.id, "apocalypse", "last book")

        // The nine divisions, and the two testaments they partition.
        for division in Division.allCases {
            let books = bible.books(in: division)
            log.check(!books.isEmpty, "division \(division.rawValue) is empty")
            for book in books {
                log.equal(
                    book.testament, division.testament,
                    "\(book.id) testament against its division")
            }
        }
        log.equal(
            bible.books.count { $0.testament == .old }, 46, "Old Testament book count")
        log.equal(
            bible.books.count { $0.testament == .new }, 27, "New Testament book count")
        log.equal(bible.books(in: .pentateuch).count, 5, "Pentateuch")
        log.equal(bible.books(in: .historical).count, 16, "Historical")
        log.equal(bible.books(in: .wisdom).count, 7, "Wisdom")
        log.equal(bible.books(in: .prophets).count, 18, "Prophets")
        log.equal(bible.books(in: .gospels).count, 4, "Gospels")
        log.equal(bible.books(in: .pauline).count, 14, "Pauline Epistles")
        log.equal(bible.books(in: .catholic).count, 7, "Catholic Epistles")
        log.equal(
            bible.books.count { $0.deuterocanonical }, 7, "deuterocanonical books")

        // Machabees are `.historical` and sit at the end of the Old Testament, which
        // is the one place the division and the canonical order pull apart. If
        // `books(in:)` ever stopped sorting, this is what would catch it.
        log.equal(
            bible.books(in: .historical).last?.id, "2-machabees",
            "last historical book")

        // Every chapter has verses, every chapter is numbered from 1 without a gap,
        // and no row is empty. A chapter that parsed to nothing still decodes and
        // still renders — as a blank page.
        for book in bible.books {
            for (offset, chapter) in book.chapters.enumerated() {
                log.equal(chapter.number, offset + 1, "\(book.id) chapter numbering")
                log.check(
                    chapter.verseCount > 0, "\(book.id) \(chapter.number) has no verses")
                log.check(
                    !chapter.rows.contains { $0.text.isEmpty },
                    "\(book.id) \(chapter.number) has an empty row")
            }
        }

        // Challoner's commentary is the whole basis of the annotation design, so its
        // presence is a regression target rather than a nice-to-have. If a parser
        // change dropped the notes, everything downstream would keep working and
        // quietly get much worse.
        let notes = bible.books.reduce(0) { total, book in
            total + book.chapters.reduce(0) { $0 + $1.rows.count { $0.kind == .note } }
        }
        let arguments = bible.books.reduce(0) { total, book in
            total + book.chapters.count { $0.argument != nil }
        }
        log.equal(notes, 1772, "Challoner notes")
        log.equal(arguments, 1296, "Challoner chapter arguments")
        log.equal(bible.books.count { !$0.preface.isEmpty }, 71, "Challoner prefaces")

        // Every psalm carries its Latin incipit. Two of them (9 and 56) only do
        // because the parser splits an incipit the transcription ran into the
        // argument, so this is the check that keeps that fix honest.
        let psalms = bible.book("psalms")
        log.equal(
            psalms?.chapters.count { $0.latinIncipit != nil }, 150, "Latin incipits")
        log.equal(
            psalms?.chapter(118)?.latinIncipit, "Beati immaculati.", "Psalm 118 incipit")

        // Psalm 9's Hebrew-10 half. The only labelled rows in the corpus, and the one
        // place the Vulgate numbering is visible in the text itself.
        let ninth = psalms?.chapter(9)
        let labelled = ninth?.rows.filter { $0.isVerse && $0.label != nil } ?? []
        log.equal(labelled.count, 18, "Psalm 9 sub-numbered verses")
        log.equal(labelled.first?.label, "9a:1", "Psalm 9 first sub-numbered label")
        log.equal(labelled.last?.label, "9a:18", "Psalm 9 last sub-numbered label")
        log.check(
            ninth?.rows.contains {
                $0.kind == .sectionHeading
                    && $0.text == "Psalm 10 according to the Hebrews."
            } ?? false,
            "Psalm 9 is missing the Hebrew-10 rubric")

        // Psalm 118's stanza headings: ALEPH through TAU, one per eight verses.
        let stanzas =
            psalms?.chapter(118)?.rows.filter { $0.kind == .sectionHeading } ?? []
        log.check(
            stanzas.contains { $0.text == "ALEPH." }
                && stanzas.contains { $0.text == "TAU." },
            "Psalm 118 is missing its stanza headings")

        // A specific verse, end to end, so a silent re-parse that shifted the text is
        // caught by something a reader would recognise. Genesis 15:6 is the
        // Romans/Galatians cross-reference case and one of the benchmark passages.
        let genesis = bible.book("genesis")
        let sixth = genesis?.chapter(15)?.rows.first { $0.isVerse && $0.number == 6 }
        log.equal(
            sixth?.text, "Abram believed God, and it was reputed to him unto justice.",
            "Genesis 15:6")

        // Poetry is a rendering decision and nothing else, but it has to reach the
        // books it was meant for.
        let poetry = Set(bible.books.filter { $0.genre == .poetry }.map(\.id))
        log.equal(
            poetry,
            [
                "job", "psalms", "proverbs", "ecclesiastes", "canticle-of-canticles",
                "wisdom", "ecclesiasticus", "lamentations",
            ],
            "poetry books")
    }

    // MARK: - Psalm numbering

    private static func psalmNumbering(_ log: Log) {
        // The case a reader hits: the shepherd psalm is DRB 22, Hebrew 23.
        log.equal(
            PsalmNumbering.hebrew(forDouay: 22), .exact(23), "DRB 22 is Hebrew 23")
        log.equal(PsalmNumbering.douay(forHebrew: 23), 22, "Hebrew 23 is DRB 22")

        // The seams. DRB 9 covers two Hebrew psalms; DRB 114 and 115 split one.
        log.equal(
            PsalmNumbering.hebrew(forDouay: 9), .spans(9 ... 10),
            "DRB 9 spans Hebrew 9-10")
        log.equal(PsalmNumbering.douay(forHebrew: 10), 9, "Hebrew 10 is inside DRB 9")
        log.equal(
            PsalmNumbering.hebrew(forDouay: 113), .spans(114 ... 115),
            "DRB 113 spans Hebrew 114-115")
        log.equal(
            PsalmNumbering.hebrew(forDouay: 114), .part(116), "DRB 114 is part of 116")

        // Where the two systems agree, they must say so rather than offset anyway.
        for number in [1, 2, 8, 148, 149, 150] {
            log.equal(
                PsalmNumbering.hebrew(forDouay: number), .exact(number),
                "DRB \(number) is Hebrew \(number)")
            log.equal(
                PsalmNumbering.douay(forHebrew: number), number,
                "Hebrew \(number) is DRB \(number)")
        }

        // Undefined rather than guessed. Hebrew 116 and 147 each split into two Douay
        // psalms, and the cross-reference importer drops them rather than picking a
        // half — which is the whole reason this returns an optional.
        log.equal(PsalmNumbering.douay(forHebrew: 116), nil, "Hebrew 116 is ambiguous")
        log.equal(PsalmNumbering.douay(forHebrew: 147), nil, "Hebrew 147 is ambiguous")
        log.equal(PsalmNumbering.douay(forHebrew: 0), nil, "Hebrew 0")
        log.equal(PsalmNumbering.douay(forHebrew: 151), nil, "Hebrew 151")
        log.equal(PsalmNumbering.hebrew(forDouay: 151), nil, "DRB 151")

        // Round-trip everything that is not a seam. This is the check that would catch
        // an off-by-one introduced anywhere in the middle of the table.
        for douay in 1 ... 150 {
            guard case .exact(let hebrew) = PsalmNumbering.hebrew(forDouay: douay)
            else { continue }
            log.equal(
                PsalmNumbering.douay(forHebrew: hebrew), douay,
                "round trip for DRB \(douay)")
        }
    }

    // MARK: - References

    private static func references(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else { return }
        let table = BookTable(bible)

        func parse(_ query: String) -> ResolvedReference? {
            ReferenceParser.parse(query, table: table, bible: bible)
        }

        // The shapes a reader actually types.
        log.equal(parse("jn 3:16")?.reference.bookID, "john", "jn 3:16 book")
        log.equal(parse("jn 3:16")?.reference.verse, 16, "jn 3:16 verse")
        log.equal(parse("John 3")?.reference.chapter, 3, "John 3 chapter")
        log.equal(parse("John 3")?.reference.verse, nil, "John 3 has no verse")
        log.equal(
            parse("1 cor 13:4-7")?.reference.bookID, "1-corinthians", "1 cor 13:4-7")
        log.equal(parse("1 cor 13:4-7")?.reference.verse, 4, "1 cor 13:4-7 first")
        log.equal(parse("1 cor 13:4-7")?.reference.lastVerse, 7, "1 cor 13:4-7 last")
        log.equal(parse("Gen 1.1")?.reference.verse, 1, "Gen 1.1 accepts a period")
        log.equal(parse("Ps 22")?.reference.bookID, "psalms", "Ps 22")

        // The aliases that make the Douay names typable by someone who does not know
        // them. Nobody types "Paralipomenon", and "rev" has to reach the Apocalypse.
        log.equal(parse("rev 21")?.reference.bookID, "apocalypse", "rev 21")
        log.equal(parse("sirach 3")?.reference.bookID, "ecclesiasticus", "sirach 3")
        log.equal(parse("sir 3")?.reference.bookID, "ecclesiasticus", "sir 3")
        log.equal(
            parse("1 chronicles 5")?.reference.bookID, "1-paralipomenon",
            "1 chronicles 5")
        log.equal(parse("song 2")?.reference.bookID, "canticle-of-canticles", "song 2")
        log.equal(parse("1 samuel 17")?.reference.bookID, "1-kings", "1 samuel 17")
        log.equal(parse("st. mark 4")?.reference.bookID, "mark", "st. mark 4")

        // The two hints, which are rendered as a secondary row and never as a redirect.
        // `1 Kings 18` resolves to the DRB book, which is 1 Samuel — correct for this
        // edition and wrong against the reader's expectation, so it must also say so.
        let kings = parse("1 Kings 18")
        log.equal(kings?.reference.bookID, "1-kings", "1 Kings 18 resolves to the DRB book")
        log.check(
            kings?.hint?.contains("1 Samuel") ?? false,
            "1 Kings 18 should hint at the naming difference")
        let shepherd = parse("Ps 23")
        log.equal(shepherd?.reference.chapter, 23, "Ps 23 resolves to DRB 23")
        log.check(
            shepherd?.hint?.contains("22") ?? false,
            "Ps 23 should hint at DRB 22")
        // Where the numbering agrees there is nothing to say.
        log.equal(parse("Ps 1")?.hint, nil, "Ps 1 needs no hint")
        log.equal(parse("Ps 150")?.hint, nil, "Ps 150 needs no hint")

        // Garbage, and near-misses that must not resolve to something plausible.
        log.equal(parse("")?.reference.bookID, nil, "empty query")
        log.equal(parse("hezekiah 4:2")?.reference.bookID, nil, "no such book")
        log.equal(parse("genesis 51")?.reference.bookID, nil, "no such chapter")
        log.equal(parse("the quick brown fox")?.reference.bookID, nil, "prose")
        log.equal(parse("macbeth")?.reference.bookID, nil, "wrong corpus entirely")

        // A backwards range is a typo, not an error: keep the start, drop the end.
        log.equal(parse("Gen 1:5-2")?.reference.lastVerse, nil, "backwards range")

        // Every book must be reachable by its own short name, which is also what
        // `Citation` prints — so this is the check that the two agree.
        for book in bible.books {
            let query = "\(book.name) 1"
            log.equal(
                parse(query)?.reference.bookID, book.id, "round trip for \(book.name)")
        }
    }

    // MARK: - Selection

    private static func selection(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else { return }

        // Genesis 15:19-21 is the case the period rule exists for: three verses that
        // are one list. *"The Cineans, and Cenezites, the Cedmonites," / "And the
        // Hethites…" / "And the Amorrhites…"*
        guard let chapter = bible.chapter(ChapterKey(bookID: "genesis", chapter: 15)),
            let start = chapter.rows.firstIndex(where: { $0.isVerse && $0.number == 19 })
        else {
            log.fail("selection: Genesis 15 did not load")
            return
        }
        let period = VerseSelection.period(at: start, in: chapter.rows)
        log.equal(
            chapter.rows[period.range.lowerBound].number, 19, "Genesis 15:19-21 first")
        log.equal(
            chapter.rows[period.range.upperBound].number, 21, "Genesis 15:19-21 last")

        // A verse that ends a sentence selects alone. 15:6 is a complete sentence.
        guard
            let sixth = chapter.rows.firstIndex(where: { $0.isVerse && $0.number == 6 })
        else {
            log.fail("selection: Genesis 15:6 not found")
            return
        }
        log.equal(
            VerseSelection.period(at: sixth, in: chapter.rows).count, 1,
            "Genesis 15:6 is its own period")

        // The rule itself, away from the corpus.
        log.check(VerseSelection.continues("and the Cedmonites,"), "comma continues")
        log.check(VerseSelection.continues("saying:"), "colon continues")
        log.check(VerseSelection.continues("of the earth;"), "semicolon continues")
        log.check(
            VerseSelection.continues("and there was light and"),
            "a trailing lowercase word continues")
        log.check(
            !VerseSelection.continues("And light was made."), "a period ends it")
        log.check(!VerseSelection.continues("Who is like to God?"), "a question ends it")
        log.check(
            !VerseSelection.continues("he said: \"Let there be light.\""),
            "a closing quotation mark is stepped over")

        // A note selects itself, and never drags its verse in.
        if let note = chapter.rows.firstIndex(where: { $0.kind == .note }) {
            log.equal(
                VerseSelection.period(at: note, in: chapter.rows).count, 1,
                "a note selects alone")
        }

        // Arrow-key movement and clamping, which are what keep a stale selection from
        // indexing out of bounds after a chapter change.
        let rows = chapter.rows
        log.equal(
            VerseSelection.moved(from: nil, by: 1, extending: false, in: rows),
            VerseSelection(at: 0), "the first press lands rather than steps")
        log.equal(
            VerseSelection.moved(
                from: VerseSelection(at: 0), by: -1, extending: false, in: rows),
            nil, "stepping off the top rolls into the previous chapter")
        log.equal(
            VerseSelection(anchor: 900, head: 900).clamped(to: rows)?.head,
            rows.count - 1, "a stale selection clamps")
        log.equal(
            VerseSelection.chapter(rows)?.count, rows.count, "select chapter")
    }

    // MARK: - Navigator

    /// The accordion and the find field, which are pure functions of a `ChapterKey` and
    /// of the corpus respectively — which is the whole reason they are not written inside
    /// `NavigatorView`.
    private static func navigator(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else {
            log.fail("could not load the corpus for the navigator checks")
            return
        }
        let table = BookTable(bible)

        // MARK: The outline

        // What a launch gets: the restored position, and nothing else open.
        let outline = NavigatorOutline.following(
            ChapterKey(bookID: "isaias", chapter: 7), in: bible)
        log.check(outline.isOpen(division: .prophets), "the read division should be open")
        log.check(outline.isOpen(book: "isaias", in: .prophets), "the read book")
        log.check(!outline.isOpen(division: .gospels), "another division should be shut")
        log.check(
            !outline.isOpen(book: "jeremias", in: .prophets),
            "another book of the open division should be shut")
        // The invariant: an open book belongs to the open division.
        log.check(
            !outline.isOpen(book: "isaias", in: .gospels),
            "the open book should not read as open in another division")

        // Tapping the open division closes it, and takes its book with it.
        var closed = outline
        closed.toggle(division: .prophets)
        log.check(!closed.isOpen(division: .prophets), "the tapped-open division closes")
        log.check(
            !closed.isOpen(book: "isaias", in: .prophets),
            "closing a division should drop its open book")

        // Tapping another division moves the accordion, with that division's books shut:
        // four book rows to choose between, not a chapter grid.
        var moved = outline
        moved.toggle(division: .gospels)
        log.check(moved.isOpen(division: .gospels), "the tapped division should open")
        log.check(!moved.isOpen(division: .prophets), "the division left behind closes")
        log.check(
            !moved.isOpen(book: "matthew", in: .gospels),
            "a newly opened division should start with its books shut")

        // A book in another division opens both.
        var reached = outline
        reached.toggle(book: "john", in: .gospels)
        log.check(reached.isOpen(division: .gospels), "a book opens its division with it")
        log.check(reached.isOpen(book: "john", in: .gospels), "the tapped book opens")
        log.check(!reached.isOpen(division: .prophets), "the division left behind closes")

        // Tapping the open book closes it and leaves the division open.
        reached.toggle(book: "john", in: .gospels)
        log.check(!reached.isOpen(book: "john", in: .gospels), "the tapped-open book closes")
        log.check(
            reached.isOpen(division: .gospels),
            "closing a book should leave its division open")

        // A key the corpus cannot resolve opens nothing rather than trapping.
        let unknown = NavigatorOutline.following(
            ChapterKey(bookID: "book-of-eli", chapter: 1), in: bible)
        log.check(
            !Division.allCases.contains { unknown.isOpen(division: $0) },
            "an unresolvable key should open no division")

        // MARK: The find field

        /// The book ids a query lists, in canonical order.
        func ids(_ query: String) -> [String]? {
            guard
                case .books(let matches) = NavigatorSearch.matches(
                    in: bible, table: table, query: query)
            else { return nil }
            return matches.map(\.book.id)
        }

        // No query is the whole corpus: the outline alone decides what shows.
        log.equal(ids("  ")?.count, 73, "the number of books with no query")
        log.equal(ids("  ")?.first, "genesis", "the first book with no query")

        // A name match.
        log.equal(ids("machab"), ["1-machabees", "2-machabees"], "\"machab\"")
        log.equal(ids("apocalypse"), ["apocalypse"], "\"apocalypse\"")
        // Folding: the curly apostrophe in the Canticle's title, which no reader types.
        log.equal(
            ids("solomons canticle"), ["canticle-of-canticles"], "\"solomons canticle\"")

        // An alias match says which alias found it, because "sirach" finding
        // Ecclesiasticus is right and also surprising.
        guard
            case .books(let sirach) = NavigatorSearch.matches(
                in: bible, table: table, query: "sirach")
        else {
            log.fail("\"sirach\" should list books")
            return
        }
        log.equal(sirach.map(\.book.id), ["ecclesiasticus"], "\"sirach\"")
        log.equal(sirach.first?.via, "Sirach", "\"sirach\" should say what matched")
        // A name match does not, because there is nothing to explain.
        guard
            case .books(let genesis) = NavigatorSearch.matches(
                in: bible, table: table, query: "genesis")
        else {
            log.fail("\"genesis\" should list books")
            return
        }
        log.equal(genesis.first?.via, nil, "a name match needs no explanation")

        // Nothing at all, which the view renders as its placeholder.
        log.equal(ids("zzz"), [], "the books matching \"zzz\"")

        // MARK: The reference front end

        // A reference is an address, not a search: it comes back as a jump.
        guard
            case .reference(let resolved) = NavigatorSearch.matches(
                in: bible, table: table, query: "jn 3:16")
        else {
            log.fail("\"jn 3:16\" should resolve to a reference")
            return
        }
        log.equal(resolved.reference.bookID, "john", "\"jn 3:16\" book")
        log.equal(resolved.reference.verse, 16, "\"jn 3:16\" verse")

        // And a bare book name is not, even though the parser could see a number in it:
        // `John` alone has no chapter, so it lists. The Apocalypse is in the list because
        // its title in this edition is "The Apocalypse of St. John the Apostle", which is
        // a title match and exactly what a reader typing "john" should be shown.
        log.equal(
            ids("john"), ["john", "1-john", "2-john", "3-john", "apocalypse"],
            "\"john\" lists")

        // The written form round-trips, which is what the jump row prints.
        log.equal(
            ScriptureReference(bookID: "john", chapter: 3, verse: 16)
                .string(bookName: "John"), "John 3:16", "one verse")
        log.equal(
            ScriptureReference(bookID: "john", chapter: 3).string(bookName: "John"),
            "John 3", "a whole chapter")
        log.equal(
            ScriptureReference(
                bookID: "1-corinthians", chapter: 13, verse: 4, lastVerse: 7
            ).string(bookName: "1 Corinthians"), "1 Corinthians 13:4-7", "a run")
    }

    // MARK: - Reader fonts

    /// The typeface picker's inputs. Model-free and network-free.
    ///
    /// Nothing here may touch `ReaderFontLibrary`, which is `@MainActor` while `run()` is
    /// synchronous and non-isolated — which is exactly why `installedFamilyNames()` is a
    /// `static` on `ReaderFont` that the library merely calls.
    ///
    /// Named once so the bound and the failure message cannot drift apart. Wide enough
    /// for any real optical correction and narrow enough that a fat-fingered `11.5`
    /// cannot ship.
    private static let plausibleOpticalScales: ClosedRange<CGFloat> = 0.9 ... 1.3

    private static func readerFonts(_ log: Log) {
        for font in ReaderFont.allCases {
            // Literally the `@AppStorage("readerFont")` contract: a raw value that stops
            // round-tripping silently resets every reader to the system face.
            log.check(
                ReaderFont(rawValue: font.rawValue) == font,
                "ReaderFont.\(font) does not round-trip through its raw value")
            log.check(
                plausibleOpticalScales.contains(font.opticalScale),
                "ReaderFont.\(font) opticalScale \(font.opticalScale) is outside "
                    + "\(plausibleOpticalScales), which is not an optical correction")
        }

        log.equal(
            Set(ReaderFont.allCases.map(\.displayName)).count,
            ReaderFont.allCases.count, "the number of distinct display names")
        log.check(
            ReaderFont.system.familyName == nil,
            "the system face should not name a family")
        for font in ReaderFont.allCases where font != .system {
            log.check(font.familyName != nil, "ReaderFont.\(font) names no family")
        }

        // The only nontrivial logic in the feature, and pure CoreText: Baskerville has a
        // real italic cut, Big Caslon is a single face and has none — which is what
        // `ReaderTypeface.noteItalic` shears by hand for the catchword.
        log.check(
            ReaderFont.baskerville.hasItalicFace,
            "Baskerville reported no italic face, so note catchwords lost their cut")
        log.check(
            !ReaderFont.caslon.hasItalicFace,
            "Big Caslon reported an italic face, so the synthetic oblique is dead code")

        // Machine-dependent, and kept anyway: a typo like "BigCaslon" is otherwise
        // completely silent — the reader would just get the system face forever.
        // Deliberately not Garamond, which is an on-demand Apple asset and legitimately
        // absent until someone picks it.
        let installed = ReaderFont.installedFamilyNames()
        for font in [ReaderFont.caslon, .baskerville] {
            guard let family = font.familyName else { continue }
            log.check(
                installed.contains(family),
                "\"\(family)\" is not among the installed font families, so "
                    + "ReaderFont.\(font) would silently render as the system face")
        }
    }

    // MARK: - Reader text size

    /// The same bound as `plausibleOpticalScales`, and for the same reason: named once so
    /// the range and the failure message cannot drift apart.
    private static let plausibleTextSizeMultipliers: ClosedRange<CGFloat> = 0.7 ... 1.7

    /// The size ladder's inputs, and the arithmetic `ReaderTypeface` does with them.
    ///
    /// `installed: []` short-circuits `hasItalicFace`, so nothing here reaches CoreText or
    /// the `@MainActor` `ReaderFontLibrary`.
    private static func readerTextSizes(_ log: Log) {
        func typeface(
            _ size: ReaderTextSize, at category: DynamicTypeSize = .large
        ) -> ReaderTypeface {
            ReaderTypeface(
                .system, textSize: size, dynamicTypeSize: category, installed: [])
        }

        for size in ReaderTextSize.allCases {
            log.check(
                ReaderTextSize(rawValue: size.rawValue) == size,
                "ReaderTextSize.\(size) does not round-trip through its raw value")
            log.check(
                plausibleTextSizeMultipliers.contains(size.multiplier),
                "ReaderTextSize.\(size) multiplier \(size.multiplier) is outside "
                    + "\(plausibleTextSizeMultipliers), which is not a reading size")
            // `isDefault` is what every role branches on to keep the shipped rendering
            // byte-for-byte, so it has to mean "changes nothing".
            log.equal(
                size.isDefault, size.multiplier == 1,
                "ReaderTextSize.\(size).isDefault against a multiplier of exactly 1")
        }

        log.equal(ReaderTextSize.default.multiplier, 1, "the default multiplier")
        log.equal(
            ReaderTextSize.allCases.filter(\.isDefault).count, 1,
            "the number of neutral size steps")

        // Declaration order is menu order, so the multipliers have to rise along it.
        for (smaller, bigger) in zip(
            ReaderTextSize.allCases, ReaderTextSize.allCases.dropFirst())
        {
            log.check(
                smaller.multiplier < bigger.multiplier,
                "ReaderTextSize.\(smaller) (\(smaller.multiplier)) does not sort below "
                    + "\(bigger) (\(bigger.multiplier)) in `allCases` order")
        }

        // The byte-for-byte promise, in the units that can be read back off a
        // `ReaderTypeface`. Every one of these is a multiplication by exactly 1.0.
        let shipped = ReaderTypeface.system
        log.equal(shipped.textSize, .default, "the shipped typeface's size step")
        log.equal(shipped.sectionGap, 6, "the shipped section gap")
        log.equal(shipped.sectionInset, 28, "the shipped section-heading inset")
        log.equal(shipped.noteInset, 24, "the shipped note indent")
        log.equal(shipped.gutterWidth, 38, "the shipped gutter width")
        log.equal(shipped.measure, 620, "the shipped reading measure")
        log.equal(shipped.poetryMeasure, 480, "the shipped poetry measure")
        log.equal(shipped.poetryInset, 16, "the shipped poetry inset")
        log.equal(shipped.chapterTracking, 0, "the shipped chapter-heading tracking")
        log.equal(shipped.sectionTracking, 0.6, "the shipped section tracking")

        // The same promise for the fonts. Comparing rather than measuring: these assert
        // that Default returns the very same values the app returns with no size setting
        // at all, rather than a computed `Font.system(size:)` that merely resolves to the
        // same points. The two are not interchangeable, since only the text style follows
        // Dynamic Type.
        log.equal(shipped.verse, .body, "the shipped verse font")
        log.equal(shipped.chapterHeading, .headline, "the shipped chapter-heading font")
        log.equal(
            shipped.chapterArgument, .subheadline.italic(),
            "the shipped chapter-argument font")
        log.equal(
            shipped.sectionHeading, .caption.weight(.semibold),
            "the shipped section-heading font")
        // A note is **upright** and its catchword is italic, which is the one place the
        // presentation diverges from the stage direction it replaces. Asserted apart,
        // because swapping them would look plausible and read wrong on 1,772 rows.
        log.equal(shipped.note, .callout, "the shipped note font")
        log.equal(shipped.noteItalic, .callout.italic(), "the shipped catchword font")
        log.equal(shipped.verseItalic, .body.italic(), "the shipped verse-italic font")
        log.equal(
            shipped.gutterFont, .caption2.monospacedDigit(), "the shipped gutter font")

        // The other direction, which is what would catch the whole feature quietly
        // becoming a no-op for the system face.
        log.check(
            typeface(.large).verse != .body,
            "the system face at the Large step still returns `Font.body`, so choosing a "
                + "size does nothing")

        // End-to-end through `size(_:)`'s rounding: a ladder whose steps round to the
        // same point size is still a ladder, one that goes *down* somewhere is not.
        for (smaller, bigger) in zip(
            ReaderTextSize.allCases, ReaderTextSize.allCases.dropFirst())
        {
            let low = typeface(smaller)
            let high = typeface(bigger)
            log.check(
                low.sectionGap <= high.sectionGap,
                "the section gap falls from \(smaller) to \(bigger)")
            // The measure has to climb with the type for the same reason it is scaled at
            // all: a measure held fixed while the text grows is a measure that gets
            // narrower in ems, which is the cramped column the cap exists to avoid.
            log.check(
                low.measure < high.measure,
                "the reading measure does not grow from \(smaller) to \(bigger)")
            log.check(
                low.poetryMeasure < high.poetryMeasure,
                "the poetry measure does not grow from \(smaller) to \(bigger)")
        }

        // Poetry is narrower than prose at every step, which is the whole of the
        // typographic claim. If these ever crossed, a psalm would set *wider* than
        // Genesis.
        for size in ReaderTextSize.allCases {
            let face = typeface(size)
            log.check(
                face.poetryMeasure < face.measure,
                "the poetry measure is not narrower than the prose measure at \(size)")
        }

        // What makes `ChapterReaderView`'s `.onChange(of: typeface)` re-anchor the scroll
        // position when only the size changed.
        log.check(
            typeface(.default) != typeface(.largest),
            "two size steps of the same face compare equal, so a size change would not "
                + "re-anchor the reader's scroll position")
        log.check(
            typeface(.large) == typeface(.large),
            "the same face and size compare unequal, so every render would re-anchor")
    }

    // MARK: - Word tokenizer

    /// What a hover mark and a dictionary lookup are built on.
    private static func wordTokenizer(_ log: Log) {
        /// Every word of `text`, as strings.
        func words(_ text: String) -> [String] {
            WordTokenizer.words(in: text).map { String(text[$0]) }
        }

        /// The invariant that makes a hover mark trustworthy: the ranges tile the string.
        /// Ordered, non-overlapping, non-empty, and everything they leave out is
        /// punctuation or space — a gap with a letter in it is a word the reader can point
        /// at and be told nothing about.
        func tiles(_ text: String, _ label: String) {
            let ranges = WordTokenizer.words(in: text)
            var cursor = text.startIndex
            for range in ranges {
                log.check(!range.isEmpty, "\(label): an empty word range in \"\(text)\"")
                log.check(
                    range.lowerBound >= cursor,
                    "\(label): word ranges overlap or run backwards in \"\(text)\"")
                for character in text[cursor ..< range.lowerBound] {
                    log.check(
                        !character.isLetter && !character.isNumber,
                        "\(label): \"\(character)\" in \"\(text)\" is in no word")
                }
                cursor = range.upperBound
            }
            for character in text[cursor...] {
                log.check(
                    !character.isLetter && !character.isNumber,
                    "\(label): trailing \"\(character)\" in \"\(text)\" is in no word")
            }

            // And what the pointer will actually ask: every character of a word resolves
            // back to that same word.
            for range in ranges {
                for index in text[range].indices {
                    log.equal(
                        WordTokenizer.word(at: index, in: text), range,
                        "\(label): the word at \"\(text[index])\" in \"\(text)\"")
                }
            }
        }

        log.equal(
            words("In the beginning God created heaven, and earth."),
            ["In", "the", "beginning", "God", "created", "heaven", "and", "earth"],
            "the words of Genesis 1:1")

        // Elisions stay whole, in both apostrophes: the corpus is typeset with the curly
        // one and a reader's own typing is not.
        log.equal(words("o’er the"), ["o’er", "the"], "\"o’er\"")
        log.equal(words("o'er the"), ["o'er", "the"], "with a straight apostrophe")
        log.equal(words("the Lord’s anointed"), ["the", "Lord’s", "anointed"], "a possessive")

        // Compounds stay whole, which `.byWords` gets wrong on its own: it splits at
        // every hyphen. `she-goat` is Genesis 15:9, one of the benchmark passages.
        log.equal(words("a she-goat of"), ["a", "she-goat", "of"], "\"she-goat\"")
        log.equal(words("well-beloved"), ["well-beloved"], "\"well-beloved\"")
        log.equal(words("death,--and"), ["death", "and"], "a double-hyphen dash")

        // What the dictionary and the model are handed: the word, without the sentence
        // leaning on it.
        func term(_ text: String) -> String {
            guard let range = WordTokenizer.words(in: text).first else { return "" }
            return WordTokenizer.term(for: range, in: text)
        }
        log.equal(term("firmament,"), "firmament", "the term of \"firmament,\"")
        log.equal(term("Lord?"), "Lord", "the term of \"Lord?\"")
        log.equal(term("she-goat"), "she-goat", "the term of \"she-goat\"")

        // Nothing is a word on a space, and nothing is offered there.
        let line = "In the beginning"
        guard let space = line.firstIndex(of: " ") else {
            log.fail("no space in a string with two of them")
            return
        }
        log.check(
            WordTokenizer.word(at: space, in: line) == nil, "a space resolved to a word")
        log.check(
            WordTokenizer.word(at: line.startIndex, in: line) != nil,
            "the first letter of a line resolved to no word")

        tiles("", "an empty row")
        tiles("ALEPH.", "a section heading")
        tiles("9a:1", "a sub-numbered label")

        // And against the real thing, because the invariant is about punctuation the
        // corpus has and hand-written strings do not. Three books rather than 73: the
        // tokenizer knows nothing about which book it is reading, and these cover prose
        // narrative, the poetry measure, and — through Genesis — the note catchwords,
        // which are the only rows whose `displayText` is not their `text`.
        guard let bible = try? CorpusLoader.load() else {
            log.fail("could not load the corpus for the word-tokenizer checks")
            return
        }
        for id in ["genesis", "psalms", "john"] {
            guard let book = bible.book(id) else {
                log.fail("no book \(id)")
                continue
            }
            for chapter in book.chapters {
                for row in chapter.rows {
                    tiles(row.displayText, "\(id) \(chapter.number)")
                }
            }
        }
    }

    // MARK: - Quote check

    /// The one check that needs no model and cannot be argued with. Ported with
    /// ShakespeareReader's mechanism and this corpus's punctuation.
    private static func quoteCheck(_ log: Log) {
        let passage = "Abram believed God, and it was reputed to him unto justice."

        log.equal(
            QuoteCheck.unsupported(
                in: "He says \u{201C}Abram believed God\u{201D}.", passage: passage),
            [], "a quotation that is in the passage")
        log.equal(
            QuoteCheck.unsupported(
                in: "He says \u{201C}Abraham believed the Lord\u{201D}.", passage: passage),
            ["Abraham believed the Lord"],
            "a King James paraphrase of a Douay verse")

        // Both quote marks, mixed within one sentence, which is what the model does.
        log.equal(
            QuoteCheck.unsupported(
                in: "\u{201C}unto justice\" and \"reputed to him\u{201D}", passage: passage),
            [], "straight and curly pooled rather than paired")

        // The apostrophe fold, which is the reason `normalized` exists: this edition is
        // typeset with U+2019 throughout and the model writes U+0027.
        log.equal(
            QuoteCheck.unsupported(
                in: "\"the Lord's anointed\"", passage: "he is the Lord\u{2019}s anointed"),
            [], "a curly apostrophe in the corpus against a straight one in the output")

        // Case and whitespace folded; punctuation kept, because a moved comma is still a
        // misquotation, just a mild one.
        log.equal(
            QuoteCheck.unsupported(in: "\"ABRAM   BELIEVED  GOD\"", passage: passage),
            [], "case and runs of whitespace")

        // Below the floor, a "quotation" is punctuation and matching it proves nothing.
        log.equal(QuoteCheck.unsupported(in: "\"a\" \"of\"", passage: passage), [], "short spans")

        // Single quotes are not quotation marks in this corpus.
        log.equal(
            QuoteCheck.unsupported(in: "the Lord's own words", passage: passage), [],
            "an apostrophe is not a quotation mark")
    }

    // MARK: - Section parsing

    /// The four-marker format, and every way the model has to be tolerated breaking it.
    ///
    /// This is the check that makes the format decision safe. The whole argument for four
    /// labelled sections over one paragraph is that a dropped section becomes *visible*;
    /// a parser that silently mis-split a reordered run would give that back.
    private static func sectionParsing(_ log: Log) {
        // Well-formed.
        let whole = """
            PLAIN SENSE: Abram trusts God's promise, and God counts that trust as \
            righteousness.

            CONTEXT: Genesis is narrative, set in the patriarchal age.

            SEE ALSO: Romans 4:3 \u{2014} Paul quotes this verse.

            THE TRADITION: The Fathers read Abram's faith as the pattern of the \
            believer's own.
            """
        var parsed = Annotation.parseSections(whole)
        log.equal(parsed.present, Prompts.Section.allCases, "all four sections")
        log.equal(parsed.preamble, nil, "no preamble on a well-formed run")
        log.check(
            parsed.plainSense?.hasPrefix("Abram trusts") ?? false, "the plain sense body")
        log.check(
            parsed.seeAlso?.hasPrefix("Romans 4:3") ?? false, "the see-also body")
        log.check(
            parsed.tradition?.hasPrefix("The Fathers") ?? false, "the tradition body")

        // Missing: the passage had no cross-references, so the model omitted SEE ALSO.
        // The correct behaviour, and the pane has to render three sections rather than
        // an empty fourth.
        parsed = Annotation.parseSections(
            "PLAIN SENSE: A.\n\nCONTEXT: B.\n\nTHE TRADITION: C.")
        log.equal(parsed.present, [.plainSense, .context, .tradition], "a missing section")
        log.equal(parsed.seeAlso, nil, "the missing section is nil, not empty")

        // Reordered. The markers are located wherever they are, and each section runs to
        // the next one *found* rather than the next one expected.
        parsed = Annotation.parseSections(
            "THE TRADITION: C.\n\nPLAIN SENSE: A.\n\nCONTEXT: B.")
        log.equal(parsed.plainSense, "A.", "plain sense, out of order")
        log.equal(parsed.context, "B.", "context, out of order")
        log.equal(parsed.tradition, "C.", "tradition, out of order")

        // Markdown around the label, which the model adds unbidden.
        parsed = Annotation.parseSections("**PLAIN SENSE:** A.\n\n## CONTEXT: B.")
        log.equal(parsed.plainSense, "A.", "a bolded label")
        log.equal(parsed.context, "B.", "a heading label")

        // No colon.
        log.equal(
            Annotation.parseSections("PLAIN SENSE A.").plainSense, "A.", "no colon")

        // The word "context" inside a sentence must not split the annotation. This is the
        // reason the marker has to open a line.
        parsed = Annotation.parseSections(
            "PLAIN SENSE: The CONTEXT here is the covenant.\n\nCONTEXT: B.")
        log.equal(
            parsed.plainSense, "The CONTEXT here is the covenant.",
            "a label-shaped word mid-sentence")
        log.equal(parsed.context, "B.", "the real label after it")

        // Ignored the format entirely. Everything lands in `preamble` and the pane shows
        // it: an unparseable annotation the reader can still read beats a blank pane.
        parsed = Annotation.parseSections("Abram believed, and it was counted to him.")
        log.equal(parsed.present, [], "no sections at all")
        log.equal(
            parsed.preamble, "Abram believed, and it was counted to him.",
            "an unformatted run is kept whole")

        // Partial, which is what a generation stopped by Esc or by the token budget
        // leaves behind — and it is still shown, so it still has to parse.
        // A half-written section is a half-written section, not nothing.
        parsed = Annotation.parseSections("PLAIN SENSE: Abram tru")
        log.equal(parsed.plainSense, "Abram tru", "a mid-word partial")
        parsed = Annotation.parseSections("PLAIN SENSE: A.\n\nCONT")
        log.equal(parsed.present, [.plainSense], "a partial label is not a section yet")

        // Empty.
        log.check(Annotation.parseSections("").isEmpty, "an empty string")
        log.check(Annotation.parseSections("   \n\n ").isEmpty, "whitespace only")

        // A label emitted twice: the first is the one it was asked for.
        log.equal(
            Annotation.parseSections("PLAIN SENSE: A.\n\nPLAIN SENSE: B.").plainSense,
            "A.", "a repeated label")

        // `TRADITION` without the `THE`, which the model wrote once in thirteen
        // benchmark passages. Accepted, and the longer spelling still wins where both
        // could match — otherwise the marker would start after `THE ` and leave it
        // dangling on the end of the section above.
        log.equal(
            Annotation.parseSections("TRADITION: C.").tradition, "C.",
            "TRADITION without THE")
        log.equal(
            Annotation.parseSections("CONTEXT: B.\n\nTHE TRADITION: C.").context, "B.",
            "THE TRADITION does not eat the section above it")

        // A label with nothing under it is not a section. Four of the thirteen benchmark
        // passages had no cross-references and printed `SEE ALSO:` anyway; the pane must
        // render three sections rather than an empty fourth.
        log.equal(
            Annotation.parseSections("PLAIN SENSE: A.\n\nSEE ALSO:  \n\nTHE TRADITION: C.")
                .present, [.plainSense, .tradition], "an empty label is not a section")
    }

    // MARK: - Reference check

    private static func referenceCheck(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else { return }
        let table = BookTable(bible)

        let supplied = [
            CrossReference(
                reference: ScriptureReference(bookID: "romans", chapter: 4, verse: 3),
                label: "Romans 4:3",
                text: "Abraham believed God, and it was reputed to him unto justice.",
                source: .challoner)
        ]

        func check(_ text: String) -> [CheckedReference] {
            ReferenceCheck.check(text, supplied: supplied, bible: bible, table: table)
        }

        // `.ok` — exists, and was supplied. The only verdict that navigates.
        var found = check("SEE ALSO: Romans 4:3 \u{2014} Paul quotes this verse.")
        log.equal(found.count, 1, "one reference found")
        log.equal(found.first?.verdict, .ok, "a supplied reference")
        log.equal(found.first?.label, "Romans 4:3", "the normalized label")
        log.equal(found.first?.note, "Paul quotes this verse.", "the model's own note")

        // `.ungiven` — the verse is real and the *connection* is invented. Secondary
        // text, and still a link.
        found = check("See also Galatians 3:6.")
        log.equal(found.first?.verdict, .ungiven, "a real verse that was not supplied")

        // `.nonexistent`, in both of its shapes. The second is the one a book-name check
        // would miss.
        log.equal(
            check("As Hezekiah 4:2 says").first?.verdict, .nonexistent, "no such book")
        log.equal(
            check("See Genesis 51:1").first?.verdict, .nonexistent, "no such chapter")
        log.equal(check("See Jude 2:3").first?.verdict, .nonexistent, "no such chapter in Jude")
        log.equal(
            check("See Psalms 151:1").first?.verdict, .nonexistent, "no such psalm")

        // A Protestant book name resolves rather than being flagged: `Revelation` is an
        // alias of the Apocalypse, and telling a reader it does not exist would be wrong.
        log.equal(
            check("See Revelation 21:1").first?.reference.bookID, "apocalypse",
            "a Protestant alias resolves")
        log.equal(
            check("See Revelation 21:1").first?.label, "Apocalypse 21:1",
            "and is relabelled to this edition's name")

        // A supplied whole-chapter reference covers a verse inside it.
        let chapterSupplied = [
            CrossReference(
                reference: ScriptureReference(bookID: "romans", chapter: 4),
                label: "Romans 4", text: "", source: .challoner)
        ]
        log.equal(
            ReferenceCheck.check(
                "Romans 4:3", supplied: chapterSupplied, bible: bible, table: table
            ).first?.verdict, .ok, "a verse inside a supplied chapter")

        // A **ranged** citation of a supplied verse is still supplied. `lastVerse` is set
        // from the model's own `3-5` now that inline links need the end of the run, and
        // nothing in `supplied` carries one — so this is the check that setting it did not
        // quietly drop every ranged reference out of `SEE ALSO`.
        let ranged = check("SEE ALSO: Romans 4:3-5 \u{2014} Paul quotes this.").first
        log.equal(ranged?.verdict, .ok, "a ranged citation of a supplied verse")
        log.equal(ranged?.reference.lastVerse, 5, "and keeps the end of its run")
        log.equal(ranged?.label, "Romans 4:3-5", "and prints the range")

        // Ordinary prose must not produce references. "chapter 15" and "verse 6" are the
        // shapes that would, if resolution did not decide what is a book.
        log.equal(check("in chapter 15 at verse 6").count, 0, "prose is not a reference")
        log.equal(check("the 12 tribes").count, 0, "a bare number is not a reference")

        // Deduplicated, so a reference named twice is one row.
        log.equal(check("Romans 4:3 and again Romans 4:3").count, 1, "deduplicated")

        // Quoted verse text, against the whole Bible rather than the passage.
        let haystack = CorpusHaystack(bible)
        log.equal(
            ReferenceCheck.quotedVerse(
                "\"Abraham believed God: and it was reputed to him unto justice.\"",
                in: haystack),
            [], "a real verse quoted from outside the passage")
        // The same quotation with Genesis 15:6's comma where Romans 4:3 has a colon,
        // which is what a model reproducing one verse's punctuation for the other
        // actually writes. Real scripture, mildly misquoted — and `quotedVerse` folds
        // punctuation precisely so this is not reported as fabricated. `QuoteCheck` is
        // the one that would still flag it, and should.
        log.equal(
            ReferenceCheck.quotedVerse(
                "\"Abraham believed God, and it was reputed to him unto justice.\"",
                in: haystack),
            [], "a punctuation variant of a real verse")
        log.equal(
            ReferenceCheck.quotedVerse(
                "\"Blessed are the cheesemakers, for they shall inherit\"", in: haystack
            ).count, 1, "a verse that is nowhere in this Bible")
        log.equal(
            ReferenceCheck.quotedVerse("\"unto justice\"", in: haystack), [],
            "a span below the five-word floor")
    }

    // MARK: - Reference links

    /// What turns a reference in running prose into somewhere you can go.
    ///
    /// The case this exists for is the one that prompted the feature: a follow-up answer
    /// naming a dozen parables, every reference in it dead text. So the spans are checked
    /// against that answer verbatim rather than against a hand-tuned sentence.
    private static func referenceLinks(_ log: Log) {
        guard let bible = try? CorpusLoader.load(), let genesis = bible.book("genesis")
        else {
            log.fail("could not load the corpus for the reference-link checks")
            return
        }
        let table = BookTable(bible)

        /// Every linked run: what it reads, and where it points.
        func links(_ string: AttributedString) -> [(text: String, url: String)] {
            string.runs.compactMap { run in
                guard let url = run.link else { return nil }
                return (String(string[run.range].characters), url.absoluteString)
            }
        }

        /// Every struck run, which is the app saying "this verse is not in this Bible".
        func struck(_ string: AttributedString) -> [String] {
            string.runs.compactMap { run -> String? in
                let style: Text.LineStyle? = run.strikethroughStyle
                return style == nil ? nil : String(string[run.range].characters)
            }
        }

        // MARK: Spans

        // The screenshot's own answer. Three references in one sentence, two of them
        // ranges, one of them parenthesised — and the spans have to stop at the reference
        // rather than swallowing the prose around it.
        let parables =
            "Jesus told parables 12 times in the Gospels. The first is in Matthew "
            + "7:24-25, and the best known are the Good Samaritan (Luke 10:25-37) and "
            + "the Prodigal Son (Luke 15:11-32)."
        let answer = ReferenceLinks.modelProse(parables, bible: bible, table: table)
        log.equal(
            links(answer).map(\.text),
            ["Matthew 7:24-25", "Luke 10:25-37", "Luke 15:11-32"],
            "the linked spans of the parables answer")
        log.equal(struck(answer), [], "nothing in the parables answer is struck")
        // `parables 12` and `Gospels. The` are the shapes that would link if the scanner
        // did not make resolution decide what is a book.
        log.equal(links(answer).count, 3, "prose around a reference is not linked")

        // The end of the run, which used to be dropped: `Matthew 7:24-25` resolved to
        // verse 24 alone, so following it selected half the citation.
        let matthew = ReferenceCheck.scan("Matthew 7:24-25").first
        log.equal(matthew?.verse, 24, "Matthew 7:24-25 first verse")
        log.equal(matthew?.lastVerse, 25, "Matthew 7:24-25 last verse")
        log.equal(
            ReferenceCheck.scan("1 Cor 13:4\u{2013}7").first?.lastVerse, 7,
            "an en-dashed range")
        log.equal(
            ReferenceCheck.scan("Genesis 15:6").first?.lastVerse, nil,
            "a single verse has no range")
        log.equal(
            ReferenceCheck.scan("Gen 1:5-2").first?.lastVerse, nil,
            "a backwards range drops its end")

        // The span covers the reference and **not** the `SEE ALSO` note after it, which
        // runs to the end of the line and is a whole sentence.
        let seeAlso = ReferenceLinks.modelProse(
            "Romans 4:3 \u{2014} Paul quotes this verse.", bible: bible, table: table)
        log.equal(
            links(seeAlso).map(\.text), ["Romans 4:3"],
            "a SEE ALSO line links the reference and not its note")

        // MARK: The URL

        func roundTrip(_ reference: ScriptureReference) -> ScriptureReference? {
            ReferenceLinks.url(reference).flatMap(ReferenceLinks.reference)
        }

        log.equal(
            ReferenceLinks.url(
                ScriptureReference(bookID: "matthew", chapter: 7, verse: 24, lastVerse: 25))?
                .absoluteString, "drb://matthew/7/24-25", "a range's URL")
        for reference in [
            ScriptureReference(bookID: "romans", chapter: 4, verse: 3),
            ScriptureReference(bookID: "john", chapter: 3),
            ScriptureReference(bookID: "matthew", chapter: 7, verse: 24, lastVerse: 25),
            // The hyphenated ids are the ones a naive scheme breaks on, and there are 12
            // of them in this corpus.
            ScriptureReference(bookID: "1-machabees", chapter: 2, verse: 15),
            ScriptureReference(
                bookID: "canticle-of-canticles", chapter: 2, verse: 1, lastVerse: 3),
        ] {
            log.equal(roundTrip(reference), reference, "the round trip for \(reference)")
        }
        // Anything that is not ours comes back nil, so the handler passes it to the
        // system rather than swallowing it.
        log.equal(
            URL(string: "https://example.com/john/3/16").flatMap(ReferenceLinks.reference),
            nil, "another scheme is not ours")
        log.equal(
            URL(string: "drb://john").flatMap(ReferenceLinks.reference), nil,
            "a book with no chapter")

        // MARK: Fabrications

        // `ReferenceCheck`'s stance, carried into running prose: a citation to a verse
        // that does not exist is struck rather than being set in the same typeface as a
        // real one. Both shapes — no such book, and no such chapter in a real book.
        let invented = ReferenceLinks.modelProse(
            "As Hezekiah 4:2 says, and Psalms 151:1 agrees.", bible: bible, table: table)
        log.equal(
            struck(invented), ["Hezekiah 4:2", "Psalms 151:1"],
            "a fabricated reference is struck")
        log.equal(links(invented).count, 0, "and is not tappable")

        // MARK: Challoner's notes

        // The intra-book form, which only means anything relative to the note's own book.
        let intra = ReferenceLinks.note(
            "See chap. 5.3, where the same is said.", in: genesis, chapter: 2,
            bible: bible, table: table)
        log.equal(
            links(intra).map(\.text), ["chap. 5.3"],
            "an intra-book reference links where it stands")
        log.equal(
            links(intra).map(\.url), ["drb://genesis/5/3"],
            "and resolves inside its own book")

        // The named form, with Challoner's period separator.
        log.equal(
            links(
                ReferenceLinks.note(
                    "as in Gen. 2.24, which our Lord cites.", in: genesis, chapter: 1,
                    bible: bible, table: table)
            ).map(\.url), ["drb://genesis/2/24"], "`Gen. 2.24` links to Genesis 2:24")

        // `chap. 8. ver. 20` is matched whole by the intra-book pass and again, from the
        // middle, by the intra-chapter one. Both targets exist here — Genesis 8:20 and,
        // for the enclosed reading, Genesis 19:20 — so only the span says which is meant.
        // One link, over the whole of it, pointing at the enclosing reading.
        let enclosed = ReferenceLinks.note(
            "See above, chap. 8. ver. 20.", in: genesis, chapter: 19, bible: bible,
            table: table)
        log.equal(
            links(enclosed).map(\.text), ["chap. 8. ver. 20"],
            "an enclosed span does not link twice")
        log.equal(
            links(enclosed).map(\.url), ["drb://genesis/8/20"],
            "and links the enclosing reading")

        // The same shape where the enclosing reading does not exist — Genesis 8 has 22
        // verses. Overlaps are resolved before existence is tested, so nothing is linked
        // rather than the enclosed `ver. 31` quietly pointing at Genesis 19:31, which is
        // a verse Challoner was not naming.
        log.equal(
            links(
                ReferenceLinks.note(
                    "See above, chap. 8. ver. 31.", in: genesis, chapter: 19,
                    bible: bible, table: table)
            ).count, 0, "an enclosed span is not linked on its own")

        // **The exemption.** A reference in a 1750 note that does not resolve is far more
        // likely to be this app's parser than Challoner, so it is left exactly as printed
        // — no link and, unlike the model's prose, no strike either.
        let unresolved = ReferenceLinks.note(
            "as in Gen. 99.1, said elsewhere.", in: genesis, chapter: 1, bible: bible,
            table: table)
        log.equal(
            links(unresolved).count, 0,
            "an unresolvable note reference is not linked")
        log.equal(struck(unresolved), [], "and is not struck either")
        log.equal(
            unresolved.runs.count, 1,
            "an unresolvable note reference should come back completely unstyled")
    }

    // MARK: - Patristic check
    private static func patristicCheck(_ log: Log) {
        // Allowed: a generic attribution is honest about how precise it is being.
        for text in [
            "The Fathers read this as a figure of baptism.",
            "The Church has always taken this to mean the Eucharist.",
            "Augustine reads this passage as a figure of the Church.",
            "As the Catechism teaches, this is a sacrament.",
        ] {
            log.equal(
                PatristicCheck.unverified(in: text), [],
                "a generic attribution should pass: \(text)")
        }

        // Flagged: a named work, council, document or number.
        for text in [
            "Augustine, City of God XIV.13, reads this",
            "Aquinas, Summa Theologiae I-II q.94",
            "Chrysostom, Homily 12 on Genesis",
            "CCC 1213 teaches",
            "the Catechism, 1213",
            "Denzinger 1520",
            "the Council of Trent settled this",
            "see \u{00A7}44",
            "Contra Faustum XXII",
        ] {
            log.check(
                !PatristicCheck.unverified(in: text).isEmpty,
                "a specific citation should be flagged: \(text)")
        }

        // The generic/specific line, drawn on the same Father in the same sentence.
        log.equal(
            PatristicCheck.unverified(in: "Augustine reads this as a figure."), [],
            "Augustine with no locator")
        log.check(
            !PatristicCheck.unverified(in: "Augustine, Sermon 51, reads this").isEmpty,
            "Augustine with a locator")

        // Counted separately, so a prompt change that swapped specific citations for
        // generic attributions can be told from one that removed both.
        log.check(
            PatristicCheck.namesAFather("As Jerome observes"), "a bare Father is named")
        log.check(
            !PatristicCheck.namesAFather("The Fathers observe"),
            "a collective is not a name")

        // Deduplicated.
        log.equal(
            PatristicCheck.unverified(in: "CCC 1213, and again CCC 1213").count, 1,
            "deduplicated")
    }

    // MARK: - Cross-references

    /// **Every reference the app would put in a prompt resolves against the corpus.**
    ///
    /// The highest-value check here: a full sweep that runs in milliseconds and is the
    /// only thing that catches a bad import before a reader does. It is written against
    /// the whole corpus rather than a sample precisely because the failure it guards is a
    /// systematic one — a mis-mapped book or an off-by-one in psalm numbering does not
    /// break one reference, it breaks thousands.
    ///
    /// Today it sweeps Challoner's harvested references. When
    /// `Resources/CrossReferences.json` lands it sweeps that too, unchanged.
    private static func crossReferences(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else { return }
        let table = BookTable(bible)
        let store = CrossReferenceStore(bible: bible, table: table)

        var total = 0
        var chaptersWithAny = 0
        for book in bible.books {
            for chapter in book.chapters {
                let found = store.references(
                    for: chapter.rows[...], in: book, chapter: chapter.number)
                if !found.isEmpty { chaptersWithAny += 1 }
                total += found.count

                for reference in found {
                    // The three things a bad import breaks, each of which is silent.
                    log.check(
                        bible.rowIndex(of: reference.reference) != nil,
                        "\(book.id) \(chapter.number): \(reference.label) does not resolve")
                    log.check(
                        !reference.text.isEmpty,
                        "\(book.id) \(chapter.number): \(reference.label) carries no text")
                    log.check(
                        reference.text.split(separator: " ").count
                            <= CrossReferenceStore.wordLimit + 1,
                        "\(book.id) \(chapter.number): \(reference.label) is not truncated")
                }
                log.check(
                    found.count <= CrossReferenceStore.limit,
                    "\(book.id) \(chapter.number) exceeded the cross-reference cap")
            }
        }

        // A floor rather than an exact count: the harvest is a regex over prose, so the
        // number moves with any pattern change, and what matters is that it has not
        // collapsed to nothing. Zero here would mean `SEE ALSO` is dead in every passage
        // and nothing else would say so.
        log.check(
            total >= 200,
            "only \(total) Challoner cross-references harvested across the corpus, which "
                + "is too few for the SEE ALSO section to be doing anything")
        log.check(
            chaptersWithAny >= 100,
            "only \(chaptersWithAny) chapters carry a harvested cross-reference")

        // The intra-book and intra-chapter forms, which are Challoner's own conventions
        // and are meaningless without knowing where they were read. A general reference
        // parser cannot do these, which is why the harvester is separate.
        guard let judges = bible.book("judges") else { return }
        let intra = CrossReferenceStore.harvest(
            "See above, chap. 8. ver. 31.", in: judges, chapter: 19, table: table)
        log.check(
            intra.contains(ScriptureReference(bookID: "judges", chapter: 8, verse: 31)),
            "an intra-book `chap. 8. ver. 31` should resolve inside its own book")
        let sameChapter = CrossReferenceStore.harvest(
            "as at ver. 16", in: judges, chapter: 19, table: table)
        log.check(
            sameChapter.contains(
                ScriptureReference(bookID: "judges", chapter: 19, verse: 16)),
            "a bare `ver. 16` should resolve inside the chapter it was read in")

        // The named form, with Challoner's period separator rather than a colon.
        let named = CrossReferenceStore.harvest(
            "as in Gen. 2.24", in: judges, chapter: 1, table: table)
        log.check(
            named.contains(ScriptureReference(bookID: "genesis", chapter: 2, verse: 24)),
            "`Gen. 2.24` should resolve to Genesis 2:24")
    }

    // MARK: - Random passage

    /// The shuffle button's two pools, as literal regression targets.
    ///
    /// 1,764 note-anchored verses across 72 of the 73 books — only Philemon, a single
    /// chapter, carries none. Pinned the way `corpus` pins 73 / 1,334 / 35,805: a parser
    /// change that dropped half the notes would leave the button working and quietly make
    /// it a much narrower thing.
    private static let anchoredVerses = 1764
    private static let anchoredBooks = 72

    private static func randomPassage(_ log: Log) {
        guard let bible = try? CorpusLoader.load() else {
            log.fail("could not load the corpus for the random-passage checks")
            return
        }
        var draws = RandomPassage(bible: bible)

        // MARK: Tier 1 — the anchors

        log.equal(draws.anchors.count, anchoredVerses, "note-anchored verses")
        log.equal(
            Set(draws.anchors.map(\.bookID)).count, anchoredBooks,
            "books carrying a note-anchored verse")

        // The sweep `crossReferences` does for prompt references, for the same reason: a
        // reference that does not resolve is a press of the button that lands nowhere,
        // and nothing else would say so.
        for anchor in draws.anchors {
            log.check(
                bible.rowIndex(of: anchor) != nil,
                "anchor \(anchor.bookID) \(anchor.chapter):\(anchor.verse ?? 0) "
                    + "does not resolve")
        }

        // MARK: Tier 2 — the prefix sum

        log.equal(
            draws.keys.count, draws.cumulative.count,
            "the tier-2 chapter list against its prefix sum")
        log.check(!draws.keys.isEmpty, "tier 2 has no chapters at all")

        var running = 0
        for (offset, key) in draws.keys.enumerated() {
            guard let chapter = bible.chapter(key) else {
                log.fail("tier-2 chapter \(key.slug) does not resolve")
                continue
            }
            // Both halves of what tier 2 is filtered on. A chapter with no argument would
            // be one the model is asked to explain cold; one with no verses would be a
            // zero-width span of the prefix sum that no draw can ever land in.
            log.check(chapter.argument != nil, "tier-2 chapter \(key.slug) has no argument")
            log.check(chapter.verseCount > 0, "tier-2 chapter \(key.slug) has no verses")
            running += chapter.verseCount
            log.equal(
                draws.cumulative[offset], running,
                "the prefix sum at \(key.slug)")
        }
        log.equal(draws.cumulative.last, running, "the tier-2 pool's verse count")

        // MARK: The draw

        // A few hundred presses. Every one has to resolve, and none may repeat inside the
        // ring — which is the whole reason the ring exists: a dozen presses in one sitting
        // that came back to the same verse would be noticed immediately.
        var window: [ScriptureReference] = []
        let anchored = Set(draws.anchors)
        var reachedOutsideTheAnchors = false
        for press in 0 ..< 400 {
            guard let drawn = draws.draw() else {
                log.fail("draw \(press) came back empty")
                break
            }
            log.check(
                bible.rowIndex(of: drawn) != nil,
                "draw \(press) — \(drawn.bookID) \(drawn.chapter):\(drawn.verse ?? 0) — "
                    + "does not resolve")
            log.check(
                !window.contains(drawn),
                "draw \(press) repeated \(drawn.bookID) \(drawn.chapter):"
                    + "\(drawn.verse ?? 0) inside the \(RandomPassage.ring)-draw ring")
            if !anchored.contains(drawn) { reachedOutsideTheAnchors = true }
            window.append(drawn)
            if window.count > RandomPassage.ring { window.removeFirst() }
        }

        // And that the button is not silently a bookmark list. One draw in four is
        // verse-uniform over the whole Bible, of which the anchors are 5%, so 400 presses
        // that never once left them would mean tier 2 is unreachable.
        log.check(
            reachedOutsideTheAnchors,
            "no draw in 400 came from outside the anchors, so tier 2 — the whole Bible — "
                + "may be unreachable")
    }

    // MARK: - Follow-up parsing

    /// Every allowance in `FollowUps.parse` exists for a way the model has been seen to
    /// break "output exactly four numbered lines and nothing else."
    private static func followUpParsing(_ log: Log) {
        func parse(_ raw: String, asked: Set<String> = []) -> [String] {
            Prompts.FollowUps.parse(raw, asked: asked)
        }

        log.equal(
            parse("1. What does justice mean here?\n2. Why does God speak now?"),
            ["What does justice mean here?", "Why does God speak now?"],
            "a plain numbered list")

        // A preamble line never matches the number pattern and is dropped.
        log.equal(
            parse("Here are your questions:\n1. Who is Abram?"), ["Who is Abram?"],
            "a preamble line")

        // Bullets, brackets and the other separators.
        log.equal(
            parse("- 1) Who is Abram?\n* 2] Why here?"),
            ["Who is Abram?", "Why here?"], "bullets and bracket separators")

        // Bolding, which the model adds unbidden.
        log.equal(parse("1. **Who is Abram?**"), ["Who is Abram?"], "a bolded question")

        // A declarative sentence costumed as a question is rejected rather than given a
        // bare "?".
        log.equal(
            parse("1. It establishes the covenant."), [],
            "a statement is not a question")
        log.equal(
            parse("1. Why does it matter"), ["Why does it matter?"],
            "an interrogative with no question mark gets one")

        // One pair of wrapping quotes, and only a matching pair.
        log.equal(
            parse("1. \u{201C}unto justice\u{201D} \u{2014} what does it mean?"),
            ["\u{201C}unto justice\u{201D} \u{2014} what does it mean?"],
            "a quote at one end only is part of the question")
        log.equal(
            parse("1. \"Who is Abram?\""), ["Who is Abram?"], "a matching pair is stripped")

        // Deduped against what has already been asked, case and punctuation folded.
        log.equal(
            parse("1. Who is Abram?", asked: ["who is abram"]), [],
            "a question already asked")

        // Capped.
        log.equal(
            parse(
                """
                1. Who is Abram?
                2. Why here?
                3. What is justice?
                4. When was this?
                5. How does it end?
                """
            ).count, 4, "capped at four")
    }

    // MARK: - Golden prompt render

    /// One assembled prompt compared against a checked-in string.
    ///
    /// This is what catches prompt drift: any change to the labelled blocks, the verse
    /// render, or the window sizes shows up here as a diff, and the fix is to regenerate
    /// this string *deliberately*, alongside a `Prompts.version` bump.
    private static func goldenPromptRender(_ log: Log) {
        guard let bible = try? CorpusLoader.load(),
            let book = bible.book("genesis"),
            case let key = ChapterKey(bookID: "genesis", chapter: 14),
            let chapter = bible.chapter(key)
        else {
            log.fail("could not load Genesis 14 for the golden render")
            return
        }
        let store = CrossReferenceStore(bible: bible, table: BookTable(bible))

        // Genesis 14:10, which is the one passage that exercises **every** block: a book
        // preface, a chapter argument, both context windows, a Challoner note on the
        // selected verse, and a cross-reference harvested out of that note.
        //
        // Chosen over Genesis 15:6, which is the app's canonical example everywhere else
        // and is a poor golden precisely because it is so clean — it carries no note and
        // no Challoner reference, so two of the seven blocks would be missing and any
        // drift in them would go unnoticed. This one also happens to be the note whose
        // catchword is `Of slime. Bituminis`, the case the parser's dot-run anchoring
        // exists for, so the render doubles as a check that the catchword survived.
        guard
            let start = chapter.rows.firstIndex(where: { $0.isVerse && $0.number == 10 })
        else {
            log.fail("could not find Genesis 14:10")
            return
        }

        let context = PassageContext.build(
            book: book, key: key, chapter: chapter, rows: chapter.rows,
            selection: VerseSelection(at: start), crossReferences: store)
        guard let context else {
            log.fail("the golden context did not build")
            return
        }

        let rendered = Prompts.annotationRequest(context)
        if rendered != Self.goldenPrompt {
            log.fail(
                """
                the golden prompt render drifted. If the change was intended, bump \
                Prompts.version and replace SelfTest.goldenPrompt with:
                ----- begin -----
                \(rendered)
                ----- end -----
                """)
        }

        log.equal(
            context.citation, "Genesis 14:10 · \(Citation.edition)", "the citation")
        log.equal(context.digest.count, 64, "the digest length")

        // The windows, in verses rather than rows.
        log.equal(
            context.preceding.filter { $0.kind == .verse }.count,
            PassageContext.precedingLimit, "the preceding window")
        log.check(!context.following.isEmpty, "the following window")

        // The four authored blocks the whole design rests on. Every one of these is
        // Challoner's own text, read out of the JSON — none is generated, and that is
        // what turns three of the four annotation layers from recall into reading.
        log.check(context.bookPreface != nil, "Genesis has a book preface")
        log.check(context.chapterArgument != nil, "Genesis 14 has a chapter argument")
        log.check(
            context.bookPreface?.count ?? 0 < 400,
            "the preface should be truncated to about two sentences")
        log.equal(context.notes.count, 1, "the note on Genesis 14:10")
        log.equal(
            context.notes.first?.catchword, "Of slime. Bituminis",
            "the catchword the dot-run anchoring exists for")
        log.equal(
            context.crossReferences.map(\.label), ["Genesis 11:3"],
            "the reference harvested from that note")
        log.check(
            !(context.crossReferences.first?.text.isEmpty ?? true),
            "a cross-reference must carry its target verse's own words")

        // Genesis 15:6 is the canonical example everywhere else, and its citation is
        // what the README quotes, so it is pinned here even though the render above uses
        // a richer passage.
        if let fifteen = bible.chapter(ChapterKey(bookID: "genesis", chapter: 15)),
            let sixth = fifteen.rows.firstIndex(where: { $0.isVerse && $0.number == 6 }),
            let canonical = PassageContext.build(
                book: book, key: ChapterKey(bookID: "genesis", chapter: 15),
                chapter: fifteen, rows: fifteen.rows,
                selection: VerseSelection(at: sixth), crossReferences: store)
        {
            log.equal(
                canonical.citation, "Genesis 15:6 · \(Citation.edition)",
                "the canonical citation")
        } else {
            log.fail("could not build the Genesis 15:6 context")
        }

        // MARK: The rendered index space

        // **A selection indexes the rows the reader can see**, which with Challoner's
        // notes turned off is not `chapter.rows`. Everything `build` reads has to come out
        // of the same array the selection was made in, and the citation is the one that
        // used to come out of the other one: it named a verse one earlier per note above
        // the selection, so Romans 4:9 — which has three notes above it — cited as
        // `Romans 4:6`. Silent, and wrong about the only thing a citation asserts.
        //
        // Romans 4 rather than a hand-built chapter, because the bug needs real notes
        // interleaved with real verses to show up at all.
        if let romans = bible.book("romans"),
            case let fourth = ChapterKey(bookID: "romans", chapter: 4),
            let chapter = bible.chapter(fourth)
        {
            let visible = chapter.rows.filter { $0.kind != .note }
            log.check(
                visible.count < chapter.rows.count,
                "Romans 4 carries no notes, so it cannot exercise the rendered index space")

            for rows in [chapter.rows, visible] {
                guard
                    let ninth = rows.firstIndex(where: { $0.isVerse && $0.number == 9 }),
                    let context = PassageContext.build(
                        book: romans, key: fourth, chapter: chapter, rows: rows,
                        selection: VerseSelection(at: ninth), crossReferences: store)
                else {
                    log.fail("could not build the Romans 4:9 context")
                    continue
                }
                let notes = rows.count == chapter.rows.count ? "on" : "off"
                log.equal(
                    context.citation, "Romans 4:9 · \(Citation.edition)",
                    "the Romans 4:9 citation with Challoner's notes \(notes)")
                log.check(
                    context.selected.first?.text.hasPrefix("This blessedness then")
                        ?? false,
                    "the Romans 4:9 selection with Challoner's notes \(notes)")
            }
        } else {
            log.fail("could not load Romans 4")
        }

        // MARK: Passage identity

        // What `ContentView.commit` tests before it decides a tap is a re-tap of the
        // passage already in the pane rather than a new request.
        func built(_ selection: VerseSelection) -> PassageContext? {
            PassageContext.build(
                book: book, key: key, chapter: chapter, rows: chapter.rows,
                selection: selection, crossReferences: store)
        }

        guard let again = built(VerseSelection(at: start)),
            let neighbour = built(VerseSelection(at: start + 1))
        else {
            log.fail("a passage-identity context did not build")
            return
        }
        log.check(context.isSamePassage(as: again), "the same verse rebuilt")
        log.check(!context.isSamePassage(as: neighbour), "the next verse along")

        // MARK: The word budget

        // The floor scales and the two chapter-level sections do not, which is the whole
        // of the retuning. A one-verse selection forced to reach ninety words fills the
        // gap with invention.
        log.equal(Prompts.wordBudget(verses: 1).plainSense, 35 ... 70, "one verse")
        log.equal(Prompts.wordBudget(verses: 5).plainSense, 60 ... 110, "five verses")
        log.equal(Prompts.wordBudget(verses: 17).plainSense, 90 ... 150, "the Decalogue")
        log.equal(
            Prompts.wordBudget(verses: 1).context, Prompts.wordBudget(verses: 17).context,
            "CONTEXT does not scale with the selection")
        log.equal(
            Prompts.wordBudget(verses: 1).tradition,
            Prompts.wordBudget(verses: 17).tradition,
            "THE TRADITION does not scale with the selection")
    }

    // MARK: - Reading progress

    private static func readingProgress(_ log: Log) {
        guard let bible = try? CorpusLoader.load(), let genesis = bible.book("genesis")
        else { return }
        let stamp = genesis.source.textSHA256
        let key = ChapterKey(bookID: "genesis", chapter: 15)

        // No record at all: open at the beginning.
        log.equal(bible.opening(from: nil).key, bible.firstChapter, "cold start")

        // A good record restores both the chapter and the selection.
        let good = ReadingProgress(
            schemaVersion: ProgressStore.schemaVersion, key: key,
            selection: VerseSelection(at: 3), corpusStamp: stamp)
        log.equal(bible.opening(from: good).key, key, "restored chapter")
        log.equal(
            bible.opening(from: good).selection, VerseSelection(at: 3),
            "restored selection")

        // A corpus whose text changed keeps the chapter and drops the selection: the
        // indices may now point at different rows.
        let stale = ReadingProgress(
            schemaVersion: ProgressStore.schemaVersion, key: key,
            selection: VerseSelection(at: 3), corpusStamp: "not-the-same-text")
        log.equal(bible.opening(from: stale).key, key, "stale stamp keeps the chapter")
        log.equal(
            bible.opening(from: stale).selection, nil, "stale stamp drops the selection")

        // A book that no longer exists falls back rather than being handed through:
        // `ContentView` would otherwise spin forever on a key the corpus cannot resolve.
        let gone = ReadingProgress(
            schemaVersion: ProgressStore.schemaVersion,
            key: ChapterKey(bookID: "book-of-eli", chapter: 1),
            selection: nil, corpusStamp: stamp)
        log.equal(bible.opening(from: gone).key, bible.firstChapter, "unknown book")

        let missing = ReadingProgress(
            schemaVersion: ProgressStore.schemaVersion,
            key: ChapterKey(bookID: "genesis", chapter: 99),
            selection: nil, corpusStamp: stamp)
        log.equal(bible.opening(from: missing).key, bible.firstChapter, "unknown chapter")
    }

    /// The checked-in render `goldenPromptRender` compares against.
    ///
    /// **Regenerate on every `Prompts.version` bump, and only then.** A diff here that
    /// nobody intended is prompt drift; a diff that somebody intended is a version bump
    /// they forgot. The failure message prints the new string ready to paste.
    private static let goldenPrompt = """
        BOOK: The Book of Genesis — Old Testament, Pentateuch

        ABOUT THIS BOOK: This book is so called from its treating of the GENERATION, that is, of the creation and the beginning of the world. The Hebrews call it BERESITH, from the Word with which it begins.

        CHAPTER: Genesis 14

        WHAT THIS CHAPTER COVERS: The expedition of the four kings; the victory of Abram; he is blessed by Melchisedech.

        NOTES FROM THIS EDITION (these are the authority where they apply):
          - "Of slime. Bituminis": This was a kind of pitch, which served for mortar in the building of Babel, Gen. 11.3, and was used by Noe in pitching the ark.

        CROSS-REFERENCES (already verified against this Bible — explain these and no others):
          - Genesis 11:3 — "And each one said to his neighbour: Come let us make brick, and bake them with fire. And they had brick instead of stones, and…"

        THE FOUR SENSES: literal (what happened, or what the words say); allegorical (what it shows about Christ and the Church); moral (how it bears on how a person should live); anagogical (what it shows about the last things).

        BEFORE (4-9):
          4. For they had served Chodorlahomor twelve years, and in the thirteenth year they revolted from him.
          5. And in the fourteenth year came Chodorlahomor, and the kings that were with him: and they smote the Raphaim in Astarothcarnaim, and the Zuzim with them, and the Emim in Save of Cariathaim.
          6. And the Chorreans in the mountains of Seir, even to the plains of Pharan, which is in the wilderness.
          7. And they returned, and came to the fountain of Misphat, the same is Cades: and they smote all the country of the Amalecites, and the Amorrhean that dwelt in Asasonthamar.
          8. And the king of Sodom, and the king of Gomorrha, and the king of Adama, and the king of Seboim, and the king of Bala, which is Segor, went out: and they set themselves against them in battle array, in the woodland vale:
          9. To wit, against Chodorlahomor king of the Elamites, and Thadal king of nations, and Amraphel king of Sennaar, and Arioch king of Pontus: four kings against five.

        SELECTED PASSAGE (10):
          10. Now the woodland vale had many pits of slime. And the king of Sodom, and the king of Gomorrha turned their backs, and were overthrown there: and they that remained, fled to the mountain.

        AFTER (11-12):
          11. And they took all the substance of the Sodomites, and Gomorrhites, and all their victuals, and went their way:
          12. And Lot also, the son of Abram’s brother, who dwelt in Sodom, and his substance.

        THE MOMENT: This is verse 10 of Genesis 14, which has 24 verses. This edition prints 1 note on it, given above; it is the authority. Nothing after verse 10 has happened yet, so do not write as if it had.

        Write exactly these four sections, in this order, each opening with its label in capitals followed by a colon. Nothing before the first label and nothing after the last section.

        PLAIN SENSE: 35-70 words. What the selected passage says, in modern English. Put the archaic or hard wording into words a reader today uses.

        CONTEXT: 30-60 words. Who wrote it and for whom, roughly when, what kind of writing it is, and where this passage sits in the book.

        SEE ALSO: up to 3 lines. Each line is one of the cross-references you were given, then an em dash, then what it has to do with this passage in a few words of your own. Only those references — not this passage's own, and none you thought of yourself. **If you were given none, leave this label out altogether rather than writing it with nothing under it.**

        THE TRADITION: 30-60 words. How the Church has read this passage: the four senses where they apply, and what this edition's own notes say. No named works, no numbers, no citations.

        Stop when you have said what the passage means — do not pad any section to its upper figure, and leave a section out rather than filling it.
        """
}
