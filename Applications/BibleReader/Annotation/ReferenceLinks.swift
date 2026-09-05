// Copyright © 2026 Apple Inc.

import Foundation
import SwiftUI

/// Every scripture reference in the app's prose, turned into somewhere you can go.
///
/// The `SEE ALSO` list was the only tappable reference in the app, and it is the smallest
/// share of them. The model writes references in running prose throughout `PLAIN SENSE`,
/// `CONTEXT` and `THE TRADITION`, and above all in answers to follow-up questions — an
/// answer about the parables names a dozen of them and every one was dead text. Challoner
/// has the same problem from the other direction: his notes are full of real `Gen. 2.24`
/// and `chap. 5.3` references that `CrossReferenceStore` already harvests at load and the
/// reader still could not click.
///
/// **Inline links resolve on existence, not on provenance.** `CheckedReference`'s
/// supplied/`.ungiven` distinction is right where it lives — the `SEE ALSO` list, where
/// the *connection* is the claim being made and an invented one must not look like a
/// citation. In running prose there is no such claim: the only question is whether the
/// passage is in this Bible, and a free-form answer reaches outside the supplied set by
/// definition. So `ReferenceCheck.check` and `referenceRows` are untouched, and this is a
/// second, looser reading of the same spans.
///
/// A `.link` run rather than the app's `Button`-per-reference house pattern, because a
/// `Button` cannot sit inside a line of flowing text and that is the entire requirement.
/// Nothing registers `drb` in either `Info.plist`: `ContentView` installs an
/// `OpenURLAction`, which intercepts before the system, so the link never leaves the
/// process.
enum ReferenceLinks {
    /// The scheme, which exists only to be recognised by the handler two files away.
    static let scheme = "drb"

    /// `drb://romans/4/3-7`, `drb://1-machabees/2`.
    ///
    /// Book ids are already URL-safe — they are the JSON filenames, `1-machabees` and
    /// `canticle-of-canticles` — so the host and path need no escaping.
    static func url(_ reference: ScriptureReference) -> URL? {
        var path = "\(scheme)://\(reference.bookID)/\(reference.chapter)"
        if let verse = reference.verse {
            path += "/\(verse)"
            if let last = reference.lastVerse, last != verse { path += "-\(last)" }
        }
        return URL(string: path)
    }

    /// The other direction. `nil` for anything that is not one of ours, which the handler
    /// passes back to the system rather than swallowing.
    static func reference(_ url: URL) -> ScriptureReference? {
        guard url.scheme == scheme, let bookID = url.host(), !bookID.isEmpty else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first, let chapter = Int(first) else { return nil }

        guard parts.count > 1 else {
            return ScriptureReference(bookID: bookID, chapter: chapter)
        }
        let verses = parts[1].split(separator: "-").compactMap { Int($0) }
        guard let verse = verses.first else { return nil }
        return ScriptureReference(
            bookID: bookID, chapter: chapter, verse: verse,
            lastVerse: verses.count > 1 ? verses[1] : nil)
    }

    /// The model's prose: every reference that resolves becomes a link, and every one that
    /// does not is struck through.
    ///
    /// The strike is `ReferenceCheck`'s stance carried into running text, and for its
    /// reason: a citation to a verse that does not exist, set in the same typeface as one
    /// that does, is the app asserting a false fact about the Bible to a reader who has no
    /// way to check it. Nothing is deleted — the words stay exactly where the model put
    /// them.
    static func modelProse(_ text: String, bible: Bible, table: BookTable) -> AttributedString {
        var string = AttributedString(text)
        // Back to front, so an earlier span's offsets are still valid after a later one
        // has been styled.
        for hit in ReferenceCheck.scan(text).reversed() {
            guard let range = attributedRange(hit.range, of: text, in: string) else {
                continue
            }
            guard let resolution = table.resolve(hit.book) else {
                string[range].strikethroughStyle = Text.LineStyle.single
                continue
            }
            let reference = hit.reference(in: resolution.bookID)
            guard bible.rowIndex(of: reference) != nil else {
                string[range].strikethroughStyle = Text.LineStyle.single
                continue
            }
            link(&string, range, to: reference)
        }
        return string
    }

