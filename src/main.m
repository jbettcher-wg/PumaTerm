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
	if (test_env("PUMATERM_TEST_ABOUT"))		/* test hook */
		[self performSelector:@selector(dumpAbout) withObject:nil afterDelay:2.0];
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

/* The standard About panel, given the icon, the version and one line
 * saying what this is. */
- (void)showAbout:(id)sender
{
	NSString *icon = [[NSBundle mainBundle] pathForResource:@"PumaTerm" ofType:@"icns"];
	NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
	NSAttributedString *credits;
	NSMutableDictionary *o = [NSMutableDictionary dictionary];

	(void)sender;
	[ps setAlignment:NSCenterTextAlignment];
	credits = [[[NSAttributedString alloc] initWithString:
		@"An OpenGL-accelerated terminal emulator for Mac OS X.\n\n"
		@"Terminal emulation by libvterm (MIT)."
		attributes:[NSDictionary dictionaryWithObjectsAndKeys:
			[NSFont systemFontOfSize:11], NSFontAttributeName,
			ps, NSParagraphStyleAttributeName, nil]] autorelease];
	[o setObject:@"PumaTerm" forKey:@"ApplicationName"];
	[o setObject:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
	      forKey:@"ApplicationVersion"];	/* one version, in Info.plist */
	[o setObject:@"" forKey:@"Version"];
	[o setObject:@"Jordan Bettcher" forKey:@"Copyright"];
	[o setObject:credits forKey:@"Credits"];
	if (icon)
		[o setObject:[[[NSImage alloc] initWithContentsOfFile:icon] autorelease]
		      forKey:@"ApplicationIcon"];
	[NSApp orderFrontStandardAboutPanelWithOptions:o];
}

/* Test hook: open About behind everything, write it to /tmp/pumaterm-about.png
 * and list the menu bar, so neither needs the desktop to check. */
- (void)dumpAbout
{
	NSWindow *w;
	NSEnumerator *e;
	NSMenuItem *i;

	[self showAbout:nil];
	e = [[NSApp windows] objectEnumerator];
	while ((w = [e nextObject]) != nil) {
		if ([[w title] length] == 0 && [w isVisible] && [w frame].size.width < 500) {
			NSView *v = [[w contentView] superview];
			NSBitmapImageRep *rep;
			[w orderBack:nil];
			[v display];
			rep = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
			[v cacheDisplayInRect:[v bounds] toBitmapImageRep:rep];
			[[rep representationUsingType:NSPNGFileType properties:nil]
				writeToFile:@"/tmp/pumaterm-about.png" atomically:NO];
		}
	}
	e = [[[NSApp mainMenu] itemArray] objectEnumerator];
	printf("menu bar:");
	while ((i = [e nextObject]) != nil)
		printf(" [%s]", [[i title] UTF8String]);
	printf("\n");
	fflush(stdout);
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
	NSMenu *services = [[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
	NSMenu *shell = [[[NSMenu alloc] initWithTitle:@"Shell"] autorelease];
	NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
	NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
	NSMenuItem *i;

	[app addItemWithTitle:@"About PumaTerm" action:@selector(showAbout:) keyEquivalent:@""];
	[app addItem:[NSMenuItem separatorItem]];
	[app addItemWithTitle:[NSString stringWithFormat:@"Preferences%C", (unichar)0x2026] action:@selector(showPreferences:) keyEquivalent:@","];
	[app addItem:[NSMenuItem separatorItem]];
	i = [app addItemWithTitle:@"Services" action:NULL keyEquivalent:@""];
	[app setSubmenu:services forItem:i];
	[app addItem:[NSMenuItem separatorItem]];
	[app addItemWithTitle:@"Hide PumaTerm" action:@selector(hide:) keyEquivalent:@"h"];
	i = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	[i setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
	[app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
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

	/* Without a nib nothing tells AppKit that the first menu is the
	 * application menu, so 10.5 added one of its own beside it and the bar
	 * read "PumaTerm PumaTerm". -setAppleMenu: is what the nib loader
	 * calls; it is still in AppKit on 10.5, only gone from the headers. */
	if ([NSApp respondsToSelector:@selector(setAppleMenu:)])
		[NSApp performSelector:@selector(setAppleMenu:) withObject:app];
	[NSApp setServicesMenu:services];
	[NSApp setWindowsMenu:win];
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
	[app setDelegate:delegate];
	[app run];
	[delegate release];
	[pool release];
	return 0;
}
