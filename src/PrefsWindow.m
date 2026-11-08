/*
 * PrefsWindow.m -- the Preferences window: General, Appearance, Colors.
 *
 * No nib, so the layout is a column of labelled rows placed by hand. Each
 * control's action writes its key and posts PrefsChangedNotification;
 * TermWindow and TermView apply what changed to every open tab, except
 * the shell, window size and scrollback, which only new tabs and windows
 * can take.
 */
#import "PrefsWindow.h"
#import "Prefs.h"
#include <pwd.h>
#include <unistd.h>

#define W	500			/* tab view width */
#define H	330			/* tab view height */
#define LABEL_W	150			/* right-aligned label column */

static NSTextField *label(NSView *v, NSString *s, float x, float y, float w)
{
	NSTextField *t = [[[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, 17)] autorelease];

	[t setStringValue:s];
	[t setEditable:NO];
	[t setSelectable:NO];
	[t setBezeled:NO];
	[t setDrawsBackground:NO];
	[v addSubview:t];
	return t;
}

/* A row label, right-aligned against the controls, Aqua-style. */
static void row_label(NSView *v, NSString *s, float y)
{
	NSTextField *t = label(v, s, 10, y + 3, LABEL_W);

	[t setAlignment:NSRightTextAlignment];
}

static NSTextField *field(NSView *v, float x, float y, float w, id target, SEL a)
{
	NSTextField *t = [[[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, 22)] autorelease];

	[t setTarget:target];
	[t setAction:a];
	[[t cell] setSendsActionOnEndEditing:YES];
	[v addSubview:t];
	return t;
}

static NSButton *checkbox(NSView *v, NSString *s, float x, float y, id target, SEL a)
{
	NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(x, y, 300, 20)] autorelease];

	[b setButtonType:NSSwitchButton];
	[b setTitle:s];
	[b setTarget:target];
	[b setAction:a];
	[v addSubview:b];
	return b;
}

static NSPopUpButton *popup(NSView *v, NSArray *items, float x, float y, float w, id target, SEL a)
{
	NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y - 2, w, 26)
						       pullsDown:NO] autorelease];

	[p addItemsWithTitles:items];
	[p setTarget:target];
	[p setAction:a];
	[v addSubview:p];
	return p;
}

static NSColorWell *well(NSView *v, float x, float y, float w, id target, SEL a, int tag)
{
	NSColorWell *c = [[[NSColorWell alloc] initWithFrame:NSMakeRect(x, y, w, 24)] autorelease];

	[c setTarget:target];
	[c setAction:a];
	[c setTag:tag];
	[v addSubview:c];
	return c;
}

static NSSlider *slider(NSView *v, float x, float y, float w, double lo, double hi, id target, SEL a)
{
	NSSlider *s = [[[NSSlider alloc] initWithFrame:NSMakeRect(x, y, w, 22)] autorelease];

	[s setMinValue:lo];
	[s setMaxValue:hi];
	[s setContinuous:YES];
	[s setTarget:target];
	[s setAction:a];
	[v addSubview:s];
	return s;
}

@interface PrefsWindow ()
- (void)build;
- (void)load;
@end

@implementation PrefsWindow

+ (PrefsWindow *)shared
{
	static PrefsWindow *p;

	if (p == nil)
		p = [[PrefsWindow alloc] init];
	return p;
}

- (void)show
{
	if (window == nil)
		[self build];
	[self load];
	[window makeKeyAndOrderFront:nil];
}

/* Test hook (PUMATERM_TEST_PREFS): open behind the other windows and write
 * each page to /tmp/pumaterm-prefs-N.png, so the layout can be checked
 * over ssh without taking the desktop. */
- (void)dumpPages
{
	NSView *cv = [window contentView];
	NSTabView *tabs = [[cv subviews] objectAtIndex:0];
	int i;

	for (i = 0; i < [tabs numberOfTabViewItems]; i++) {
		NSBitmapImageRep *rep;

		[tabs selectTabViewItemAtIndex:i];
		[cv display];
		rep = [cv bitmapImageRepForCachingDisplayInRect:[cv bounds]];
		[cv cacheDisplayInRect:[cv bounds] toBitmapImageRep:rep];
		[[rep representationUsingType:NSPNGFileType properties:nil]
			writeToFile:[NSString stringWithFormat:@"/tmp/pumaterm-prefs-%d.png", i]
			 atomically:NO];
	}
}

- (void)showForTest
{
	if (window == nil)
		[self build];
	[self load];
	[window orderBack:nil];
	[self performSelector:@selector(dumpPages) withObject:nil afterDelay:2.0];
}

