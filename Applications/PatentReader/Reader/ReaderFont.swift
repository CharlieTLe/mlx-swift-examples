// Copyright © 2026 Apple Inc.

import CoreText
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The face the patent text is set in.
///
/// A patent is a document that was typeset before it was a web page, and the app is
/// built to look like the printed grant — paragraph numbers in a margin, claims as a
/// hanging-indent tree, section headings that break the column. SF is the one part of
/// that which does not read like a document.
///
/// Two facts about what macOS actually ships shape the rest of this file:
///
/// - **Big Caslon is a single face** (`BigCaslon-Medium`): no italic, no bold, and
///   macOS ships no other Caslon. `Font.custom(...).weight(.semibold)` resolves to
///   the nearest *available* face, so asking for weight gives Baskerville real
///   contrast and Big Caslon nothing at all — one code path rendering two different
///   visual hierarchies. So weight is not a usable channel here; size, tracking,
///   italic, and colour carry the hierarchy instead.
/// - **Garamond is not installed.** It is in Apple's downloadable font asset
///   catalog, which `ReaderFontLibrary` fetches on demand.
///
/// iOS ships a different set, which is why `offered` exists rather than
/// `allCases`: of the three named faces above only Baskerville is there, Big Caslon
/// has no iOS counterpart at all, and Garamond is not in an iOS downloadable font
/// catalog. Hoefler Text and Palatino take their places, and both were picked from the
/// runtime's `System/Library/Fonts/AppFonts`, which is the set actually exposed to
/// apps, and the reason Iowan Old Style is not here. It was the obvious third choice,
/// it ships with iOS, and `CTFontManagerCopyAvailableFontFamilyNames` does not return
/// it, so the row rendered in SF and offered a download that does not exist.
///
/// The cases are *not* renamed per platform. An honest family name beats a silent
/// substitution, and a `readerFont` of `caslon` carried over from a Mac stays safe
/// because `ReaderTypeface.init` falls back to the system face for a family that is
/// not installed.
enum ReaderFont: String, CaseIterable, Sendable {
    case system, caslon, baskerville, garamond, hoeflerText, palatino

