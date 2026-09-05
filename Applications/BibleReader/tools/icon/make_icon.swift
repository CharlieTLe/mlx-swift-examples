// Copyright © 2026 Apple Inc.
//
// Regenerate the app icon: a Big Caslon capital B, ink on parchment.
//
//     swift tools/icon/make_icon.swift
//
// No shebang, unlike tools/build_corpus.py: swift-format treats one as a comment and
// folds the following line into it, so a `#!/usr/bin/swift` here comes back mangled from
// every `pre-commit run --all`. Invoked through `swift` instead, which is how the corpus
// script is invoked through `python3` anyway.
//
// Writes Assets.xcassets/AppIcon.appiconset/*.png: the macOS ladder plus the iOS 1024.
// Every output is checked in, so a clone builds with no run of this script; it exists
// to make the mark and the masking reproducible, the same way tools/build_corpus.py
// does for the corpus.
//
// The mark is drawn here rather than traced from any artwork: the only inputs are a
// system font and two colours, so there is no image file in this directory and nothing
// about the icon to license or attribute. It is also the right answer to the constraint
// that actually decides an icon, which is the 16pt tile — what survives that downsample
// is one high-contrast shape, and a glyph is nothing but that. tools/icon/NOTICE.md
// carries the rest of the design reasoning.
//
// Swift rather than Python, breaking the language precedent in this directory
// deliberately: build_corpus.py is standard-library-only so it needs no install step,
// and the equivalent image script would need Pillow. CoreGraphics is already on every
// machine that can build this app, it is what ships the high-quality downsampling the
// 16pt icon needs, and CoreText is what turns a glyph into a resolution-independent path.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// The letter, and the face it is set in.
///
/// Big Caslon is the app's own signature face — the reader offers it, and it is the only
/// Caslon macOS ships — so the icon is set in something the app actually renders verse in
/// rather than in a face chosen only for the icon. `BigCaslon-Medium` is its single
/// weight; there is no bold or italic, which is why `markFontName` is a PostScript name
/// and is checked rather than requested by family.
let markCharacter: UniChar = 0x0042  // "B"
let markFontName = "BigCaslon-Medium"

/// Cap height as a fraction of the art canvas.
///
/// 0.62 leaves the letter clear of the squircle's corners on macOS, where the art is
/// scaled into the 824pt body, while still filling enough of the iOS canvas, where it is
/// full-bleed. Larger crowds the corners at 512pt; smaller stops reading at 16pt.
let markHeightFraction = 0.62

/// Warm parchment, and an ink that is off-black rather than black.
///
/// Figure/ground contrast is the whole design budget at 16pt, so these are far apart in
/// luminance and close in hue. A true black letter on a true white ground would read as
/// harshly as a system alert; the warmth is what makes it look like a printed initial.
let parchment = CGColor(srgbRed: 0.941, green: 0.902, blue: 0.816, alpha: 1)
let ink = CGColor(srgbRed: 0.129, green: 0.110, blue: 0.090, alpha: 1)

/// Resolution the mark is drawn at once, then downsampled from for every slot.
///
/// Rasterising the glyph separately at each size would hint it differently at each one;
/// drawing it once large and letting `.high` interpolation reduce it keeps the stroke
/// weights proportional all the way down, which is what the 16pt tile needs.
let artSize = 1024

/// Fraction of the icon canvas the rounded body occupies.
///
/// Apple's macOS icon grid: an 824pt body centred in a 1024pt canvas, with the
/// remaining margin carrying the shadow. iOS is full-bleed instead — the system
/// applies its own mask — so this applies to the macOS ladder only.
let bodyFraction = 824.0 / 1024.0

/// Superellipse exponent for the corner shape.
///
/// `CGPath(roundedRect:)` is circular arcs, which reads visibly pinched at the corners
/// next to a system icon. Apple's shape is a squircle: continuous curvature, no flat
/// sides. n = 5 is the standard model of it, and sampling the curve densely is simpler
/// to get right than the Bézier control-point approximation.
let superellipseExponent = 5.0

// MARK: - Paths