/* ---- layout ------------------------------------------------------------ */

- (NSView *)general
{
	NSView *v = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)] autorelease];
	struct passwd *pw = getpwuid(getuid());
	NSString *login = [NSString stringWithFormat:@"Default login shell (%s)",
				   pw && pw->pw_shell ? pw->pw_shell : "/bin/bash"];
	NSButtonCell *proto = [[[NSButtonCell alloc] init] autorelease];
	float x = LABEL_W + 18, y = H - 40;

	row_label(v, @"Shells open with:", y);
	[proto setButtonType:NSRadioButton];
	shellMode = [[[NSMatrix alloc] initWithFrame:NSMakeRect(x, y - 22, 300, 44)
					       mode:NSRadioModeMatrix prototype:proto
					 numberOfRows:2 numberOfColumns:1] autorelease];
	[shellMode setCellSize:NSMakeSize(300, 20)];
	[shellMode setIntercellSpacing:NSMakeSize(0, 4)];
	[[shellMode cellAtRow:0 column:0] setTitle:login];
	[[shellMode cellAtRow:1 column:0] setTitle:@"Command (complete path):"];
	[shellMode setTarget:self];
	[shellMode setAction:@selector(shellModeChanged:)];
	[v addSubview:shellMode];
	y -= 52;
	shellCommand = field(v, x + 18, y, 280, self, @selector(shellCommandChanged:));
	[[shellCommand cell] setPlaceholderString:@"/opt/local/bin/zsh"];

	y -= 40;
	row_label(v, @"New windows:", y);
	columns = field(v, x, y, 50, self, @selector(sizeChanged:));
	label(v, @"columns", x + 56, y + 3, 60);
	rowsField = field(v, x + 120, y, 50, self, @selector(sizeChanged:));
	label(v, @"rows", x + 176, y + 3, 60);

	y -= 34;
	row_label(v, @"Scrollback:", y);
	scrollback = field(v, x, y, 70, self, @selector(scrollbackChanged:));
	label(v, @"lines, for new tabs", x + 76, y + 3, 200);

	y -= 40;
	row_label(v, @"Bell:", y);
	bell = popup(v, [NSArray arrayWithObjects:@"None", @"Visual (flash)", @"Audible", nil],
		     x, y, 160, self, @selector(bellChanged:));

	y -= 36;
	row_label(v, @"Keyboard:", y);
	optionMeta = checkbox(v, @"Use Option as Meta key", x, y + 2, self, @selector(optionChanged:));
	return v;
}

- (NSView *)appearance
{
	NSView *v = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)] autorelease];
	NSButton *b;
	float x = LABEL_W + 18, y = H - 40;

	row_label(v, @"Font:", y);
	fontLabel = label(v, @"", x, y + 3, 200);
	b = [[[NSButton alloc] initWithFrame:NSMakeRect(x + 200, y - 4, 100, 30)] autorelease];
	[b setBezelStyle:NSRoundedBezelStyle];
	[b setTitle:[NSString stringWithFormat:@"Change%C", (unichar)0x2026]];
	[b setTarget:self];
	[b setAction:@selector(chooseFont:)];
	[v addSubview:b];

	y -= 44;
	row_label(v, @"Cursor:", y);
	cursorShape = popup(v, [NSArray arrayWithObjects:@"Block", @"Underline", @"Vertical bar", nil],
			    x, y, 140, self, @selector(cursorChanged:));
	cursorBlink = checkbox(v, @"Blink", x + 154, y + 2, self, @selector(cursorChanged:));

	y -= 48;
	row_label(v, @"Background opacity:", y);
	opacity = slider(v, x, y, 220, 20, 100, self, @selector(opacityChanged:));
	opacityLabel = label(v, @"", x + 228, y + 3, 50);

	y -= 34;
	blur = checkbox(v, @"Blur what is behind the window", x, y, self, @selector(blurChanged:));
	y -= 30;
	row_label(v, @"Blur radius:", y);
	blurRadius = slider(v, x, y, 220, 1, 20, self, @selector(blurChanged:));

	y -= 40;
	label(v, @"Opacity applies to the default background; cells a program colours stay solid.",
	      20, y, W - 40);
	return v;
}

