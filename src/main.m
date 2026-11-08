/*
 * main.m -- the application: a menu bar and its TermWindows.
 *
 * No nib: everything is built here so the bundle is just the binary and its
 * Info.plist. A tab closes when its shell exits, a window with its last
 * tab, and the app with its last window.
 */
#import <Cocoa/Cocoa.h>
#import "TermView.h"
#import "TermWindow.h"
#include <stdlib.h>

@interface TermApp : NSObject {
	NSMutableArray	*windows;		/* TermWindow controllers */
	NSPoint		 cascade;
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
	const char *nw = getenv("PUMATERM_TEST_WINDOWS");	/* test hook */
	int i, count = nw ? atoi(nw) : 1;

	(void)n;
	windows = [[NSMutableArray alloc] init];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowClosed:)
		name:TermWindowClosedNotification object:nil];
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
	TermWindow *tw;

	(void)sender;
	if (size <= 0)
		size = 12;
	tw = [[TermWindow alloc] initWithFont:chosen_font(size) size:size cascadeFrom:&cascade];
	[windows addObject:tw];
	[tw release];
	if (getenv("PUMATERM_STARTUP_INPUT"))	/* a test launch: stay out of the way */
		[[tw window] orderBack:nil];
	else
		[[tw window] makeKeyAndOrderFront:nil];
}

- (void)windowClosed:(NSNotification *)n
{
	[windows removeObject:[n object]];
}

@end

static NSMenu *build_menu(void)
{
	NSMenu *bar = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	NSMenu *app = [[[NSMenu alloc] initWithTitle:@"PumaTerm"] autorelease];
	NSMenu *shell = [[[NSMenu alloc] initWithTitle:@"Shell"] autorelease];
	NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
	NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
	NSMenuItem *i;

	[app addItemWithTitle:@"Hide PumaTerm" action:@selector(hide:) keyEquivalent:@"h"];
	[app addItem:[NSMenuItem separatorItem]];
	[app addItemWithTitle:@"Quit PumaTerm" action:@selector(terminate:) keyEquivalent:@"q"];
	[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"];
	[shell addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"t"];
	[shell addItem:[NSMenuItem separatorItem]];
	[shell addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
	[shell addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"W"];
	[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[win addItem:[NSMenuItem separatorItem]];
	[win addItemWithTitle:@"Select Next Tab" action:@selector(selectNextTab:) keyEquivalent:@"}"];
	[win addItemWithTitle:@"Select Previous Tab" action:@selector(selectPreviousTab:) keyEquivalent:@"{"];

	i = [bar addItemWithTitle:@"PumaTerm" action:NULL keyEquivalent:@""];
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