let toolURL = URL(fileURLWithPath: #filePath)
let appRoot = toolURL.deletingLastPathComponent()  // tools/icon
    .deletingLastPathComponent()  // tools
    .deletingLastPathComponent()  // ShakespeareReader
let iconSetURL = appRoot.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing

/// The squircle, as a path inscribed in `rect`.
///
/// Sampled rather than fitted: 720 points is finer than a pixel at 1024pt, so the
/// polygon is indistinguishable from the curve once CoreGraphics antialiases it.
func superellipsePath(in rect: CGRect, exponent: Double) -> CGPath {
    let path = CGMutablePath()
    let (a, b) = (rect.width / 2, rect.height / 2)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let samples = 720
    for i in 0 ..< samples {
        let t = 2 * Double.pi * Double(i) / Double(samples)
        // |cos t|^(2/n) with the sign of cos t, which traces the superellipse.
        let x = pow(abs(cos(t)), 2 / exponent) * (cos(t) < 0 ? -1 : 1) * a
        let y = pow(abs(sin(t)), 2 / exponent) * (sin(t) < 0 ? -1 : 1) * b
        let point = CGPoint(x: center.x + x, y: center.y + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func context(size: Int) -> CGContext {
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(size)x\(size) bitmap context") }
    // The default is `.default`, which is bilinear and leaves the 16pt icon mushy.
    context.interpolationQuality = .high
    return context
}

/// The mark itself: parchment, with the letter centred on it in ink.
///
/// The glyph arrives as a `CGPath` from CoreText rather than as drawn text, so it can be
/// scaled to an exact cap height and centred on its own bounding box. Laying it out as
/// text instead would centre the *typographic* box — advance width, ascent and descent —
/// and an `S` has no descender, so the letter would sit visibly high in the tile.
func markArt(size: Int) -> CGImage {
    let canvas = Double(size)
    let context = context(size: size)

    context.setFillColor(parchment)
    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Asked for by PostScript name, and checked: `CTFontCreateWithName` substitutes the
    // system face for a name it cannot resolve rather than failing, so without this a
    // machine missing Big Caslon would silently produce a San Francisco icon.
    let font = CTFontCreateWithName(markFontName as CFString, canvas, nil)
    let resolved = CTFontCopyPostScriptName(font) as String
    guard resolved == markFontName else {
        fatalError(
            "\(markFontName) did not resolve (got \(resolved)). It ships with macOS; "
                + "check Font Book has not disabled it.")
    }

    var character = markCharacter
    var glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
        fatalError("\(markFontName) has no glyph for U+\(String(markCharacter, radix: 16))")
    }
    guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else {
        fatalError("no outline for the mark glyph")
    }

    // Scale to the target cap height, then translate the *scaled* bounding box to the
    // centre of the canvas. Order matters: scaling after the translate would move the
    // letter off centre by the scale factor.
    let bounds = outline.boundingBox
    let scale = canvas * markHeightFraction / bounds.height
    let scaled = bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
    var transform = CGAffineTransform(scaleX: scale, y: scale)
        .concatenating(
            CGAffineTransform(
                translationX: (canvas - scaled.width) / 2 - scaled.minX,
                y: (canvas - scaled.height) / 2 - scaled.minY))
    guard let placed = outline.copy(using: &transform) else {
        fatalError("could not place the mark glyph")
    }

    context.addPath(placed)
    context.setFillColor(ink)
    context.fillPath()

    guard let image = context.makeImage() else { fatalError("mark \(size) failed") }
    return image
}

/// The macOS icon at `size` pixels: the art, masked to the squircle, inset in the
/// canvas, over a soft shadow.
func macIcon(art: CGImage, size: Int) -> CGImage {
    let canvas = Double(size)
    let body = (canvas * bodyFraction).rounded()
    let origin = ((canvas - body) / 2).rounded()
    let bodyRect = CGRect(x: origin, y: origin, width: body, height: body)
    let path = superellipsePath(in: bodyRect, exponent: superellipseExponent)

    let context = context(size: size)
    // Drawn as a filled shape first so the shadow comes off the silhouette, not off the
    // art's bounding box — clipping to the path and then drawing the image would put the
    // shadow behind opaque pixels where it is never seen.
    context.saveGState()
    context.setShadow(
        // Negative dy: this context is y-up, and the shadow belongs below the body.
        offset: CGSize(width: 0, height: -canvas * 0.012),
        blur: canvas * 0.022,
        color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(art, in: bodyRect)
    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("macOS icon \(size) failed") }
    return image
}

/// The iOS icon: full-bleed and opaque. An alpha channel here is an App Store
/// validation error, and the rounding is the system's job.
func iOSIcon(art: CGImage, size: Int) -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("could not create the iOS bitmap context") }
    context.interpolationQuality = .high
    context.draw(art, in: CGRect(x: 0, y: 0, width: Double(size), height: Double(size)))
    guard let image = context.makeImage() else { fatalError("iOS icon \(size) failed") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not open \(url.path) for writing") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
    print("  \(url.lastPathComponent)  \(image.width)x\(image.height)")
}

// MARK: - Run

let art = markArt(size: artSize)

try? FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

/// One entry per `Contents.json` slot. The 32, 256 and 512 pixel sizes each appear
/// twice — as @1x of one point size and @2x of the one below — and get a file each
/// rather than two entries sharing a name, which is the layout Xcode itself writes.
let macLadder: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

print(
    "app icon: \(markFontName) U+\(String(markCharacter, radix: 16).uppercased()) at \(artSize)x\(artSize)"
)
print("appiconset:")
for (points, scale) in macLadder {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    write(macIcon(art: art, size: points * scale), to: iconSetURL.appendingPathComponent(name))
}
write(iOSIcon(art: art, size: 1024), to: iconSetURL.appendingPathComponent("icon_ios_1024.png"))
