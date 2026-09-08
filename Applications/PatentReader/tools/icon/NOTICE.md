# Icon source

The app icon is a **Big Caslon capital P, ink on parchment**, drawn by
`make_icon.swift`. It is original artwork: the only inputs are a font that ships with
macOS and the two colours named in that file, so there is nothing here to license or
attribute.

Big Caslon because it is one of the faces the reader offers, and the only Caslon macOS
ships, so the icon is set in something the app actually renders patent text in rather than
in a face chosen only for the icon.

`BigCaslon-Medium` is asked for by PostScript name and the resolved name is checked,
because `CTFontCreateWithName` substitutes the system face for a name it cannot resolve
rather than failing. Without that check, a machine missing Big Caslon would quietly
produce a San Francisco icon instead of an error.

The glyph is taken as a `CGPath` and scaled to an exact height rather than laid out as
text, so it can be centred on its own bounding box. Centring the typographic box instead —
advance width, ascent and descent — would sit the letter visibly high in the tile, because
a `P` has no descender. The horizontal centring is worth as much: a Caslon `P` hangs a wide
bowl off the right of a straight stem, so its ink is not centred in the advance width
either.

## Why this is not just ShakespeareReader's icon with a different letter

It is the same script and the same two colours, and deliberately so — these are sibling
apps in the same repo and they should look like it. One number differs.
`markHeightFraction` is 0.65 here against 0.62 next door, because that fraction measures
the glyph's *bounding box*, and what a bounding box contains depends on the letter. An `S`
overshoots the cap line and the baseline at both of its curved ends, so its box is taller
than the cap height it encloses. A `P` is flat-topped and sits squarely on the baseline, so
its box **is** the cap height. Setting both to 0.62 does not give both letters the same
presence; it gives the `P` a shorter cap in a tile its narrow silhouette already leaves
emptier. 0.65 was picked by rendering 0.62, 0.65, 0.68 and 0.72 and looking: by 0.72 the
top and foot serifs crowd the squircle's edge.

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
`tools/wire_target.py` exists for the target's entry in the project file.
