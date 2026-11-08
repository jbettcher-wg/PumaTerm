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
#import "PrefsWindow.h"
#import "Prefs.h"
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
	const char *nw = test_env("PUMATERM_TEST_WINDOWS");	/* test hook */
	int i, count = nw ? atoi(nw) : 1;

	(void)n;
	windows = [[NSMutableArray alloc] init];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowClosed:)
		name:TermWindowClosedNotification object:nil];
	for (i = 0; i < (count > 0 ? count : 1); i++)
		[self newWindow:nil];
	if (test_env("PUMATERM_TEST_PREFS"))		/* test hook */
		[[PrefsWindow shared] showForTest];
	if (test_env("PUMATERM_TEST_LIVE"))		/* test hook */
		[self performSelector:@selector(liveChange:) withObject:nil afterDelay:3.0];
}

/* Test hook: change scheme and font size while running, as the
 * Preferences window would, but in the argument domain, which is never
 * written to disk, so the user's settings are untouched. */
- (void)liveChange:(id)o
{
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
		prefs_scheme_values([NSString stringWithUTF8String:test_env("PUMATERM_TEST_LIVE")])];

	(void)o;
	[d setObject:[NSNumber numberWithFloat:16] forKey:kPrefFontSize];
	[d addEntriesFromDictionary:[[NSUserDefaults standardUserDefaults]
		volatileDomainForName:NSArgumentDomain]];
	[d setObject:[NSNumber numberWithFloat:16] forKey:kPrefFontSize];
	[[NSUserDefaults standardUserDefaults] setVolatileDomain:d forName:NSArgumentDomain];
	prefs_changed();
}

- (void)newWindow:(id)sender
{
	TermWindow *tw;

	(void)sender;
	tw = [[TermWindow alloc] initWithCascadeFrom:&cascade];
	[windows addObject:tw];
	[tw release];
	if (test_env("PUMATERM_STARTUP_INPUT"))	/* a test launch: stay out of the way */
		[[tw window] orderBack:nil];
	else
		[[tw window] makeKeyAndOrderFront:nil];
}

- (void)showPreferences:(id)sender
{
	(void)sender;
	[[PrefsWindow shared] show];
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

	[app addItemWithTitle:[NSString stringWithFormat:@"Preferences%C", (unichar)0x2026] action:@selector(showPreferences:) keyEquivalent:@","];
	[app addItem:[NSMenuItem separatorItem]];
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
	prefs_register();
	[app setMainMenu:build_menu()];
	/* -[NSApplication setAppleMenu:] is private on 10.5; the first item of
	 * the main menu is the application menu either way. */
	[app setDelegate:delegate];
	[app run];
	[delegate release];
	[pool release];
	return 0;
}