    /// What the typeface menu lists, which is only the families the running platform
    /// can actually resolve. `allCases` stays the full set, because it is also the
    /// decoding surface for a stored preference written on the other platform.
    static var offered: [ReaderFont] {
        #if os(macOS)
            [.system, .caslon, .baskerville, .garamond]
        #else
            [.system, .baskerville, .hoeflerText, .palatino]
        #endif
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .caslon: "Caslon"
        case .baskerville: "Baskerville"
        case .garamond: "Garamond"
        case .hoeflerText: "Hoefler Text"
        case .palatino: "Palatino"
        }
    }

    /// The CoreText family name, or `nil` for the system face, which is the one this
    /// app has no business naming: `Font.body` already resolves it, including on a
    /// machine where SF has been replaced.
    var familyName: String? {
        switch self {
        case .system: nil
        case .caslon: "Big Caslon"
        case .baskerville: "Baskerville"
        case .garamond: "Garamond"
        case .hoeflerText: "Hoefler Text"
        case .palatino: "Palatino"
        }
    }

    /// The point-size multiplier that makes this family read at the size SF does.
    ///
    /// Per family, not one constant. Baskerville and Garamond both set noticeably
    /// smaller than SF at the same point size and need the same lift. Big Caslon is
    /// a display cut with a large x-height and would read *bigger*, not equal, if it
    /// were scaled with them. Hoefler Text is a text cut with a small x-height and
    /// wants nearly as much lift as Baskerville; Palatino has a large x-height and
    /// needs less.
    var opticalScale: CGFloat {
        switch self {
        case .system: 1.00
        case .caslon: 1.07
        case .baskerville, .garamond: 1.15
        case .hoeflerText: 1.10
        case .palatino: 1.05
        }
    }

    /// Whether the family ships a real italic cut.
    ///
    /// CoreText answers by trying the conversion rather than by being told:
    /// `Baskerville` yields `Baskerville-Italic`, `Big Caslon` yields nil. This is
    /// what decides whether `ReaderTypeface.direction` can ask for `.italic()` or
    /// has to shear the face by hand.
    var hasItalicFace: Bool {
        guard let familyName else { return true }
        let base = CTFontCreateWithName(familyName as CFString, 12, nil)
        return CTFontCreateCopyWithSymbolicTraits(
            base, 0, nil, .traitItalic, .traitItalic) != nil
    }

    /// CoreText rather than `NSFontManager.shared`, which is `@MainActor` by way of
    /// its `NSMenuItemValidation` conformance and so out of reach of `--selftest`,
    /// which runs synchronously and off the main actor.
    static func installedFamilyNames() -> Set<String> {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as NSArray
        return Set(names.compactMap { $0 as? String })
    }

    /// The system's own point size for a text style, which is what a custom face has
    /// to be scaled against. Callable off the main actor: neither `NSFont` nor
    /// `UIFont` is isolated, only `NSFontManager` is.
    ///
    /// Asked for **at `.large`** rather than at the current content size category,
    /// which is the whole reason this is not a one-liner. `custom(_:_:)` below hands
    /// the result to `Font.custom(_:size:relativeTo:)`, which scales it by the ratio
    /// of the current dynamic type size to `.large`, so a size that already had
    /// Dynamic Type applied would be scaled by it twice. macOS never notices, being
    /// pinned at `.large`; on iOS, where Dynamic Type is live, it is the difference
    /// between the text growing once and growing quadratically.
    fileprivate static func systemSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
            PlatformFont.preferredFont(forTextStyle: platformStyle(style), options: [:])
                .pointSize
        #else
            PlatformFont.preferredFont(
                forTextStyle: platformStyle(style),
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            ).pointSize
        #endif
    }

    /// The same measurement **at the category actually in force**, which is what the
    /// *system* face has to be scaled against at a non-default `ReaderTextSize`.
    ///
    /// Two measurements and not one, because the two font constructors behave
    /// differently and neither is documented as doing so:
    ///
    /// - `Font.custom(_:size:relativeTo:)` scales the size it is handed, so it wants
    ///   the `.large` measurement above.
    /// - `Font.system(size:)` does **not**. Measured on the Simulator across the
    ///   `--selftest` ladder: at `.large` the body text read 22.3pt tall at Default and
    ///   24.0pt at the Large step; at xxxLarge the Default reading grew to 30.3pt and
    ///   the Large one was still 24.0pt. A fixed-size system font is frozen, so
    ///   choosing any size step would have taken the reader's accessibility setting
    ///   away from them. The scaling therefore has to happen here, from the category
    ///   in force.
    ///
    /// Measuring each style separately rather than scaling one body size also means the
    /// system face keeps each style's own metric curve, so the caption-derived speaker
    /// heading holds its proportion against the body at accessibility sizes instead of
    /// growing at the body's rate.
    fileprivate static func systemSize(
        _ style: Font.TextStyle, at dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        #if os(macOS)
            // macOS has no Dynamic Type at all: `DynamicTypeSize` there is always `.large`,
            // so this is the measurement above, and the two paths cannot diverge.
            systemSize(style)
        #else
            PlatformFont.preferredFont(
                forTextStyle: platformStyle(style),
                compatibleWith: UITraitCollection(
                    preferredContentSizeCategory: contentSizeCategory(dynamicTypeSize))
            ).pointSize
        #endif
    }

    #if !os(macOS)
        /// `DynamicTypeSize` and `UIContentSizeCategory` are the same ladder in two types,
        /// and SwiftUI ships no conversion between them.
        ///
        /// `fileprivate` rather than `private` for the same reason `systemSize(_:)` is:
        /// `ReaderTypeface` is a different type in this file, and it needs this to reproduce
        /// what `relativeTo:` does when resolving a concrete face.
        fileprivate static func contentSizeCategory(
            _ size: DynamicTypeSize
        ) -> UIContentSizeCategory {
            switch size {
            case .xSmall: .extraSmall
            case .small: .small
            case .medium: .medium
            case .large: .large
            case .xLarge: .extraLarge
            case .xxLarge: .extraExtraLarge
            case .xxxLarge: .extraExtraExtraLarge
            case .accessibility1: .accessibilityMedium
            case .accessibility2: .accessibilityLarge
            case .accessibility3: .accessibilityExtraLarge
            case .accessibility4: .accessibilityExtraExtraLarge
            case .accessibility5: .accessibilityExtraExtraExtraLarge
            @unknown default: .large
            }
        }
    #endif

    /// `NSFont.TextStyle` and `UIFont.TextStyle` spell every case the same, so this
    /// mapping is written once against `PlatformFont`.
    fileprivate static func platformStyle(_ style: Font.TextStyle) -> PlatformFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