- (NSView *)colors
{
	NSView *v = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)] autorelease];
	float x = LABEL_W + 18, y = H - 40;
	int i;

	row_label(v, @"Scheme:", y);
	scheme = popup(v, prefs_scheme_names(), x, y, 180, self, @selector(schemeChanged:));
	[scheme addItemWithTitle:@"Custom"];

	y -= 44;
	row_label(v, @"Text:", y);
	fg = well(v, x, y, 44, self, @selector(colorChanged:), 0);
	label(v, @"Background:", x + 70, y + 3, 90);
	bg = well(v, x + 162, y, 44, self, @selector(colorChanged:), 1);
	y -= 34;
	row_label(v, @"Cursor:", y);
	cursorColor = well(v, x, y, 44, self, @selector(colorChanged:), 2);
	label(v, @"Selection:", x + 70, y + 3, 90);
	selection = well(v, x + 162, y, 44, self, @selector(colorChanged:), 3);

	y -= 48;
	row_label(v, @"ANSI colours:", y);
	for (i = 0; i < 8; i++)
		ansi[i] = well(v, x + i * 38, y, 34, self, @selector(ansiChanged:), i);
	y -= 30;
	row_label(v, @"Bright:", y);
	for (i = 8; i < 16; i++)
		ansi[i] = well(v, x + (i - 8) * 38, y, 34, self, @selector(ansiChanged:), i);
	return v;
}

- (void)build
{
	NSTabView *tabs = [[[NSTabView alloc] initWithFrame:NSMakeRect(10, 10, W, H + 36)] autorelease];
	NSArray *names = [NSArray arrayWithObjects:@"General", @"Appearance", @"Colors", nil];
	NSView *pages[3];
	int i;

	pages[0] = [self general];
	pages[1] = [self appearance];
	pages[2] = [self colors];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W + 20, H + 56)
		styleMask:NSTitledWindowMask | NSClosableWindowMask
		backing:NSBackingStoreBuffered defer:YES];
	[window setTitle:@"PumaTerm Preferences"];
	[window setReleasedWhenClosed:NO];
	[window setDelegate:self];		/* changeFont: comes up the chain */
	for (i = 0; i < 3; i++) {
		NSTabViewItem *t = [[[NSTabViewItem alloc] initWithIdentifier:[names objectAtIndex:i]] autorelease];
		[t setLabel:[names objectAtIndex:i]];
		[t setView:pages[i]];
		[tabs addTabViewItem:t];
	}
	[[window contentView] addSubview:tabs];
	[window center];
}

/* ---- reading the settings into the controls ----------------------------- */

- (void)load
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	float size;
	NSString *font = prefs_font(&size), *sch = [u stringForKey:kPrefScheme];
	int i;

	[shellMode selectCellAtRow:[u integerForKey:kPrefShellMode] == 1 ? 1 : 0 column:0];
	[shellCommand setStringValue:[u stringForKey:kPrefShellCommand]];
	[shellCommand setEnabled:[u integerForKey:kPrefShellMode] == 1];
	[columns setIntValue:[u integerForKey:kPrefColumns]];
	[rowsField setIntValue:[u integerForKey:kPrefRows]];
	[scrollback setIntValue:[u integerForKey:kPrefScrollback]];
	[bell selectItemAtIndex:[u integerForKey:kPrefBell]];
	[optionMeta setState:[u boolForKey:kPrefOptionMeta]];

	[fontLabel setStringValue:[NSString stringWithFormat:@"%@ %g pt", font, size]];
	[cursorShape selectItemAtIndex:[u integerForKey:kPrefCursorShape]];
	[cursorBlink setState:[u boolForKey:kPrefCursorBlink]];
	[opacity setFloatValue:[u floatForKey:kPrefOpacity] * 100];
	[opacityLabel setStringValue:[NSString stringWithFormat:@"%d%%", [opacity intValue]]];
	[blur setState:[u boolForKey:kPrefBlur]];
	[blurRadius setFloatValue:[u floatForKey:kPrefBlurRadius]];
	[blur setEnabled:[opacity intValue] < 100];
	[blurRadius setEnabled:[opacity intValue] < 100 && [blur state]];

	if ([scheme indexOfItemWithTitle:sch] >= 0)
		[scheme selectItemWithTitle:sch];
	else
		[scheme selectItemWithTitle:@"Custom"];
	[fg setColor:prefs_color(kPrefForeground)];
	[bg setColor:prefs_color(kPrefBackground)];
	[cursorColor setColor:prefs_color(kPrefCursorColor)];
	[selection setColor:prefs_color(kPrefSelection)];
	for (i = 0; i < 16; i++)
		[ansi[i] setColor:prefs_palette_color(i)];
}

/* ---- actions ------------------------------------------------------------ */

static void set_int(NSString *k, int v)
{
	[[NSUserDefaults standardUserDefaults] setInteger:v forKey:k];
}

