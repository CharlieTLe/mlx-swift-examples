// Copyright © 2026 Apple Inc.

import Foundation

/// Project Gutenberg’s transcription markup, turned into text plus spans.
///
/// The corpus is parsed straight out of Gutenberg and keeps what the transcription
/// uses: `_..._` marks an italic span, a stage direction is bracketed (`[_Exit._]`)
/// or not (`Enter Francisco and Barnardo, two sentinels.`), and `&c.` stands where a
/// modern edition prints `etc.` Left alone, Hamlet I.v renders as
/// `_Hic et ubique?_ Then we’ll shift our ground.` — underscores and all — and that
/// same string goes into the annotation prompt.
///
/// Pure, `Sendable` and deliberately **not** `@MainActor`, the same shape as
/// `WordTokenizer` and `NavigatorSearch`, so `--selftest` can assert against it. It
/// lives in `Corpus/` because `Line.plainText` depends on it and `PlayModel` must stay
/// clear of SwiftUI and CoreText.
///
/// Two facts about the corpus decide the design, and both were measured across all 35
/// plays rather than assumed:
///
/// - **A span crosses lines.** 361 speech lines carry an odd number of underscores,
///   because the span opens on one line and closes several later — Ophelia's letter
///   runs eight lines of Hamlet II.ii, from `_Doubt thou the stars are fire,` to
///   `HAMLET._`. So a span cannot be resolved one line at a time.
/// - **A span is balanced within one *block*.** In Gutenberg's own HTML every `<i>`
///   closes inside its `<p>`, and treating a speech heading or a stage direction as a
///   block boundary balances every block in the corpus but one — `titus-andronicus`
///   I.i, where the source splits a single direction across two records. An unpaired
///   underscore is therefore dropped rather than allowed to leak italic into the rest
///   of the scene.
enum GutenbergMarkup {

