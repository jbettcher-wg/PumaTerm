/* Prefs.h -- PumaTerm's settings: the keys, their defaults, colour schemes. */
#import <Cocoa/Cocoa.h>
#include <stdlib.h>

/* Posted when any setting changes; open windows re-read what they use. */
extern NSString *const PrefsChangedNotification;

/* Keys in the io.github.jbettcher-wg.PumaTerm defaults domain. Colours are stored
 * as "#rrggbb" strings so `defaults read` stays legible. */
#define kPrefFont		@"Font"		/* PostScript name */
#define kPrefFontSize		@"FontSize"
#define kPrefForeground		@"Foreground"
#define kPrefBackground		@"Background"
#define kPrefCursorColor	@"CursorColor"
#define kPrefSelection		@"SelectionColor"
#define kPrefPalette		@"Palette"	/* 16 colours, ANSI 0-15 */
#define kPrefScheme		@"Scheme"	/* name of the last preset applied */
#define kPrefOpacity		@"Opacity"	/* background, 0.2 - 1.0 */
#define kPrefBlur		@"Blur"		/* blur what is behind the window */
#define kPrefBlurRadius		@"BlurRadius"
#define kPrefCursorShape	@"CursorShape"	/* 0 block, 1 underline, 2 bar */
#define kPrefCursorBlink	@"CursorBlink"
#define kPrefShellMode		@"ShellMode"	/* 0 login shell, 1 command */
#define kPrefShellCommand	@"ShellCommand"
#define kPrefColumns		@"Columns"
#define kPrefRows		@"Rows"
#define kPrefScrollback		@"Scrollback"
#define kPrefBell		@"Bell"		/* 0 none, 1 visual, 2 audible */
#define kPrefOptionMeta		@"OptionIsMeta"

enum { CursorBlock, CursorUnderline, CursorBar };

/* A PUMATERM_* test hook's value, or NULL when unset or empty: the test
 * script passes every hook, empty when unused, and an empty one must not
 * count as set. */
static inline const char *test_env(const char *name)
{
	const char *v = getenv(name);

	return v && *v ? v : NULL;
}
enum { BellNone, BellVisual, BellAudible };

void      prefs_register(void);
NSString *prefs_font(float *size);	/* checked to exist, with fallbacks */
void      prefs_rgb(NSString *key, unsigned char out[3]);
void      prefs_palette_rgb(int i, unsigned char out[3]);
NSColor  *prefs_color(NSString *key);
NSColor  *prefs_palette_color(int i);
void      prefs_set_color(NSString *key, NSColor *c);
void      prefs_set_palette_color(int i, NSColor *c);
NSArray  *prefs_scheme_names(void);
void      prefs_apply_scheme(NSString *name);
NSDictionary *prefs_scheme_values(NSString *name);
void      prefs_changed(void);		/* post PrefsChangedNotification */
