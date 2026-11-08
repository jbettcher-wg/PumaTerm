/*
 * main.m -- the application: a menu bar and windows each holding a TermView.
 *
 * No nib: everything is built here so the bundle is just the binary and its
 * Info.plist. A window closes when its shell exits, and the app quits when
 * the last one closes.
 */
#import <Cocoa/Cocoa.h>
#import "TermView.h"
#include <stdlib.h>

#define DEFAULT_COLS	100
#define DEFAULT_ROWS	32

@interface TermApp : NSObject {
	NSPoint	cascade;
}
- (void)newWindow:(id)sender;
@end

@implementation TermApp

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
	(void)app;
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
	const char *nw = getenv("TERM_TEST_WINDOWS");	/* test hook */
	int i, count = nw ? atoi(nw) : 1;

	(void)n;
	for (i = 0; i < (count > 0 ? count : 1); i++)
		[self newWindow:nil];
}

/* The Font default if set, else Hack Nerd Font Mono where it is installed
 * (its icons are what prompts and status bars draw now), else Monaco. A
 * name Core Text does not know falls back silently to a proportional
 * face, so it is checked here rather than trusted. */
static NSString *chosen_font(float size)
{
	NSString *f = [[NSUserDefaults standardUserDefaults] stringForKey:@"Font"];

	if (f != nil && [NSFont fontWithName:f size:size] != nil)
		return f;
	if ([NSFont fontWithName:@"HackNFM-Regular" size:size] != nil)
		return @"HackNFM-Regular";
	return @"Monaco";
}

- (void)newWindow:(id)sender
{
	float size = [[NSUserDefaults standardUserDefaults] floatForKey:@"FontSize"];
	NSString *font;
	TermView *probe, *view;
	NSSize cell;
	NSRect frame;
	NSWindow *w;
	BOOL first = NSEqualPoints(cascade, NSZeroPoint);

	(void)sender;
	if (size <= 0)
		size = 12;
	font = chosen_font(size);

	/* Size the window to whole cells, then give the terminal that frame. */
	probe = [[TermView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) fontName:font size:size];
	cell = [probe cellSize];
	[probe release];
	frame = NSMakeRect(0, 0, cell.width * DEFAULT_COLS, cell.height * DEFAULT_ROWS);

	w = [[NSWindow alloc] initWithContentRect:frame
		styleMask:NSTitledWindowMask | NSClosableWindowMask |
			  NSMiniaturizableWindowMask | NSResizableWindowMask
		backing:NSBackingStoreBuffered defer:NO];
	[w setContentResizeIncrements:cell];
	[w setTitle:@"term"];
	view = [[TermView alloc] initWithFrame:frame fontName:font size:size];
	[w setContentView:view];
	[w makeFirstResponder:view];
	/* The first window is centred; each later one steps down and right
	 * from the one before. A zero point leaves a window where it is. */
	if (first)
		[w center];
	cascade = [w cascadeTopLeftFromPoint:cascade];
	if (getenv("TERM_STARTUP_INPUT"))	/* a test launch: stay out of the way */
		[w orderBack:nil];
	else
		[w makeKeyAndOrderFront:nil];
	[view startShell];
	[view release];
}

@end

static NSMenu *build_menu(void)
{
	NSMenu *bar = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	NSMenu *app = [[[NSMenu alloc] initWithTitle:@"term"] autorelease];
	NSMenu *shell = [[[NSMenu alloc] initWithTitle:@"Shell"] autorelease];
	NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
	NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
	NSMenuItem *i;

	[app addItemWithTitle:@"Hide term" action:@selector(hide:) keyEquivalent:@"h"];
	[app addItem:[NSMenuItem separatorItem]];
	[app addItemWithTitle:@"Quit term" action:@selector(terminate:) keyEquivalent:@"q"];
	[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"];
	[shell addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
	[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];

	i = [bar addItemWithTitle:@"term" action:NULL keyEquivalent:@""];
	[bar setSubmenu:app forItem:i];
	i = [bar addItemWithTitle:@"Shell" action:NULL keyEquivalent:@""];
	[bar setSubmenu:shell forItem:i];
	i = [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
	[bar setSubmenu:edit forItem:i];
	i = [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
	[bar setSubmenu:win forItem:i];
	return bar;
}

int main(int argc, char **argv)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSApplication *app = [NSApplication sharedApplication];
	TermApp *delegate = [[TermApp alloc] init];

	(void)argc;
	(void)argv;
	[app setMainMenu:build_menu()];
	/* -[NSApplication setAppleMenu:] is private on 10.5; the first item of
	 * the main menu is the application menu either way. */
	[app setDelegate:delegate];
	[app run];
	[delegate release];
	[pool release];
	return 0;
}