- (void)shellModeChanged:(id)s
{
	(void)s;
	set_int(kPrefShellMode, [shellMode selectedRow]);
	[shellCommand setEnabled:[shellMode selectedRow] == 1];
	if ([shellMode selectedRow] == 1)
		[window makeFirstResponder:shellCommand];
}

- (void)shellCommandChanged:(id)s
{
	(void)s;
	[[NSUserDefaults standardUserDefaults] setObject:[shellCommand stringValue]
						  forKey:kPrefShellCommand];
}

- (void)sizeChanged:(id)s
{
	(void)s;
	set_int(kPrefColumns, MAX(20, [columns intValue]));
	set_int(kPrefRows, MAX(5, [rowsField intValue]));
	[columns setIntValue:MAX(20, [columns intValue])];
	[rowsField setIntValue:MAX(5, [rowsField intValue])];
}

- (void)scrollbackChanged:(id)s
{
	(void)s;
	set_int(kPrefScrollback, MIN(200000, MAX(100, [scrollback intValue])));
	[scrollback setIntValue:[[NSUserDefaults standardUserDefaults] integerForKey:kPrefScrollback]];
}

- (void)bellChanged:(id)s
{
	(void)s;
	set_int(kPrefBell, [bell indexOfSelectedItem]);
	prefs_changed();
}

- (void)optionChanged:(id)s
{
	(void)s;
	[[NSUserDefaults standardUserDefaults] setBool:[optionMeta state] forKey:kPrefOptionMeta];
	prefs_changed();
}

- (void)chooseFont:(id)s
{
	float size;
	NSString *name = prefs_font(&size);
	NSFontManager *fm = [NSFontManager sharedFontManager];

	(void)s;
	[window makeFirstResponder:nil];	/* changeFont: comes to the delegate */
	[fm setSelectedFont:[NSFont fontWithName:name size:size] isMultiple:NO];
	[fm orderFrontFontPanel:self];
}

- (void)changeFont:(id)sender
{
	float size;
	NSFont *f = [sender convertFont:[NSFont fontWithName:prefs_font(&size) size:size]];
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];

	if (f == nil)
		return;
	[u setObject:[f fontName] forKey:kPrefFont];
	[u setFloat:[f pointSize] forKey:kPrefFontSize];
	[fontLabel setStringValue:[NSString stringWithFormat:@"%@ %g pt", [f fontName], [f pointSize]]];
	prefs_changed();
}

- (void)cursorChanged:(id)s
{
	(void)s;
	set_int(kPrefCursorShape, [cursorShape indexOfSelectedItem]);
	[[NSUserDefaults standardUserDefaults] setBool:[cursorBlink state] forKey:kPrefCursorBlink];
	prefs_changed();
}

- (void)opacityChanged:(id)s
{
	(void)s;
	[[NSUserDefaults standardUserDefaults] setFloat:[opacity intValue] / 100.0f forKey:kPrefOpacity];
	[opacityLabel setStringValue:[NSString stringWithFormat:@"%d%%", [opacity intValue]]];
	[blur setEnabled:[opacity intValue] < 100];
	[blurRadius setEnabled:[opacity intValue] < 100 && [blur state]];
	prefs_changed();
}

- (void)blurChanged:(id)s
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];

	(void)s;
	[u setBool:[blur state] forKey:kPrefBlur];
	[u setFloat:[blurRadius floatValue] forKey:kPrefBlurRadius];
	[blurRadius setEnabled:[blur state]];
	prefs_changed();
}

- (void)schemeChanged:(id)s
{
	(void)s;
	if ([[scheme titleOfSelectedItem] isEqualToString:@"Custom"])
		return;
	prefs_apply_scheme([scheme titleOfSelectedItem]);
	[self load];
	prefs_changed();
}

- (void)markCustom
{
	[[NSUserDefaults standardUserDefaults] setObject:@"Custom" forKey:kPrefScheme];
	[scheme selectItemWithTitle:@"Custom"];
}

- (void)colorChanged:(NSColorWell *)w
{
	static NSString *const keys[] = { kPrefForeground, kPrefBackground, kPrefCursorColor, kPrefSelection };

	prefs_set_color(keys[[w tag]], [w color]);
	[self markCustom];
	prefs_changed();
}

- (void)ansiChanged:(NSColorWell *)w
{
	prefs_set_palette_color([w tag], [w color]);
	[self markCustom];
	prefs_changed();
}

/* Closing the window commits a field being edited. */
- (void)windowWillClose:(NSNotification *)n
{
	(void)n;
	[window makeFirstResponder:nil];
	[[NSColorPanel sharedColorPanel] orderOut:nil];
}

@end