/// The fonts the patent text is actually drawn with.
///
/// **Roles, not styles.** One property per place that draws patent text, rather than a
/// general `font(_ style:weight:italic:)`. Every "what happens in a family with only
/// one face" decision then lives here, in one place, next to the comment explaining
/// it — and `DocumentRowView` stops restating styling it does not own.
struct ReaderTypeface: Equatable, Sendable {
    let font: ReaderFont

    /// `nil` for `.system` **and** for a family that is not installed yet, which is
    /// what Garamond looks like until its asset lands.
    ///
    /// Resolving availability here rather than leaving it to `Font.custom` is
    /// deliberate: `Font.custom`'s fallback for an unknown family is real but
    /// undocumented, and it would make a typo'd family name indistinguishable from a
    /// font that has simply not downloaded yet. With this nil until the family is
    /// present the not-yet-downloaded state is explicit in the type, and when the
    /// download lands the value changes identity and the reader re-renders with no
    /// extra wiring.
    let familyName: String?

    /// Probed once, here, rather than on every row: `direction` is asked for at each
    /// stage direction in the scene.
    private let hasItalicFace: Bool

    /// The reader's size step, carried here rather than in a second environment key.
    ///
    /// `DocumentReaderView` re-anchors the scroll position off `.onChange(of: typeface)`,
    /// precisely because changing the type shifts point-based scroll offsets. Putting
    /// the step on this already-`Equatable` value gets that re-anchor for free; a
    /// separate key would not fire it, and every size change would drift the reader off
    /// their line.
    ///
    /// Named `textSize` and not `size`, so it cannot be confused with the `size(_:)`
    /// method below, which answers in points.
    let textSize: ReaderTextSize

    /// The content size category in force, which only the system face needs and only at
    /// a non-default `textSize`: `Font.system(size:)` is fixed, so nothing else would
    /// scale the text when the reader moves the Larger Text slider. See
    /// `ReaderFont.systemSize(_:at:)`, which is where that was measured.
    ///
    /// Stored here, alongside `textSize`, for the same reason: `DocumentReaderView`
    /// re-anchors off `.onChange(of: typeface)`, and a category change moves the type
    /// exactly as a size step does. Always `.large` on macOS.
    let dynamicTypeSize: DynamicTypeSize

    /// No default argument for `textSize` or `dynamicTypeSize`. There are exactly two
    /// construction sites, so being explicit costs two arguments and buys a compiler
    /// error at any new one — and a silently defaulted `dynamicTypeSize` is precisely
    /// the bug that froze the accessibility control before it was threaded through.
    init(
        _ font: ReaderFont, textSize: ReaderTextSize, dynamicTypeSize: DynamicTypeSize,
        installed: Set<String>
    ) {
        let resolved = font.familyName.flatMap { installed.contains($0) ? $0 : nil }
        self.font = font
        self.familyName = resolved
        self.hasItalicFace = resolved == nil || font.hasItalicFace
        self.textSize = textSize
        self.dynamicTypeSize = dynamicTypeSize
    }

