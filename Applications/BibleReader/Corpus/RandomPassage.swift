// Copyright © 2026 Apple Inc.

import Foundation

/// Where the shuffle button lands.
///
/// **Not a uniform draw over the 35,805 verses**, which would spend most presses in a
/// genealogy or a tribal allotment, and not a curated highlights list either — that would
/// be somebody's taste, maintained by hand, and it would make the button a bookmark bar.
///
/// Two tiers instead, rolled per draw:
///
/// **Tier 1, three draws in four** — uniform over the 1,764 verses Challoner himself hung
/// a note on. Wide and well spread rather than a highlights reel: those verses span 72 of
/// the 73 books (only Philemon, one chapter, has none) and the largest single share is
/// Psalms at about 8%. It is also the pool where the annotation is *worth reading*, since
/// a note-anchored passage puts Challoner's own note in the prompt as the stated
/// authority — the retrieve-and-explain case, rather than the recall case a 4B model does
/// badly.
///
/// **Tier 2, one draw in four** — verse-uniform over every verse of a chapter that
/// carries an argument, so the whole Bible stays reachable. *Verse*-uniform and not
/// *chapter*-uniform deliberately: drawing a chapter first would give each of Abdias' 21
/// verses 150× the odds of a verse of Psalms.
///
/// **It hands back a `ScriptureReference` and never a row index**, which is the one real
/// trap in the feature. A `VerseSelection` indexes the *rendered* rows, and those differ
/// from `Chapter.rows` by one per note whenever the reader has Challoner's notes turned
/// off — which is exactly why `ContentView.rowIndex(of:in:)` exists alongside
/// `Bible.rowIndex(of:)`. Returning a reference leaves that already-solved question where
/// it is solved.
///
/// Derived from the corpus, built once, no I/O — `CrossReferenceStore`'s shape.
struct RandomPassage: Sendable {
    private let bible: Bible

    /// Tier 1: every verse with at least one of Challoner's notes hung on it. 1,764 of
    /// them, and `SelfTest.randomPassage` pins that as a regression target.
    let anchors: [ScriptureReference]

    /// Tier 2's chapters, and the prefix sum of their verse counts. Two flat arrays of
    /// 1,296 entries rather than one array of 34,773 references: a binary search into the
    /// sum picks a verse-uniform chapter for the price of the chapter list.
    let keys: [ChapterKey]
    let cumulative: [Int]

    /// The last few draws, skipped so that pressing ⌘⇧R a dozen times does not repeat.
    /// Bounded the way `NavigationHistory` is, and for the same reason: it is a
    /// convenience, and an unbounded one buys nothing past the first few.
    private(set) var recent: [ScriptureReference] = []

    static let ring = 25

    /// One draw in this many falls through to tier 2 — the whole Bible rather than the
    /// annotated part of it.
    static let wholeBibleOdds = 4

    /// How many times a draw resamples to get out of the ring. The pools are 70× and
    /// 1,400× the ring, so a single retry would almost always do; the extra ones are
    /// there so the no-repeat promise does not rest on "almost".
    static let retries = 8

    init(bible: Bible) {
        self.bible = bible

        var anchors: [ScriptureReference] = []
        var keys: [ChapterKey] = []
        var cumulative: [Int] = []
        var running = 0

        for book in bible.books {
            for chapter in book.chapters {
                // A verse is note-anchored if a note follows it before the next verse
                // does. `pending` is cleared as the note claims it, so two notes on one
                // verse are one anchor rather than two.
                var pending: Int?
                for row in chapter.rows {
                    switch row.kind {
                    case .verse:
                        pending = row.number
                    case .note:
                        guard let verse = pending else { continue }
                        anchors.append(
                            ScriptureReference(
                                bookID: book.id, chapter: chapter.number, verse: verse))
                        pending = nil
                    case .sectionHeading:
                        // A stanza rubric between a verse and its note does not break the
                        // pairing; it is typography.
                        break
                    }
                }

                // The argument is what tier 2 is filtered on, and it is not a proxy for
                // quality: it is the block `PassageContext` puts at the head of the
                // prompt, so a chapter without one is a chapter the model would be asked
                // to explain cold.
                guard chapter.argument != nil, chapter.verseCount > 0 else { continue }
                running += chapter.verseCount
                keys.append(ChapterKey(bookID: book.id, chapter: chapter.number))
                cumulative.append(running)
            }
        }

        self.anchors = anchors
        self.keys = keys
        self.cumulative = cumulative
    }

    /// Rolls the tier, samples, and records what it returns.
    ///
    /// `nil` only for a corpus with nothing in it, which the loader would already have
    /// refused.
    mutating func draw() -> ScriptureReference? {
        var drawn: ScriptureReference?
        for _ in 0 ..< Self.retries {
            guard let candidate = sample() else { return nil }
            drawn = candidate
            if !recent.contains(candidate) { break }
        }
        guard let drawn else { return nil }

        recent.append(drawn)
        if recent.count > Self.ring { recent.removeFirst() }
        return drawn
    }

    private func sample() -> ScriptureReference? {
        if Int.random(in: 0 ..< Self.wholeBibleOdds) == 0 { return anyVerse() }
        return anchors.randomElement() ?? anyVerse()
    }

    /// Tier 2. Picks a verse out of the whole pool, then finds the chapter it fell in.
    private func anyVerse() -> ScriptureReference? {
        guard let total = cumulative.last, total > 0 else { return nil }
        let target = Int.random(in: 0 ..< total)
        let index = chapterIndex(containing: target)
        let key = keys[index]
        let start = index == 0 ? 0 : cumulative[index - 1]

        guard let chapter = bible.chapter(key) else { return nil }
        let verses = chapter.verses
        let offset = target - start
        guard verses.indices.contains(offset), let number = verses[offset].number
        else { return nil }
        return ScriptureReference(bookID: key.bookID, chapter: key.chapter, verse: number)
    }

    /// The first chapter whose running total is past `target` — a binary search, since
    /// `cumulative` is sorted by construction.
    private func chapterIndex(containing target: Int) -> Int {
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
