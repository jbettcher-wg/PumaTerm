# term -- a GL-accelerated terminal for Mac OS X 10.5 PowerPC

(Working name; renaming is a find-and-replace on `term`/`Term`.)

Every frame is one draw call: a vertex array with a quad per cell, carrying
the glyph's atlas coordinates and its foreground and background colours, and
a GLSL 1.20 shader that mixes the two by the glyph's coverage. That is all
OpenGL 2.1, which is what Leopard's OpenGL.framework offers whatever the
driver underneath can do; on board 1 it runs on the RadeonNI renderer
(`GL_VERSION 2.1 Mesa RadeonNI`).

| Part | What |
|---|---|
| `vendor/libvterm` | libvterm 0.3.3 (MIT): VT/xterm parsing, screen, keys, mouse |
| `src/GlyphAtlas.m` | glyphs rasterized once into a 2048x2048 GL_ALPHA texture via Core Text + CGFont (CTFontDrawGlyphs is 10.7); braille, block elements and box drawing are drawn pixel-exact |
| `src/TermView.m` | the NSOpenGLView: libvterm callbacks, 10,000-line scrollback, rendering, keyboard/mouse/paste, resize |
| `src/Pty.c` | the login shell on a pseudo-terminal (TERM=xterm-256color, COLORTERM=truecolor) |
| `src/main.m` | the app: menu bar and one window, no nib |

Build natively on a board (Apple's gcc-4.2: Objective-C and the 10.5 SDK):

    make            # -> build/Term.app
    cp -R build/Term.app /Applications/

Defaults: `defaults write org.xnu-t4240.term Font Monaco`, `FontSize 12`.
`Font` is the **PostScript** name, not the file or family name: an unknown
name silently falls back to a proportional system face (which shows as wide
gaps between letters).

Nerd Fonts work on 10.5 as they ship. Measured on board 1 with Hack Nerd Font
Mono v3.4.0 (`HackNerdFontMono-*.ttf` into `/Library/Fonts`, then
`Font HackNFM-Regular`): powerline (U+E0B0), devicons (U+E711) and the
Material Design set in plane 15 (U+F0001), so Leopard reads the font's
format 12 cmap and the surrogate path here reaches it. Use the *Mono*
variant: its icons are one cell wide, as a cell grid needs. A family's own
bold and italic faces are used when Core Text finds them; Monaco, which
has neither, gets a stroked bold and a sheared italic.
Shift-PageUp/PageDown and the scroll wheel scroll back; Cmd-V pastes
(bracketed); Option is Meta.

Test hooks (for checking rendering over ssh without touching the desktop):
`TERM_STARTUP_INPUT='btop\n'` types into the shell after start and opens the
window behind the others; `kill -USR1 <pid>` writes the next frame to
`/tmp/term-frame.png`. `proving-ground/board/termtest.sh` drives both.

Measured on board 1, 2026-11-08: btop 1.4.8 draws all panels, 24 CPU
threads, truecolor theme, braille meters and box-drawn frames.

Not yet: copy (selection), multiple windows/tabs, underline/strikethrough
drawing, combining characters, font fallback for colour emoji.
