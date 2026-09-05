// Copyright © 2026 Apple Inc.

import Foundation

/// Checks the model's quotations against the lines it was given.
///
/// The one check in this app that needs no model, costs no latency, and cannot be
/// argued with. Three prompt rules have each failed to stop the same two things — a
/// follow-up row quoting `ye soft-voiced, weak-tempered, fleshy-limbed`, which is in
/// none of the 36 plays, and rows quoting `The canker galls the infants of the
/// spring`, which is real verse from thirteen lines outside the selection. Both are
/// decidable by string comparison against the passage the model was handed.
///
/// It **reports and does not strip.** A quoted span that fails is evidence about a
/// prompt, and half of what this app has learned came from reading exactly these
/// failures; deleting them before anyone sees them would spend the signal to tidy the
/// symptom. What the reader sees is a separate decision, deliberately not taken here.
enum QuoteCheck {

    /// Quoted spans in `text` that do not appear in `passage`.
    ///
    /// Only double quotes, straight or curly. Single quotes are excluded and that is
    /// not laziness: early modern verse is full of elisions — `o'er`, `'tis`,
    /// `pursu'd` — so an apostrophe is not a reliable quotation mark in this corpus.
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
    /// Openers and closers are pooled rather than paired, because the model mixes
    /// straight and curly within one sentence and a strict pairing drops those.
    private static func spans(in text: String) -> [String] {
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
    /// The corpus sets `pursu’d` with U+2019 and the model writes `pursu'd`, which is
    /// the same quotation and must not be reported as an invention. Punctuation is
    /// otherwise kept: a quotation that adds or moves a comma is still a misquotation,
    /// just a mild one, and this is a diagnostic rather than a gate.
    private static func normalized(_ text: String) -> String {
        var folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        folded = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded
    }
}
