// Copyright © 2026 Apple Inc.

import Foundation

/// The chapter-level correspondence between this edition's psalm numbers and the
/// Hebrew/Protestant ones.
///
/// **The corpus and every citation the app emits are pure Douay-Rheims.** This table
/// exists for exactly two consumers: the navigator's disambiguation hint, and the
/// cross-reference importer, which has to translate a Protestant dataset into this
/// edition's numbering before anything can resolve.
///
/// Chapter level only, and deliberately so. Verse-level offsets within a psalm are
/// *not* uniformly +1 — the Hebrew titles are counted as verse 1 in the Vulgate for
/// many psalms and not for others — and they are not verified here per psalm. So
/// nothing in this app depends on them, and imported Psalms references are downgraded
/// to chapter granularity rather than pointed at a verse that may be off by one.
///
/// The divergence is real and it is most of the psalter: DRB 10 through 145 are all
/// one behind their Hebrew counterparts, which is why `Ps 23` finds the wrong psalm.
enum PsalmNumbering {
    /// What a Douay psalm corresponds to on the Hebrew side.
    enum Correspondence: Equatable, Sendable {
        /// One Douay psalm, one Hebrew psalm, whole.
        case exact(Int)
        /// One Douay psalm covering several Hebrew ones: DRB 9 is Hebrew 9 and 10.
        case spans(ClosedRange<Int>)
        /// One Douay psalm that is part of a Hebrew one: DRB 114 and 115 are the two
        /// halves of Hebrew 116.
        case part(Int)
    }

    static let count = 150

    /// The Hebrew numbering of a Douay psalm.
    static func hebrew(forDouay douay: Int) -> Correspondence? {
        switch douay {
        case 1 ... 8: .exact(douay)
        case 9: .spans(9 ... 10)
        case 10 ... 112: .exact(douay + 1)
        case 113: .spans(114 ... 115)
        case 114, 115: .part(116)
        case 116 ... 145: .exact(douay + 1)
        case 146, 147: .part(147)
        case 148 ... 150: .exact(douay)
        default: nil
        }
    }

    /// The Douay numbering of a Hebrew psalm.
    ///
    /// `nil` where the Hebrew psalm is split across two Douay ones — Hebrew 116 is DRB
    /// 114 and 115, Hebrew 147 is DRB 146 and 147 — because there is no single right
    /// answer at chapter granularity and guessing one would put an imported
    /// cross-reference in the wrong half. The importer drops those rather than
    /// resolving them.
    static func douay(forHebrew hebrew: Int) -> Int? {
        switch hebrew {
        case 1 ... 8: hebrew
        case 9, 10: 9
        case 11 ... 113: hebrew - 1
        case 114, 115: 113
        case 116: nil
        case 117 ... 146: hebrew - 1
        case 147: nil
        case 148 ... 150: hebrew
        default: nil
        }
    }
}