    /// Challoner's notes: what resolves becomes a link, and **what does not is left
    /// completely alone**.
    ///
    /// The one place this departs from treating all prose alike, and the asymmetry is the
    /// point. A reference the model invented is the model's fault. A reference in a 1750
    /// note that fails to resolve is almost certainly this app's fault — the harvester is
    /// three regexes over an OCR'd transcription of an eighteenth-century printing — and
    /// striking Challoner through because our parser mis-read him would be the app
    /// asserting a false fact of its own.
    static func note(
        _ text: String, in book: Book, chapter: Int, bible: Bible, table: BookTable
    ) -> AttributedString {
        var string = AttributedString(text)
        apply(
            resolvable(text, in: book, chapter: chapter, bible: bible, table: table),
            to: &string, of: text)
        return string
    }

    /// Links a note's spans into a string already being built for other reasons.
    ///
    /// `VerseRow` needs this rather than `note(_:in:chapter:bible:table:)` because its
    /// `AttributedString` is not this function's to make: the catchword's italic run goes
    /// on first, and the hovered word's underline goes on after, so a link is the middle
    /// of three passes over one string.
    static func apply(
        _ hits: [CrossReferenceStore.Hit], to string: inout AttributedString, of text: String
    ) {
        // Back to front, so an earlier span's offsets are still valid after a later one
        // has been styled.
        for hit in hits.reversed() {
            guard let range = attributedRange(hit.range, of: text, in: string) else {
                continue
            }
            link(&string, range, to: hit.reference)
        }
    }

    /// The links a note carries, front to back and non-overlapping.
    ///
    /// Internal so `VerseRow` can hold the spans in `@State` rather than re-running three
    /// regexes on every hover event.
    ///
    /// Overlaps are resolved **before** existence is tested, and that order is the whole
    /// of the correctness here. `chap. 8. ver. 31` is one reference, and the enclosing
    /// span is the one that reads it right; filtering first would drop it wherever the
    /// target chapter is short and leave the enclosed `ver. 31` to link to a verse of the
    /// current chapter that Challoner was not pointing at.
    static func resolvable(
        _ text: String, in book: Book, chapter: Int, bible: Bible, table: BookTable
    ) -> [CrossReferenceStore.Hit] {
        var kept: [CrossReferenceStore.Hit] = []
        let hits = CrossReferenceStore.scan(text, in: book, chapter: chapter, table: table)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        for hit in hits {
            guard kept.last.map({ hit.range.lowerBound >= $0.range.upperBound }) ?? true
            else { continue }
            kept.append(hit)
        }
        return kept.filter { bible.rowIndex(of: $0.reference) != nil }
    }

    /// What a link looks like: the accent colour, and **no underline set**.
    ///
    /// A reference in the middle of a sentence is not a web link, and underlining a dozen
    /// of them in one answer would make the paragraph unreadable. `Text` does not underline
    /// a `.link` run on its own, so the colour is the whole of it — which is what the
    /// `SEE ALSO` rows already use, so a reference reads the same in a list and in a line.
    private static func link(
        _ string: inout AttributedString, _ range: Range<AttributedString.Index>,
        to reference: ScriptureReference
    ) {
        guard let url = url(reference) else { return }
        string[range].link = url
        string[range].foregroundColor = .accentColor
    }

    /// A source range, in the coordinates an `AttributedString` is subscripted by. The
    /// same crossing `VerseRow.attributedRange` makes, and it can fail for the same
    /// reason: the two are separate views of the string and an index is only valid in one.
    private static func attributedRange(
        _ span: Range<String.Index>, of text: String, in string: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let lower = AttributedString.Index(span.lowerBound, within: string),
            let upper = AttributedString.Index(span.upperBound, within: string)
        else { return nil }
        return lower ..< upper
    }

    /// The same, from UTF-16 offsets — which is how a note's spans travel, since they are
    /// held across renders of a row whose text is recomputed. `VerseRow.attributedRange`
    /// does this for the catchword's italic run; this is that function for a link.
    private static func attributedRange(
        _ span: Range<Int>, of text: String, in string: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard span.lowerBound >= 0, span.lowerBound < span.upperBound,
            span.upperBound <= text.utf16.count
        else { return nil }
        return attributedRange(
            String.Index(utf16Offset: span.lowerBound, in: text)
                ..< String.Index(utf16Offset: span.upperBound, in: text),
            of: text, in: string)
    }
}