    /// The line without its markup. What `Line.plainText` returns.
    ///
    /// The short-circuit is not a micro-optimization looking for a home: this is called
    /// on every `onContinuousHover` tick by way of `LineRow.resolvedWord(at:)`, and
    /// about 95% of the corpus has neither mark in it, so it is the difference between
    /// a per-event allocation and none.
    static func strip(_ text: String) -> String {
        guard
            text.utf8.contains(where: {
                $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "&")
            })
        else { return text }
        return scan(text).text
    }

    /// `etc.`, spelled out. 31 lines across 15 plays abbreviate it the way the
    /// compositor did — `Enter priests, &c, in procession`, `Shall Rome, &c.` — and a
    /// modern edition prints `etc.` Unlike the underscores and brackets around it this
    /// is the edition's own text rather than transcription markup, so it is a
    /// modernization and not a strip; it is here because it has to happen in the same
    /// pass, or the italic spans would be measured against a different string than the
    /// one drawn.
    private static let etCetera = "etc."

    /// The text without its markup, and the offset of every underscore in that output.
    ///
    /// **One implementation, deliberately.** `strip` and the span scanner used to walk
    /// the line separately and had to be asserted to agree; expanding `&c.` — the one
    /// substitution here that changes the line's *length* — is what made two of them
    /// untenable, since a disagreement of one UTF-16 unit silently slides every span
    /// after it.
    private static func scan(_ text: String) -> (text: String, marks: [Int]) {
        var out = ""
        out.reserveCapacity(text.count)
        var marks: [Int] = []
        var offset = 0
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "_" {
                marks.append(offset)
                index = text.index(after: index)
                continue
            }
            if character == "&", let end = etCeteraEnd(in: text, at: index) {
                out += etCetera
                offset += etCetera.utf16.count
                index = end
                continue
            }
            out.append(character)
            offset += character.utf16.count
            index = text.index(after: index)
        }
        return (out, marks)
    }

    /// The index just past `&c` or `&c.`, if that is what starts at `index`.
    ///
    /// `nil` for a bare ampersand, which is what keeps the two joint speech headings
    /// the parser leaves sitting in speech text — `PRINCE & POINS.` and
    /// `GLOUCESTER & CLARENCE.` — from becoming `PRINCE etc. POINS.` A following
    /// letter or digit is rejected for the same reason, so a hypothetical `&created`
    /// is left alone.
    ///
    /// A trailing period is *consumed*, because `etCetera` brings its own; a trailing
    /// comma is not, so `Enter priests, &c, in procession` reads `etc.,` and keeps the
    /// comma it was punctuated with.
    private static func etCeteraEnd(in text: String, at index: String.Index) -> String.Index? {
        let afterAmpersand = text.index(after: index)
        guard afterAmpersand < text.endIndex, text[afterAmpersand] == "c" else { return nil }

        let afterC = text.index(after: afterAmpersand)
        guard afterC < text.endIndex else { return afterC }
        if text[afterC] == "." { return text.index(after: afterC) }
        guard !text[afterC].isLetter, !text[afterC].isNumber else { return nil }
        return afterC
    }

    /// The italic spans of one block, as UTF-16 ranges of each line's stripped text.
    ///
    /// **UTF-16 offsets and not `Range<String.Index>`**, because `plainText` is a
    /// *computed* property: a caller holds a different `String` instance than the one
    /// these were measured against, and a `String.Index` from one is not valid in the
    /// other. `WordHitTest` speaks `utf16Offset` for the same reason.
    ///
    /// Two passes, because "drop the odd one out" cannot be decided forward-only — an
    /// underscore is only known to be unpaired once the whole block has been read.
    static func italics(inBlock lines: [String]) -> [[Range<Int>]] {
        // Pass 1: every underscore's position in the *output* coordinate space, which
        // is the space the ranges are reported in. `scan` is the same walk `strip`
        // makes, so the offsets are measured against exactly the string that is drawn.
        var lengths = [Int](repeating: 0, count: lines.count)
        var marks: [(line: Int, offset: Int)] = []
        for (index, text) in lines.enumerated() {
            let scanned = scan(text)
            lengths[index] = scanned.text.utf16.count
            marks.append(contentsOf: scanned.marks.map { (index, $0) })
        }

        // Pass 2: the marks are flattened block-wide, so a span that opens on one line
        // and closes on another pairs exactly as one that opens and closes on the same
        // line does.
        var result = [[Range<Int>]](repeating: [], count: lines.count)
        if !marks.count.isMultiple(of: 2) { marks.removeLast() }
        for pair in stride(from: 0, to: marks.count, by: 2) {
            let open = marks[pair]
            let close = marks[pair + 1]

            guard open.line != close.line else {
                if open.offset < close.offset {
                    result[open.line].append(open.offset ..< close.offset)
                }
                continue
            }
            if open.offset < lengths[open.line] {
                result[open.line].append(open.offset ..< lengths[open.line])
            }
            for line in (open.line + 1) ..< close.line where lengths[line] > 0 {
                result[line].append(0 ..< lengths[line])
            }
            if close.offset > 0 {
                result[close.line].append(0 ..< close.offset)
            }
        }
        return result
    }

    /// A whole scene, segmented into blocks. One entry per line, aligned to
    /// `Scene.lines`.
    ///
    /// Directions get `[]`: they are drawn italic end to end by `LineRow`, so marking
    /// spans inside one would say nothing. They are still block *boundaries* — no span
    /// in the corpus crosses a direction, so closing there is free and strictly safer
    /// than letting one try.
    static func italics(in lines: [Line]) -> [[Range<Int>]] {
        var result = [[Range<Int>]](repeating: [], count: lines.count)
        var index = 0
        while index < lines.count {
            guard !lines[index].isDirection else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, !lines[end].isDirection, !lines[end].startsSpeech {
                end += 1
            }
            let spans = italics(inBlock: lines[index ..< end].map(\.text))
            for (offset, ranges) in spans.enumerated() where !ranges.isEmpty {
                result[index + offset] = ranges
            }
            index = end
        }
        return result
    }
}
