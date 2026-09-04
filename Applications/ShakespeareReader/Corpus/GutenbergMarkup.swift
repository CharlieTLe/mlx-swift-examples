// Copyright © 2026 Apple Inc.

import Foundation

/// Project Gutenberg's transcription markup, turned into text plus spans.
///
/// The corpus is parsed straight out of Gutenberg and keeps what the transcription
/// uses: `_..._` marks an italic span, and a stage direction is bracketed (`[_Exit._]`)
/// or not (`Enter Francisco and Barnardo, two sentinels.`). Left alone, Hamlet I.v
/// renders as `_Hic et ubique?_ Then we’ll shift our ground.` — underscores and all —
/// and that same string is what goes into the annotation prompt.
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
    /// about 95% of the corpus has no underscore in it, so it is the difference between
    /// a per-event allocation and none.
    static func strip(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "_")) else { return text }
        return text.replacingOccurrences(of: "_", with: "")
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
        // is the space the ranges are reported in. The running offset is accumulated
        // rather than re-measured; asking `out.utf16.count` inside the loop is
        // quadratic in the length of the line.
        var lengths = [Int](repeating: 0, count: lines.count)
        var marks: [(line: Int, offset: Int)] = []
        for (index, text) in lines.enumerated() {
            var count = 0
            for character in text {
                guard character != "_" else {
                    marks.append((index, count))
                    continue
                }
                count += character.utf16.count
            }
            lengths[index] = count
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
