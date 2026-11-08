/*
 * Prefs.m -- PumaTerm's settings: the keys, their defaults, colour schemes.
 *
 * Everything lives in NSUserDefaults, so `defaults write
 * org.xnu-t4240.pumaterm Key value` and the Preferences window are two
 * views of the same thing.
 */
#import "Prefs.h"
#include <stdio.h>

NSString *const PrefsChangedNotification = @"PumaTermPrefsChanged";

/* A preset: text, background, cursor, selection, then ANSI 0-15. */
struct scheme { NSString *name; const char *c[20]; };

static const struct scheme schemes[] = {
	/* PumaTerm's own: near-black ground; ANSI as libvterm defines it. */
	{ @"PumaTerm", { "#d8d8d8", "#121214", "#d8d8d8", "#3a3d4a",
	  "#000000", "#e00000", "#00e000", "#e0e000", "#0000e0", "#e000e0", "#00e0e0", "#e0e0e0",
	  "#808080", "#ff4040", "#40ff40", "#ffff40", "#4040ff", "#ff40ff", "#40ffff", "#ffffff" } },
	/* The Tango project's terminal palette. */
	{ @"Tango Dark", { "#d3d7cf", "#2e3436", "#d3d7cf", "#555753",
	  "#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
	  "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec" } },
	/* Ethan Schoonover's Solarized, dark: base03 ground, base0 text. */
	{ @"Solarized Dark", { "#839496", "#002b36", "#93a1a1", "#073642",
	  "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
	  "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3" } },
	/* Dracula. */
	{ @"Dracula", { "#f8f8f2", "#282a36", "#f8f8f2", "#44475a",
	  "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
	  "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff" } },
};
#define NSCHEMES (int)(sizeof schemes / sizeof schemes[0])

static NSArray *palette_of(const struct scheme *s)
{
	NSMutableArray *a = [NSMutableArray array];
	int i;

	for (i = 0; i < 16; i++)
		[a addObject:[NSString stringWithUTF8String:s->c[4 + i]]];
	return a;
}

void prefs_register(void)
{
	const struct scheme *s = &schemes[0];
	NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithFloat:12], kPrefFontSize,
		[NSString stringWithUTF8String:s->c[0]], kPrefForeground,
		[NSString stringWithUTF8String:s->c[1]], kPrefBackground,
		[NSString stringWithUTF8String:s->c[2]], kPrefCursorColor,
		[NSString stringWithUTF8String:s->c[3]], kPrefSelection,
		palette_of(s), kPrefPalette,
		s->name, kPrefScheme,
		[NSNumber numberWithFloat:1.0f], kPrefOpacity,
		[NSNumber numberWithBool:NO], kPrefBlur,
		[NSNumber numberWithFloat:6], kPrefBlurRadius,
		[NSNumber numberWithInt:CursorBlock], kPrefCursorShape,
		[NSNumber numberWithBool:NO], kPrefCursorBlink,
		[NSNumber numberWithInt:0], kPrefShellMode,
		@"", kPrefShellCommand,
		[NSNumber numberWithInt:100], kPrefColumns,
		[NSNumber numberWithInt:32], kPrefRows,
		[NSNumber numberWithInt:10000], kPrefScrollback,
		[NSNumber numberWithInt:BellAudible], kPrefBell,
		[NSNumber numberWithBool:YES], kPrefOptionMeta,
		nil];

	[[NSUserDefaults standardUserDefaults] registerDefaults:d];
}

/* The Font default if installed, else Hack Nerd Font Mono where it is
 * installed (its icons are what prompts and status bars draw now), else
 * Monaco. A name Core Text does not know falls back silently to a
 * proportional face, so it is checked rather than trusted. */
NSString *prefs_font(float *size)
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	NSString *f = [u stringForKey:kPrefFont];
	float sz = [u floatForKey:kPrefFontSize];

	if (sz < 6 || sz > 72)
		sz = 12;
	*size = sz;
	if (f != nil && [NSFont fontWithName:f size:sz] != nil)
		return f;
	if ([NSFont fontWithName:@"HackNFM-Regular" size:sz] != nil)
		return @"HackNFM-Regular";
	return @"Monaco";
}

static void parse_hex(NSString *s, unsigned char out[3])
{
	unsigned r = 0, g = 0, b = 0;

	if (s == nil || sscanf([s UTF8String], "#%2x%2x%2x", &r, &g, &b) != 3)
		r = g = b = 0x80;
	out[0] = r; out[1] = g; out[2] = b;
}

static NSString *hex_of(NSColor *c)
{
	NSColor *rgb = [c colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

	return [NSString stringWithFormat:@"#%02x%02x%02x",
		(int)lroundf([rgb redComponent] * 255),
		(int)lroundf([rgb greenComponent] * 255),
		(int)lroundf([rgb blueComponent] * 255)];
}

static NSColor *color_of(const unsigned char c[3])
{
	return [NSColor colorWithCalibratedRed:c[0] / 255.0f green:c[1] / 255.0f
					  blue:c[2] / 255.0f alpha:1];
}

void prefs_rgb(NSString *key, unsigned char out[3])
{
	parse_hex([[NSUserDefaults standardUserDefaults] stringForKey:key], out);
}

void prefs_palette_rgb(int i, unsigned char out[3])
{
	NSArray *p = [[NSUserDefaults standardUserDefaults] arrayForKey:kPrefPalette];

	parse_hex(i < (int)[p count] ? [p objectAtIndex:i] : nil, out);
}

NSColor *prefs_color(NSString *key)
{
	unsigned char c[3];

	prefs_rgb(key, c);
	return color_of(c);
}

NSColor *prefs_palette_color(int i)
{
	unsigned char c[3];

	prefs_palette_rgb(i, c);
	return color_of(c);
}

void prefs_set_color(NSString *key, NSColor *c)
{
	[[NSUserDefaults standardUserDefaults] setObject:hex_of(c) forKey:key];
}

void prefs_set_palette_color(int i, NSColor *c)
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	NSMutableArray *p = [NSMutableArray arrayWithArray:[u arrayForKey:kPrefPalette]];

	while ((int)[p count] < 16)
		[p addObject:@"#808080"];
	[p replaceObjectAtIndex:i withObject:hex_of(c)];
	[u setObject:p forKey:kPrefPalette];
}

NSArray *prefs_scheme_names(void)
{
	NSMutableArray *a = [NSMutableArray array];
	int i;

	for (i = 0; i < NSCHEMES; i++)
		[a addObject:schemes[i].name];
	return a;
}

NSDictionary *prefs_scheme_values(NSString *name)
{
	int i;

	for (i = 0; i < NSCHEMES; i++) {
		const struct scheme *s = &schemes[i];
		if ([s->name isEqualToString:name])
			return [NSDictionary dictionaryWithObjectsAndKeys:
				[NSString stringWithUTF8String:s->c[0]], kPrefForeground,
				[NSString stringWithUTF8String:s->c[1]], kPrefBackground,
				[NSString stringWithUTF8String:s->c[2]], kPrefCursorColor,
				[NSString stringWithUTF8String:s->c[3]], kPrefSelection,
				palette_of(s), kPrefPalette,
				name, kPrefScheme, nil];
	}
	return nil;
}

void prefs_apply_scheme(NSString *name)
{
	NSDictionary *d = prefs_scheme_values(name);
	NSEnumerator *e = [d keyEnumerator];
	NSString *k;

	while ((k = [e nextObject]) != nil)
		[[NSUserDefaults standardUserDefaults] setObject:[d objectForKey:k] forKey:k];
}

void prefs_changed(void)
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PrefsChangedNotification object:nil];
}
