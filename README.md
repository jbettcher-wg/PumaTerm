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

Cmd-N opens another window (each its own shell and pty), cascaded.

Defaults: `defaults write org.xnu-t4240.term Font Monaco`, `FontSize 12`.
With no `Font` set, or one that is not installed, Term takes Hack Nerd Font
Mono if it is in a Fonts folder and Monaco if not.
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
(bracketed); Option is Meta. Drag selects, double-click takes a word (path
and URL punctuation included), triple-click a line; Shift selects even when
a program has the mouse (btop, vim with mouse=a). Cmd-C copies, with lines
the terminal wrapped joined back into one.

Test hooks (for checking rendering over ssh without touching the desktop):
`TERM_STARTUP_INPUT='btop\n'` types into the shell after start and opens the
window behind the others; `kill -USR1 <pid>` writes the next frame to
`/tmp/term-frame.png`; `TERM_TEST_SELECT="line col line col unit"` (unit 1
cell, 2 word, 3 line) makes that selection at the dump and prints what Copy
would take to stdout, so the clipboard is never touched.
`TERM_TEST_WINDOWS=n` opens n windows at launch.
`proving-ground/board/termtest.sh` drives all four, and passes `TERM_ARGS`
(e.g. `-Font HackNFM-Regular`) through.

Measured on board 1, 2026-11-08: btop 1.4.8 draws all panels, 24 CPU
threads, truecolor theme, braille meters and box-drawn frames.

Not yet: tabs, combining characters drawn over their base,
colour emoji, a preferences window.
