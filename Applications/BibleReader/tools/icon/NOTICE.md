# Icon source

The app icon is a **Big Caslon capital B, ink on parchment**, drawn by
`make_icon.swift`. It is original artwork: the only inputs are a font that ships with
macOS and the two colours named in that file, so there is nothing here to license or
attribute.

Big Caslon because it is the app's own signature face — the reader offers it, and it is
the only Caslon macOS ships — so the icon is set in something the app actually renders
verse in rather than in a face chosen only for the icon.

`BigCaslon-Medium` is asked for by PostScript name and the resolved name is checked,
because `CTFontCreateWithName` substitutes the system face for a name it cannot resolve
rather than failing. Without that check, a machine missing Big Caslon would quietly
produce a San Francisco icon instead of an error.

The glyph is taken as a `CGPath` and scaled to an exact cap height rather than laid out
as text, so it can be centred on its own bounding box. Centring the typographic box
instead — advance width, ascent and descent — would sit the letter visibly high in the
tile, because a `B` has no descender.

## Why a letterform

The 16pt tile is the constraint that decides this, and figure/ground contrast is the
whole design budget there. A glyph is nothing but one high-contrast shape, so it survives
the downsample intact where a detailed image would dissolve into a smudge.

`parchment` and `ink` follow from the same reasoning: far apart in luminance so the
letter still reads at 16pt, close in hue so it does not look like a system alert. The
warmth is what makes it read as a printed initial rather than as a glyph on a swatch.

The mark is drawn once at 1024 and downsampled for every slot rather than rasterised
separately at each size, which would hint it differently at each one. Reducing a single
large render with `.high` interpolation keeps the stroke weights proportional all the way
down, and that is what the smallest tiles need.

Nothing needs regenerating for a clone to build. Every PNG is checked in, and this
script exists to keep the mark and the masking reproducible, the same reason
`tools/build_corpus.py` exists for the corpus.
