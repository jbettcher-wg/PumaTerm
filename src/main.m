/*
 * main.m -- the application: a menu bar and one window holding a TermView.
 *
 * No nib: everything is built here so the bundle is just the binary and its
 * Info.plist. The app quits when its window closes, which happens when the
 * shell exits.
 */
#import <Cocoa/Cocoa.h>
#import "TermView.h"
#include <stdlib.h>

#define DEFAULT_COLS	100
#define DEFAULT_ROWS	32

@interface TermApp : NSObject
@end

@implementation TermApp

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
	(void)app;
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
	NSString *font = [[NSUserDefaults standardUserDefaults] stringForKey:@"Font"];
	float size = [[NSUserDefaults standardUserDefaults] floatForKey:@"FontSize"];
	TermView *probe, *view;
	NSSize cell;
	NSRect frame;
	NSWindow *w;

	(void)n;
	if (font == nil)
		font = @"Monaco";
	if (size <= 0)
		size = 12;

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
	[w center];
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
	NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
	NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
	NSMenuItem *i;

	[app addItemWithTitle:@"Hide term" action:@selector(hide:) keyEquivalent:@"h"];
	[app addItem:[NSMenuItem separatorItem]];
	[app addItemWithTitle:@"Quit term" action:@selector(terminate:) keyEquivalent:@"q"];
	[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[win addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];

	i = [bar addItemWithTitle:@"term" action:NULL keyEquivalent:@""];
	[bar setSubmenu:app forItem:i];
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