    static let system = ReaderTypeface(
        .system, textSize: .default, dynamicTypeSize: .large, installed: [])

    // MARK: - Roles

    /// A specification heading — TECHNICAL FIELD, DETAILED DESCRIPTION.
    ///
    /// These are the patent's own structure, printed in the document itself, and setting
    /// them as headings rather than as another paragraph is most of what makes a
    /// specification navigable by eye. Set with tracking and generous space above; the
    /// small-caps effect comes from the source, which capitalises them already.
    var sectionHeading: Font {
        // `.system` keeps `.headline` verbatim, so the shipped default is exactly what
        // the system face renders. A custom face cannot use weight (see `ReaderFont`), so
        // a step up in size plus the letterspacing below is what holds the heading apart
        // from the text under it.
        guard let familyName else {
            // `.semibold` restated by hand: it is part of `.headline` and not part of the
            // point size, so a bare `Font.system(size:)` would draw a heading at the
            // weight of body text.
            return textSize.isDefault ? .headline : system(.headline, weight: .semibold)
        }
        return custom(familyName, .title3)
    }

    /// Letterspacing for a heading, a separate value because tracking is a `Text`
    /// modifier and not something a `Font` carries. Zero for the system face, so the
    /// default is untouched.
    ///
    /// More than a play's headings get, because these are set in full capitals for their
    /// whole length: a run of capitals needs letterspacing to stop reading as a word.
    var sectionTracking: CGFloat {
        (familyName == nil ? 0.4 : 1.0) * textSize.multiplier
    }

    /// The patent's title, on the front-page card.
    var frontPageTitle: Font {
        guard let familyName else {
            return textSize.isDefault
                ? .title3.weight(.semibold) : system(.title3, weight: .semibold)
        }
        return custom(familyName, .title2)
    }

    /// A field name on the front-page card — "Assignee", "Filed".
    ///
    /// Stays on the **system** face and small, because it is chrome rather than the
    /// document: the reader's chosen serif is for the patent's own words, and setting the
    /// app's labels in it would make the card read as part of the text.
    var frontPageLabel: Font {
        textSize.isDefault ? .caption2.weight(.semibold) : system(.caption2, weight: .semibold)
    }

    /// A field value on the front-page card.
    var frontPageDetail: Font {
        textSize.isDefault ? .caption : system(.caption)
    }

    /// Specification paragraphs and claim text — the document itself.
    var body: Font {
        guard let familyName else { return textSize.isDefault ? .body : system(.body) }
        return custom(familyName, .body)
    }

    /// The body again, in italic.
    ///
    /// Little in a patent is set in italic, unlike a play, and this exists mostly so
    /// `WordHitTest`'s shadow layout has a face to measure italic runs against — which it
    /// needs whether or not the current document happens to contain any.
    var bodyItalic: Font {
        guard let familyName else {
            return textSize.isDefault ? .body.italic() : system(.body, italic: true)
        }
        guard hasItalicFace else { return Self.oblique(familyName, size: size(.body)) }
        return custom(familyName, .body).italic()
    }

    /// A claim's own sub-paragraph.
    ///
    /// The same size as `body` and not a step down, which is the opposite of what a stage
    /// direction got next door and for a reason worth stating: a claim's elements are not
    /// an aside, they are the claim. Every limitation in them is load-bearing, and
    /// setting them smaller would tell the reader they matter less than the preamble
    /// they hang under. The hanging indent carries the structure instead.
    var claimElement: Font { body }

    /// The gap between two blocks — two paragraphs, or two claims. The one padding in a
    /// row that carries typographic meaning, so the one that scales.
    var blockGap: CGFloat { (10 * scale).rounded() }

    /// The space above a section heading. Larger than `blockGap` because a heading's job
    /// is to break the column, and white space above it is most of how that reads.
    var headingGap: CGFloat { (22 * scale).rounded() }

