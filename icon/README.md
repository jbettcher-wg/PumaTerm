# PumaTerm's icon

Original artwork for this project (`PumaTerm.svg`, paths only, no fonts):
an aluminium frame round a dark glass screen with a lit prompt and cursor,
in Leopard's idiom.

`PumaTerm.icns` is built from it, and is committed so a build on a board
needs no image tools:

    for s in 16 32 128 256 512; do rsvg-convert -w $s -h $s PumaTerm.svg -o icon-$s.png; done
    magick icon-512.png icon-256.png icon-128.png icon-32.png icon-16.png -compress none PumaTerm.tiff
    tiff2icns PumaTerm.tiff PumaTerm.icns          # on the board: 16, 32, 128
    magick icon-256.png -quality 90 icon-256.jp2   # then append ic08 and ic09
    magick icon-512.png -quality 90 icon-512.jp2   # as JPEG 2000 members

10.5's `tiff2icns` writes nothing above 128 pixels, and 10.5 reads the
256 and 512 members only as JPEG 2000, as its Icon Composer saved them:
measured on board 1, an icns with PNG `ic08`/`ic09` members made
`NSImage` refuse the whole file, and with JPEG 2000 ones it lists all
seven representations, the 512 with alpha.
