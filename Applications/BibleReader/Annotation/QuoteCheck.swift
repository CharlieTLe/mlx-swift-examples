// Copyright © 2026 Apple Inc.

import Foundation

/// Checks the model's quotations against the verses it was given.
///
/// Ported **verbatim** from ShakespeareReader, mechanism and normalization alike. It is
/// the one check in this app that needs no model, costs no latency, and cannot be
/// argued with: a quoted span either appears in the passage the model was handed or it
/// does not, and that is decidable by string comparison.
///
/// It matters more here than it did there. A 4B model asked about scripture will
/// confidently quote a verse it half-remembers from a different translation — the King
/// James wording of a Douay-Rheims verse is the common case — and the reader has no way
/// to tell that from the edition in front of them. `ReferenceCheck` is the sibling that
/// handles the other half: a citation that names a verse rather than quoting one.
///
/// It **reports and does not strip.** A quoted span that fails is evidence about a
/// prompt, and half of what this app has learned came from reading exactly these
/// failures; deleting them before anyone sees them would spend the signal to tidy the
/// symptom. What the reader sees is a separate decision, deliberately not taken here.
enum QuoteCheck {

    /// Quoted spans in `text` that do not appear in `passage`.
    ///
    /// Only double quotes, straight or curly. Single quotes are excluded and that is
    /// not laziness: this translation is full of elisions and possessives — `o'er`,
    /// `the Lord's` — so an apostrophe is not a reliable quotation mark in this corpus.
    static func unsupported(in text: String, passage: String) -> [String] {
        let haystack = normalized(passage)
        return spans(in: text)
            .filter { $0.count >= minimumLength }
            .filter { !haystack.contains(normalized($0)) }
    }

    /// Below this a "quotation" is punctuation or an initial, and matching it proves
    /// nothing either way.
    private static let minimumLength = 3

    /// The contents of every double-quoted run, in order.
    ///
    /// Internal rather than private, unlike ShakespeareReader's, because
    /// `ReferenceCheck.quotedVerse` needs the same spans against a different haystack —
    /// the whole Bible rather than the selected passage. Two scanners would be two things
    /// to keep in step about what a quotation is.
    ///
    /// Openers and closers are pooled rather than paired, because the model mixes
    /// straight and curly within one sentence and a strict pairing drops those.
    static func spans(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in text {
            if character == "\"" || character == "“" || character == "”" {
                if let open = current {
                    found.append(open)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Case, whitespace and the transcription's curly apostrophes all folded away.
    ///
    /// Internal for `ReferenceCheck`'s sake, as `spans(in:)` is: the two checks have to
    /// agree about what counts as the same words, or a quotation would pass one and fail
    /// the other on nothing but an apostrophe.
    ///
    /// The Douay-Rheims is typeset with U+2019 throughout — `the Lord’s anointed` — and
    /// the model writes `the Lord's`, which is the same quotation and must not be
    /// reported as an invention. Punctuation is
    /// otherwise kept: a quotation that adds or moves a comma is still a misquotation,
    /// just a mild one, and this is a diagnostic rather than a gate.
    static func normalized(_ text: String) -> String {
        var folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        folded = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded
    }
}