    /// One level of the claim tree's hanging indent.
    ///
    /// Lives here rather than in the row because a printed patent sets it in ems: 18pt
    /// against 17pt type is not the same indent as 18pt against 26pt type. This applies
    /// twice over — once per level of claim dependency, and once per level of a claim's
    /// own nested elements — so it has to stay modest or a fourth-level element starts
    /// halfway across the measure.
    var claimIndent: CGFloat { (18 * scale).rounded() }

    /// The paragraph-number gutter's font.
    ///
    /// Stays on the system face for its **tabular figures**, which no serif text family
    /// has, so a column of `[0009]` and `[0010]` lines up. Does scale with the reader's
    /// step: a 10pt number beside 20pt text reads as a bug rather than as restraint.
    var gutterFont: Font {
        textSize.isDefault ? .caption2.monospacedDigit() : system(.caption2).monospacedDigit()
    }

    /// The gutter's width, which moves with `gutterFont` and never on its own: the width
    /// is a budget for the widest label it has to hold, so scaling the font without it is
    /// the clipping case.
    ///
    /// 42 rather than a play's 30, because the label is `[0042]` and not `42` — six
    /// characters against two. That is the visible cost of printing every paragraph
    /// number rather than every fifth, and it buys the thing the app is for: every
    /// paragraph in a patent is a citation target, so every one of them shows its number.
    ///
    /// `textSize.multiplier` and not `scale`, because the gutter is not in the reader's
    /// chosen family and so has no optical correction to apply.
    var gutterWidth: CGFloat { (42 * textSize.multiplier).rounded() }

    /// A reference numeral inside running text — the `100` in "the heat sink 100".
    ///
    /// Tabular figures again, and at the body's size rather than the gutter's, because
    /// this one sits *in* a sentence: a numeral a step smaller than the words around it
    /// would look like a footnote marker, which is precisely what it is not.
    var referenceNumeral: Font {
        textSize.isDefault ? .body.monospacedDigit() : system(.body).monospacedDigit()
    }

    /// The reading measure: how wide a column of text is allowed to get before the line
    /// length itself becomes the thing making it hard to read.
    ///
    /// 640pt at the default step, which is roughly 70 characters of the system face —
    /// the width a typographer would pick and, not coincidentally, about what a patent's
    /// own two-column setting gives per column. A full-screen 13-inch iPad in landscape
    /// is roughly 1,100pt of pane, which is nearly twice that.
    ///
    /// `scale` and not `textSize.multiplier`, for `claimIndent`'s reason restated: a
    /// measure is set in ems, so 640pt against 17pt type is not the same measure as
    /// 640pt against 26pt type, and a measure held fixed while the type grows gets
    /// *narrower* in ems — which is the cramped column the cap exists to avoid.
    var measure: CGFloat { (640 * scale).rounded() }

    // MARK: - Roles, resolved

    /// `body` and `bodyItalic` again, as concrete faces at concrete point sizes, which is
    /// what hit-testing a word needs: a SwiftUI `Font` cannot be asked which family or
    /// how many points it resolved to, so `WordHitTest` has to be told.
    ///
    /// These **shadow** the roles above and have to be kept in step with them — the
    /// family, the point size, the `textSize.isDefault` short-circuit and the `size(_:)`
    /// / `systemFaceSize(_:)` asymmetry are all restated here. A role changed without its
    /// twin does not fail to compile; it makes the hover mark drift along the line,
    /// further the further right the pointer is.
    ///
    /// The system-face branch needs no `isDefault` case of its own, and that is not an
    /// omission: at the default step `scale` is exactly 1, so `systemFaceSize(_:)` returns
    /// the very point size `Font.body` resolves to. The one difference is this rounds and
    /// the text style does not, which on macOS is no difference at all — every system
    /// text style there is a whole number of points.
    var bodyPlatformFont: PlatformFont {
        Self.face(familyName, size: scaledSize(.body), italic: false)
    }

