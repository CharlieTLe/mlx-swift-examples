// Copyright © 2026 Apple Inc.

import Foundation

/// Flags specific patristic and magisterial citations, which a 4B model cannot get right.
///
/// The third of the three checks, and the only one that is about a *kind* of claim
/// rather than about a string. `QuoteCheck` decides whether a quotation is in the
/// passage; `ReferenceCheck` decides whether a verse exists. Neither can touch
/// "Augustine, *City of God* XIV.13", because there is no offline corpus here to check it
/// against — and that is exactly the problem, since there is none for the reader either.
///
/// **What a 4B model does with these is a coin flip on the work and near-certain to be
/// wrong on the locator.** It is confident, it is specific, it is formatted like a
/// footnote, and it is unverifiable. That combination is the worst one an app can put in
/// front of someone: a reader who could evaluate the claim would not need the app, and a
/// reader who needs the app cannot evaluate the claim.
///
/// So the rule is a line drawn by *precision*, not by subject:
///
/// - **Allowed:** "the Fathers read this as a figure of baptism", "the Church has always
///   taken this to mean". A generic attribution is honest about how precise it is being.
/// - **Flagged:** any named work, council, document or number. `Summa I-II q.94`,
///   `CCC 1213`, `Homily 12 on Genesis`, `Denzinger 1520`, `Council of Trent`. A fake
///   footnote is not honest about anything.
///
/// The prompt forbids these outright and this catches what the prompt does not hold. Like
/// `QuoteCheck`, it **reports and does not strip**: the sentence stays, the pane marks it
/// unverified, and the count reaches the diagnostics strip where a rise in it is the
/// signal that a prompt change made things worse.
enum PatristicCheck {

    /// The specific citations in `text`, in order, deduplicated.
    static func unverified(in text: String) -> [String] {
        var seen: Set<String> = []
        var found: [String] = []
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)

        for pattern in patterns {
            for match in pattern.matches(in: text, range: range) {
                guard let swift = Range(match.range, in: text) else { continue }
                let citation = String(text[swift])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard seen.insert(citation.lowercased()).inserted else { continue }
                found.append(citation)
            }
        }
        return found
    }

    /// Whether `text` names a Father at all, with or without a locator.
    ///
    /// Not itself a finding — a bare "as Augustine says" is allowed — but it is what the
    /// diagnostics strip counts separately, so a prompt change that swaps specific
    /// citations for generic attributions can be told from one that removed both.
    static func namesAFather(_ text: String) -> Bool {
        fathers.firstMatch(
            in: text, range: NSRange(text.startIndex ..< text.endIndex, in: text)) != nil
    }

    /// The Fathers and Doctors a model reaches for most, as a bare name check.
    ///
    /// Deliberately a short list of the ones that actually show up rather than an attempt
    /// at completeness: a name not on it produces a missed flag, which is the cheap
    /// failure, and a list long enough to be exhaustive would start matching ordinary
    /// words. `Jerome`, `Ambrose` and `Basil` are also given names, which is why this is
    /// only consulted for `namesAFather` and never on its own produces a finding.
    private static let fathers = try! NSRegularExpression(
        pattern: #"\b(Augustine|Jerome|Chrysostom|Ambrose|Origen|Tertullian|Irenaeus"#
            + #"|Athanasius|Basil|Gregory|Cyprian|Cyril|Aquinas|Bede|Bonaventure"#
            + #"|Anselm)\b"#)

    /// Every shape of specific citation, each with the precision that makes it a problem.
    private static let patterns: [NSRegularExpression] = [
        // A Father plus a locator: "Augustine, City of God XIV.13", "Chrysostom, Homily
        // 12". The locator is what turns an attribution into a footnote.
        try! NSRegularExpression(
            pattern: #"\b(?:Augustine|Jerome|Chrysostom|Ambrose|Origen|Tertullian"#
                + #"|Irenaeus|Athanasius|Basil|Gregory|Cyprian|Cyril|Aquinas|Bede"#
                + #"|Bonaventure|Anselm)\b[^.\n]{0,60}?"#
                + #"(?:\b(?:[IVXLC]+\.\d+|\d+\.\d+|\bq\.\s*\d+|\bn\.\s*\d+)|\b\d{1,4}\b)"#),
        // A named work, with or without a Father attached.
        try! NSRegularExpression(
            pattern: #"\b(?:Summa(?:\s+Theologi(?:ae|ca))?|Contra\s+[A-Z][A-Za-z]+"#
                + #"|City\s+of\s+God|De\s+[A-Z][A-Za-z]+|Confessions|Enchiridion"#
                + #"|Catena\s+Aurea)\b[^.\n]{0,40}"#),
        // A homily, tract, letter, book or question with a number on it.
        try! NSRegularExpression(
            pattern: #"\b(?:Homily|Homilies|Tractate|Sermon|Epistle|Letter|Book"#
                + #"|Question|Article)\s+(?:[IVXLC]+|\d{1,3})\b[^.\n]{0,40}"#,
            options: .caseInsensitive),
        // The Catechism, by paragraph. `CCC 1213` is the shape; a bare "the Catechism"
        // is an attribution and is allowed.
        try! NSRegularExpression(
            pattern: #"\b(?:CCC|Catechism(?:\s+of\s+the\s+Catholic\s+Church)?)"#
                + #"[,\s]*(?:§\s*)?\d{1,4}\b"#),
        // Denzinger, which is a paragraph number and nothing else.
        try! NSRegularExpression(pattern: #"\bDenzinger[,\s]*\d{1,4}\b"#),
        // A named council or a dated one.
        try! NSRegularExpression(
            pattern: #"\bCouncil\s+of\s+[A-Z][A-Za-z]+(?:\s*\(?\d{3,4}\)?)?"#),
        // An encyclical, which is a Latin title and usually a year.
        try! NSRegularExpression(
            pattern: #"\b[A-Z][a-z]+\s+[A-Z][a-z]+\s*\(\d{4}\)"#),
        // A bare section number, which only ever appears in this app attached to a
        // document the model has invented.
        try! NSRegularExpression(pattern: #"§\s*\d{1,4}"#),
    ]
}
