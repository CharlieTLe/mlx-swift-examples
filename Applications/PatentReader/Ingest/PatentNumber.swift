// Copyright © 2026 Apple Inc.

import Foundation

/// Turning what a reader types into a patent number.
///
/// One patent is written `US10123456B2`, `US 10,123,456 B2`, `10123456`, `10,123,456`
/// and `us10123456b2` in different places on the same afternoon, and a reader who pastes
/// any of them is asking for the same document. Normalizing them onto one `PatentKey` is
/// what lets the library's find field, the fetch sheet and a pasted citation all be the
/// same code path.
///
/// A pure function with no state, deliberately, so `SelfTest` can assert the whole
/// grammar without a view — `NavigatorSearch`'s reason, restated.
enum PatentNumberParser {

    /// The offices this recognises by prefix. Not a complete list of patent offices and
    /// not trying to be: it is the set whose numbers a reader of US patents will
    /// plausibly paste, taken from the `DC.relation` values Google Patents emits for
    /// cited references. An unrecognised prefix falls through to `nil` rather than being
    /// invented, because "XX 123456" is far more likely to be a typo than an office.
    private static let offices: Set<String> = [
        "US", "EP", "WO", "JP", "CN", "KR", "DE", "GB", "FR", "CA", "AU", "IN", "BR",
        "RU", "TW", "ES", "IT", "NL", "SE", "CH", "AT", "BE", "DK", "FI", "NO", "MX",
    ]

    /// `US10123456B2` and every spelling of it, or `nil`.
    ///
    /// The rules, in order:
    ///
    /// - Separators — spaces, commas, hyphens, slashes, non-breaking spaces — are
    ///   dropped everywhere. `US 10,123,456 B2` and `US10123456B2` are one input.
    /// - A leading two-letter office code is taken if it is one of `offices`; otherwise
    ///   the number is assumed to be `US`, because this is a reader of US patents and a
    ///   bare `10123456` means a US patent to everybody who types it.
    /// - A trailing kind code is a letter and an optional digit: `A`, `A1`, `B2`, `T3`.
    /// - What is left must be six to eleven digits. Six is the floor because a US grant
    ///   number reached seven digits in 1902 and this app cannot fetch anything older
    ///   usefully; eleven is the ceiling because a US pre-grant publication number is
    ///   `20140030575`, four-digit year plus seven.
    ///
    /// Deliberately **not** validated beyond shape. `US99999999B2` parses and then fails
    /// to fetch, which is the right place for it to fail: a parser that refused
    /// implausible numbers would also refuse the next numbering scheme an office adopts.
    static func parse(_ input: String) -> PatentKey? {
        let compact =
            input
            .uppercased()
            .filter { !" \t\n\r,.-/\u{00A0}\u{2011}\u{2013}\u{2014}".contains($0) }
        guard !compact.isEmpty else { return nil }

        var rest = Substring(compact)

        var country = "US"
        let prefix = String(rest.prefix(2))
        if prefix.count == 2, prefix.allSatisfy(\.isLetter), offices.contains(prefix) {
            country = prefix
            rest = rest.dropFirst(2)
        }

        var kind: String?
        // A kind code is one letter, optionally followed by one digit, at the end. Read
        // from the back so `B2` is taken and the `B` of a hypothetical alphabetic serial
        // is not.
        if let last = rest.last, last.isNumber, rest.count >= 2 {
            let letter = rest[rest.index(rest.endIndex, offsetBy: -2)]
            if letter.isLetter {
                kind = String([letter, last])
                rest = rest.dropLast(2)
            }
        } else if let last = rest.last, last.isLetter {
            kind = String(last)
            rest = rest.dropLast()
        }

        let serial = String(rest)
        guard serial.count >= 6, serial.count <= 11, serial.allSatisfy(\.isNumber)
        else { return nil }

        return PatentKey(country: country, serial: serial, kind: kind)
    }

    /// Whether `input` looks like somebody trying to type a patent number at all.
    ///
    /// Used by the find field to decide between offering a fetch and filtering by title.
    /// Deliberately stricter than `parse`: `parse("heat sink 100")` is nil anyway, but
    /// `parse("2018")` would be nil for length and `parse("20140030575")` would succeed,
    /// and a reader typing a title that happens to be eight digits long is not asking to
    /// fetch. Requiring that digits dominate is the cheap discriminator.
    static func looksLikeNumber(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let digits = trimmed.filter(\.isNumber).count
        return digits >= 6 && digits >= trimmed.count / 2
    }
}