    /// `bodyItalic`'s shadow. Italic advances are not the upright face's, so a span
    /// hit-tested with the upright font drifts from the word after it.
    ///
    /// `italic: false` for Big Caslon is deliberate and not an oversight. Its italic is
    /// `oblique(_:size:)`, which shears the matrix's `c` slot only, so its advances *are*
    /// the upright face's. `hasItalicFace` probes the family and not the size, so it
    /// already answers for body.
    var bodyItalicPlatformFont: PlatformFont {
        Self.face(
            familyName, size: scaledSize(.body),
            italic: familyName == nil || hasItalicFace)
    }

    /// The rendered point size of a role, for the family this typeface resolved to.
    ///
    /// The two branches are the `size(_:)` / `systemFaceSize(_:)` asymmetry: a custom face
    /// is handed to `Font.custom(_:size:relativeTo:)`, which scales it by Dynamic Type
    /// afterwards, and the system face is handed to `Font.system(size:)`, which does not.
    private func scaledSize(_ style: Font.TextStyle) -> CGFloat {
        guard familyName != nil else { return systemFaceSize(style) }
        #if os(macOS)
            // Dynamic Type is pinned at `.large`, so `relativeTo:` scales by 1 and the size
            // asked for is the size drawn.
            return size(style)
        #else
            // What `relativeTo:` does, reproduced: the ratio of the category in force to
            // `.large`, applied to a size measured at `.large`. This is the half of word
            // lookup that is not wired up on iOS yet, and it is written out so that when it
            // is, the mark lands on the word at every Dynamic Type size rather than only at
            // the default one.
            return UIFontMetrics(forTextStyle: ReaderFont.platformStyle(style))
                .scaledValue(
                    for: size(style),
                    compatibleWith: UITraitCollection(
                        preferredContentSizeCategory: ReaderFont.contentSizeCategory(
                            dynamicTypeSize)))
        #endif
    }

