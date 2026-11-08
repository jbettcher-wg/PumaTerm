# PumaTerm -- a GL-accelerated terminal for Mac OS X 10.5 PowerPC

Named for Mac OS X 10.1's codename, one cat before the Leopard it runs on.

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
| `src/TermWindow.m` | a window: the tab strip and the selected terminal; unselected tabs stay out of the view tree, shells running |
| `src/Prefs.m` | the settings: keys, defaults, colour schemes (PumaTerm, Tango Dark, Solarized Dark, Dracula) |
| `src/PrefsWindow.m` | Preferences (Cmd-,): General, Appearance, Colors, built in code |
| `src/main.m` | the app: menu bar and windows, no nib |

Build natively on a board (Apple's gcc-4.2: Objective-C and the 10.5 SDK):

    make            # -> build/PumaTerm.app
    make install    # -> /Applications/PumaTerm.app

Cmd-N opens another window, Cmd-T another tab (each tab its own shell and
pty); Cmd-W closes a tab, Shift-Cmd-W the window, Shift-Cmd-[ and ] move
between tabs, and a tab is labelled with the title its program sets (OSC 0/2).
The tab strip appears with the second tab, and the window grows by its
height so the terminal keeps its rows.

Preferences (Cmd-,), each applied to open windows at once:

- **General**: the shell (login shell, or a command: a bare path such as
  `/opt/local/bin/zsh` runs as a login shell, anything with arguments under
  `/bin/sh -c`), new-window size, scrollback (new tabs), bell (none, a
  flash, audible), Option as Meta.
- **Appearance**: font (the font panel), cursor (block, underline, bar;
  blink; an outline when the window is not key, as Terminal.app),
  background opacity, and blur of what is behind the window.
- **Colors**: a scheme, then text, background, cursor, selection and the 16
  ANSI colours individually; editing any of them makes the scheme Custom.

Opacity applies to the default background only, so a program's coloured
cells stay solid, as in iTerm. The blur is CoreGraphics' private window
filter (`CGSAddWindowFilter` with a `CIGaussianBlur`, flags 0x3001), which
10.5 exports; it is what iTerm used before 10.6.

Every setting is a key in `org.xnu-t4240.pumaterm` (see `src/Prefs.h`), so
`defaults write org.xnu-t4240.pumaterm Opacity 0.85` works too. `Font` is the
**PostScript** name, not the file or family name, and an unknown one falls
back to Hack Nerd Font Mono if installed, else Monaco.

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
`PUMATERM_STARTUP_INPUT='btop\n'` types into the shell after start and opens the
window behind the others; `kill -USR1 <pid>` writes the next frame to
`/tmp/pumaterm-frame.png` (RGB, as GL drew it) and
`/tmp/pumaterm-window.png` (the window as the window server composites it,
which is what shows translucency); `PUMATERM_TEST_SELECT="line col line col unit"` (unit 1
cell, 2 word, 3 line) makes that selection at the dump and prints what Copy
would take to stdout, so the clipboard is never touched.
`PUMATERM_TEST_WINDOWS=n` opens n windows at launch, and `PUMATERM_TEST_TABS=n` n tabs
in each, writing the tab strip to `/tmp/pumaterm-tabs.png`.
`PUMATERM_TEST_PREFS=1` opens Preferences behind everything and writes each
page to `/tmp/pumaterm-prefs-N.png`; `PUMATERM_TEST_LIVE=<scheme>` switches to
that scheme at 16 pt three seconds in, through the argument domain, which is
never saved. Any setting can be given for one run as an argument
(`-Opacity 0.75 -CursorShape 2`), likewise never saved.
`proving-ground/board/pumatermtest.sh` drives them all from a copy in
`/tmp/PumaTermTest.app`, kills only that copy, and passes `PUMATERM_ARGS`
through.

Measured on board 1, 2026-11-08: btop 1.4.8 draws all panels, 24 CPU
threads, truecolor theme, braille meters and box-drawn frames.

Not yet: combining characters drawn over their base,
colour emoji, a preferences window.