    /// A family name, a point size and an italic flag, resolved to the face CoreText
    /// actually draws.
    ///
    /// CoreText and then `PlatformFont(name:size:)`, because `NSFont`/`UIFont` take a font
    /// *name* while this app carries family names — `Baskerville` has to become
    /// `Baskerville-Italic` and only CoreText knows that. The system face is the one
    /// exception and is asked for by hand: its PostScript name is the private
    /// `.SFNS-Regular`, which `NSFont(name:)` refuses, and CoreText logs a warning at
    /// anyone who tries.
    private static func face(
        _ family: String?, size: CGFloat, italic: Bool
    ) -> PlatformFont {
        let system = PlatformFont.systemFont(ofSize: size)
        guard let family else {
            return italic ? (italicVariant(of: system) ?? system) : system
        }

        let base = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes(
                [kCTFontFamilyNameAttribute: family] as CFDictionary),
            size, nil)
        let face =
            italic
            ? (CTFontCreateCopyWithSymbolicTraits(
                base, size, nil, .traitItalic, .traitItalic) ?? base)
            : base
        return PlatformFont(name: CTFontCopyPostScriptName(face) as String, size: size)
            ?? system
    }

    /// The system face's italic cut, which is the one thing in this pair that has to be
    /// written twice: AppKit's `withSymbolicTraits` is not optional and its font
    /// initializer is, and UIKit has them exactly the other way round.
    private static func italicVariant(of font: PlatformFont) -> PlatformFont? {
        #if os(macOS)
            NSFont(
                descriptor: font.fontDescriptor.withSymbolicTraits(.italic),
                size: font.pointSize)
        #else
            font.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { UIFont(descriptor: $0, size: font.pointSize) }
        #endif
    }

    // MARK: - Sizing

    /// The product of two independent corrections: `opticalScale` makes a family read
    /// at the size SF does and is none of the reader's business, while
    /// `textSize.multiplier` is the only one they chose. The optical half stays 1.0 for
    /// the system face and for a download in flight; the reader's half applies in both
    /// cases, which is the feature.
    private var scale: CGFloat {
        (familyName == nil ? 1 : font.opticalScale) * textSize.multiplier
    }

    /// Rounded, so the text keeps landing on the baseline grid the number gutter is
    /// aligned to.
    private func size(_ style: Font.TextStyle) -> CGFloat {
        (ReaderFont.systemSize(style) * scale).rounded()
    }

    /// `size(_:)`'s twin for the system face, which has to do its own Dynamic Type
    /// scaling. Same rounding, different measurement — see `system(_:weight:italic:)`.
    private func systemFaceSize(_ style: Font.TextStyle) -> CGFloat {
        (ReaderFont.systemSize(style, at: dynamicTypeSize) * scale).rounded()
    }

    /// `relativeTo:` is what makes the text follow Dynamic Type, and it does not
    /// double-scale *because* `systemSize(_:)` is measured at `.large`. See the note
    /// there, which is the load-bearing half of this pair.
    private func custom(_ family: String, _ style: Font.TextStyle) -> Font {
        .custom(family, size: size(style), relativeTo: style)
    }

    /// The system face at a non-default step, which is the only reason this exists:
    /// `Font.body` is a *text style*, not a point size, and there is no arithmetic to
    /// do to it. Two things about it are worth knowing.
    ///
    /// - It is not what the default path uses, and the two are not interchangeable.
    ///   `Font.body` and `Font.system(size: 17)` are different values even where they
    ///   resolve to the same 17 points — the first follows Dynamic Type and the second
    ///   does not — so every role short-circuits to the bare style at `.default` rather
    ///   than routing through here with a multiplier of 1.
    /// - The size comes from `systemFaceSize(_:)` and **not** from `size(_:)`, because
    ///   `Font.system(size:)` will not scale it afterwards. That asymmetry with
    ///   `custom(_:_:)` is the whole content of `ReaderFont.systemSize(_:at:)`'s note.
    ///
    /// Naming SF's private dot-prefixed family to `Font.custom` in order to get
    /// `relativeTo:` here instead is rejected for the reason in `familyName`'s comment:
    /// this app has no business naming the system family.
    private func system(
        _ style: Font.TextStyle, weight: Font.Weight = .regular, italic: Bool = false
    ) -> Font {
        let font = Font.system(size: systemFaceSize(style), weight: weight)
        return italic ? font.italic() : font
    }

    /// A synthetic italic for a family with no italic cut, which is Big Caslon,
    /// and only Big Caslon: Baskerville, Garamond, Hoefler Text and Palatino
    /// all ship real italics, so `hasItalicFace` keeps them out of here.
    ///
    /// The shear sits in the matrix's `c` slot only, so advance widths are untouched
    /// and a stage direction wraps exactly where its upright twin would. The size
    /// goes to `CTFontCreateWithFontDescriptor` and stays **out** of the matrix:
    /// CoreText's Swift shim `CTFont.init(_:transform:)` hard-codes size 1.0 and
    /// expects the matrix to carry the scale, so that convenience initializer
    /// silently yields a one-point font.
    ///
    /// A `Font` built from a `CTFont` does not participate in Dynamic Type, so this is
    /// the one role that ignores it — it still follows the reader's size step, which
    /// arrives baked into `size`. Harmless: Big Caslon is macOS-only, and macOS is
    /// pinned at `.large`.
    private static func oblique(_ family: String, size: CGFloat) -> Font {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.2126, d: 1, tx: 0, ty: 0)  // ~12°
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, &shear))
    }
}

extension EnvironmentValues {
    /// Injected on `DocumentReaderView` and nowhere else, and that single injection
    /// point *is* the scope of this feature: the navigator, the commentary pane, the
    /// header chrome, and the status strip all stay on the system face. A `let`
    /// parameter threaded through initializers — how `collapsedActs` is passed —
    /// could not express that boundary nearly as well, which is the reason for the
    /// departure.
    @Entry var readerTypeface: ReaderTypeface = .system
}
