/*
 * TermWindow.m -- one window: a strip of tabs over the selected TermView.
 *
 * 10.5 has no window tabs, and NSTabView keeps every page in the window,
 * which for NSOpenGLViews means a GL surface per hidden tab. So only the
 * selected terminal is in the view hierarchy; the others stay alive (their
 * shells and libvterm state keep running) and are swapped in on selection.
 * The tab strip appears with the second tab, and the window grows by its
 * height so the terminal keeps its rows.
 */
#import "TermWindow.h"
#import "TermView.h"
#import "Prefs.h"
#include <stdio.h>
#include <stdlib.h>

/*
 * Blurring what is behind a translucent window: CoreGraphics' private
 * window filters, which 10.5 exports (measured with nm on 10.5.8:
 * CGSNewCIFilterByName, CGSAddWindowFilter, CGSSetCIFilterValuesFromDictionary)
 * and which iTerm used on 10.5 before 10.6 gave it a background blur radius.
 * Flags 0x3001 apply the filter to the backdrop rather than the window.
 */
typedef int CGSConnectionID;
typedef void *CGSWindowFilterRef;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSNewCIFilterByName(CGSConnectionID, CFStringRef, CGSWindowFilterRef *);
extern CGError CGSAddWindowFilter(CGSConnectionID, int, CGSWindowFilterRef, int);
extern CGError CGSRemoveWindowFilter(CGSConnectionID, int, CGSWindowFilterRef);
extern CGError CGSSetCIFilterValuesFromDictionary(CGSConnectionID, CGSWindowFilterRef, CFDictionaryRef);
extern CGError CGSReleaseCIFilter(CGSConnectionID, CGSWindowFilterRef);

#define BAR_H		22

NSString *const TermWindowClosedNotification = @"TermWindowClosed";

/* ---- the tab strip ----------------------------------------------------- */

@interface TabBar : NSView {
	TermWindow	*owner;			/* not retained: it owns us */
}
- (id)initWithFrame:(NSRect)f owner:(TermWindow *)o;
@end

@implementation TabBar

- (id)initWithFrame:(NSRect)f owner:(TermWindow *)o
{
	if ((self = [super initWithFrame:f]) != nil)
		owner = o;
	return self;
}

- (BOOL)isFlipped	{ return YES; }

- (void)drawRect:(NSRect)dirty
{
	NSArray *v = [owner views];
	int i, n = [v count], act = [owner activeIndex];
	NSRect b = [self bounds];
	float w = b.size.width / (n ? n : 1);
	NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
	NSDictionary *on, *off;

	(void)dirty;
	[ps setAlignment:NSCenterTextAlignment];
	[ps setLineBreakMode:NSLineBreakByTruncatingTail];
	on = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont boldSystemFontOfSize:11], NSFontAttributeName,
		[NSColor colorWithCalibratedWhite:0.92f alpha:1], NSForegroundColorAttributeName,
		ps, NSParagraphStyleAttributeName, nil];
	off = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont systemFontOfSize:11], NSFontAttributeName,
		[NSColor colorWithCalibratedWhite:0.62f alpha:1], NSForegroundColorAttributeName,
		ps, NSParagraphStyleAttributeName, nil];

	/* Colours from the terminal's own background (#121214) upward, so the
	 * selected tab reads as part of the page beneath it. */
	[[NSColor colorWithCalibratedRed:0.16f green:0.16f blue:0.18f alpha:1] set];
	NSRectFill(b);
	for (i = 0; i < n; i++) {
		NSRect t = NSMakeRect(floorf(i * w), 0, floorf((i + 1) * w) - floorf(i * w), b.size.height);
		NSString *label = [NSString stringWithFormat:@"%@", [[v objectAtIndex:i] title]];

		if (i == act) {
			[[NSColor colorWithCalibratedRed:0.07f green:0.07f blue:0.08f alpha:1] set];
			NSRectFill(t);
		}
		if (i > 0) {
			[[NSColor colorWithCalibratedWhite:0.30f alpha:1] set];
			NSRectFill(NSMakeRect(t.origin.x, 4, 1, b.size.height - 8));
		}
		[label drawInRect:NSInsetRect(t, 8, 4) withAttributes:i == act ? on : off];
	}
}

- (void)mouseDown:(NSEvent *)e
{
	NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
	int n = [[owner views] count];

	if (n > 0)
		[owner selectTabAtIndex:(int)(p.x / ([self bounds].size.width / n))];
}

@end

/* ---- the window -------------------------------------------------------- */

@interface TermWindow ()
- (void)layout;
- (void)applyWindowPrefs;
- (void)prefsChanged:(NSNotification *)n;
- (void)shellExited:(NSNotification *)n;
- (void)titleChanged:(NSNotification *)n;
@end

@implementation TermWindow

- (id)initWithCascadeFrom:(NSPoint *)cascade
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	int ncols = [u integerForKey:kPrefColumns], nrows = [u integerForKey:kPrefRows];
	TermView *probe;
	NSRect frame;

	if ((self = [super init]) == nil)
		return nil;
	fontName = [prefs_font(&fontSize) retain];
	views = [[NSMutableArray alloc] init];
	if (ncols < 20) ncols = 20;
	if (nrows < 5) nrows = 5;

	/* Size the window to whole cells. */
	probe = [[TermView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) fontName:fontName size:fontSize];
	cell = [probe cellSize];
	[probe shutdown];
	[probe release];
	frame = NSMakeRect(0, 0, cell.width * ncols, cell.height * nrows);

	window = [[NSWindow alloc] initWithContentRect:frame
		styleMask:NSTitledWindowMask | NSClosableWindowMask |
			  NSMiniaturizableWindowMask | NSResizableWindowMask
		backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[window setContentResizeIncrements:cell];
	[window setDelegate:self];
	container = [[NSView alloc] initWithFrame:frame];
	[container setAutoresizesSubviews:NO];
	[window setContentView:container];
	bar = [[TabBar alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, BAR_H) owner:self];

	/* The first window is centred; each later one steps down and right
	 * from the one before. A zero point leaves a window where it is. */
	if (NSEqualPoints(*cascade, NSZeroPoint))
		[window center];
	*cascade = [window cascadeTopLeftFromPoint:*cascade];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(layout)
		name:NSViewFrameDidChangeNotification object:container];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(prefsChanged:)
		name:PrefsChangedNotification object:nil];
	[self applyWindowPrefs];
	[self newTab:nil];
	{
		/* Test hook: PUMATERM_TEST_TABS=n opens n tabs and, a few seconds
		 * on, writes the strip to /tmp/pumaterm-tabs.png. */
		const char *nt = test_env("PUMATERM_TEST_TABS");
		int i;
		for (i = 1; nt && i < atoi(nt); i++)
			[self newTab:nil];
		if (nt)
			[self performSelector:@selector(dumpBar) withObject:nil afterDelay:5.0];
		/* PUMATERM_TEST_CLOSE=1: close the selected tab three seconds in,
		 * then report what the window holds. */
		if (test_env("PUMATERM_TEST_CLOSE"))
			[self performSelector:@selector(testClose) withObject:nil afterDelay:3.0];
	}
	return self;
}

- (void)dumpBar
{
	NSBitmapImageRep *rep = [bar bitmapImageRepForCachingDisplayInRect:[bar bounds]];

	[bar cacheDisplayInRect:[bar bounds] toBitmapImageRep:rep];
	[[rep representationUsingType:NSPNGFileType properties:nil]
		writeToFile:@"/tmp/pumaterm-tabs.png" atomically:NO];
}

- (void)testClose
{
	printf("close: %d tabs, selected %d\n", (int)[views count], active);
	[self closeTab:nil];
	printf("after: %d tabs, selected %d, in window %d, strip shown %d\n",
	       (int)[views count], active,
	       [views count] ? [[views objectAtIndex:active] superview] == container : -1,
	       [bar superview] != nil);
	fflush(stdout);
}

- (NSWindow *)window	{ return window; }

/* Opacity and blur belong to the window: a translucent terminal needs a
 * non-opaque window with a clear background behind its GL surface. */
- (void)applyWindowPrefs
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	BOOL clear = [u floatForKey:kPrefOpacity] < 1;
	BOOL blur = clear && [u boolForKey:kPrefBlur];
	CGSConnectionID cid = _CGSDefaultConnection();

	[window setOpaque:!clear];
	[window setBackgroundColor:clear ? [NSColor clearColor] : [NSColor blackColor]];
	if (blurFilter && !blur) {
		CGSRemoveWindowFilter(cid, (int)[window windowNumber], blurFilter);
		CGSReleaseCIFilter(cid, blurFilter);
		blurFilter = NULL;
	}
	if (blur) {
		NSDictionary *d = [NSDictionary dictionaryWithObject:
			[NSNumber numberWithFloat:[u floatForKey:kPrefBlurRadius]] forKey:@"inputRadius"];
		CGError e1 = 0, e2 = 0, e3 = 0;

		if (blurFilter == NULL) {
			e1 = CGSNewCIFilterByName(cid, CFSTR("CIGaussianBlur"), &blurFilter);
			if (e1 == 0)
				e2 = CGSAddWindowFilter(cid, (int)[window windowNumber], blurFilter, 0x3001);
		}
		if (blurFilter)
			e3 = CGSSetCIFilterValuesFromDictionary(cid, blurFilter, (CFDictionaryRef)d);
		if (e1 || e2 || e3 || test_env("PUMATERM_TEST_BLUR"))
			NSLog(@"pumaterm: blur: connection %d window %d filter %p: new %d, add %d, values %d",
			      cid, (int)[window windowNumber], blurFilter, e1, e2, e3);
	}
	[window invalidateShadow];
}

/* Every tab re-reads the settings. If the font changed the cell size,
 * the window is resized to keep the selected terminal's rows and columns,
 * and resizing snaps to the new cell. */
- (void)prefsChanged:(NSNotification *)n
{
	TermView *v;
	int c, r;
	NSSize nc;
	NSEnumerator *e = [views objectEnumerator];

	(void)n;
	if ([views count] == 0)
		return;
	v = [views objectAtIndex:active];
	c = [v columns];
	r = [v rows];
	while ((v = [e nextObject]) != nil)
		[v applyPrefs];
	[self applyWindowPrefs];
	[fontName release];
	fontName = [prefs_font(&fontSize) retain];
	nc = [[views objectAtIndex:active] cellSize];
	if (!NSEqualSizes(nc, cell)) {
		NSRect f = [window frame];
		NSRect content = [window contentRectForFrameRect:f];
		float h = r * nc.height + ([views count] > 1 ? BAR_H : 0);

		cell = nc;
		[window setContentResizeIncrements:cell];
		content.origin.y += content.size.height - h;	/* keep the top */
		content.size = NSMakeSize(c * nc.width, h);
		[window setFrame:[window frameRectForContentRect:content] display:YES];
	}
}
- (NSArray *)views	{ return views; }
- (int)activeIndex	{ return active; }

/* The strip across the top when there is more than one tab, and the
 * selected terminal in the rest. */
- (void)layout
{
	NSRect b = [container bounds];
	BOOL tabs = [views count] > 1;

	if (tabs) {
		[bar setFrame:NSMakeRect(0, b.size.height - BAR_H, b.size.width, BAR_H)];
		if ([bar superview] == nil)
			[container addSubview:bar];
		b.size.height -= BAR_H;
	} else if ([bar superview] != nil)
		[bar removeFromSuperview];
	if (active >= 0 && active < (int)[views count])
		[[views objectAtIndex:active] setFrame:b];
	[bar setNeedsDisplay:YES];
}

/* Grow or shrink the window by the strip's height as it comes and goes,
 * keeping the top edge where it is. */
- (void)fitBar:(BOOL)show
{
	NSRect f = [window frame];
	float d = show ? BAR_H : -BAR_H;

	f.origin.y -= d;
	f.size.height += d;
	[window setFrame:f display:YES];
}

- (void)selectTabAtIndex:(int)i
{
	TermView *v;

	if (i < 0 || i >= (int)[views count])
		return;
	if (i < (int)[views count] && active < (int)[views count] && i != active)
		[[views objectAtIndex:active] removeFromSuperview];
	active = i;
	v = [views objectAtIndex:i];
	if ([v superview] == nil)
		[container addSubview:v];
	[self layout];
	[window makeFirstResponder:v];
	[window setTitle:[v title]];
	[v setNeedsDisplay:YES];
}

- (void)newTab:(id)sender
{
	TermView *v = [[TermView alloc] initWithFrame:[container bounds]
					     fontName:fontName size:fontSize];

	(void)sender;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(shellExited:)
		name:TermShellExitedNotification object:v];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(titleChanged:)
		name:TermTitleChangedNotification object:v];
	if ([views count] == 1)
		[self fitBar:YES];
	if ([views count])
		[[views objectAtIndex:active] removeFromSuperview];
	[views addObject:v];
	[v release];
	[self selectTabAtIndex:[views count] - 1];
	[v startShell];
}

- (void)removeView:(TermView *)v
{
	int i = [views indexOfObject:v];

	/* Closing the last tab closes the window, and the app then lets go of
	 * this controller: last until the method returns. */
	[[self retain] autorelease];
	if (i == (int)NSNotFound)
		return;
	[[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:v];
	[v shutdown];
	[v removeFromSuperview];
	[views removeObjectAtIndex:i];		/* releases it: SIGHUP to its shell */
	if ([views count] == 0) {
		[window close];
		return;
	}
	/* Fix the selection before anything resizes: shrinking the window
	 * for the strip runs -layout, which indexes views by it. Doing it the
	 * other way round, closing the selected last tab of two indexed past
	 * the end, the exception abandoned the close, and the window was
	 * left with no terminal in it (reported by the user: "I just had a
	 * title bar"). */
	if (active > i || active >= (int)[views count])
		active--;
	if (active < 0)
		active = 0;
	if ([views count] == 1)
		[self fitBar:NO];
	[self selectTabAtIndex:active];
}

- (void)closeTab:(id)sender
{
	(void)sender;
	if ([views count])
		[self removeView:[views objectAtIndex:active]];
}

- (void)selectNextTab:(id)sender
{
	(void)sender;
	[self selectTabAtIndex:(active + 1) % [views count]];
}

- (void)selectPreviousTab:(id)sender
{
	(void)sender;
	[self selectTabAtIndex:(active + [views count] - 1) % [views count]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	SEL a = [item action];

	if (a == @selector(selectNextTab:) || a == @selector(selectPreviousTab:))
		return [views count] > 1;
	return YES;
}

- (void)shellExited:(NSNotification *)n
{
	[self removeView:[n object]];
}

- (void)titleChanged:(NSNotification *)n
{
	if ([views count] && [n object] == [views objectAtIndex:active])
		[window setTitle:[[n object] title]];
	[bar setNeedsDisplay:YES];
}

- (void)windowWillClose:(NSNotification *)n
{
	CGSConnectionID cid = _CGSDefaultConnection();

	(void)n;
	[views makeObjectsPerformSelector:@selector(shutdown)];
	if (blurFilter) {
		CGSRemoveWindowFilter(cid, (int)[window windowNumber], blurFilter);
		CGSReleaseCIFilter(cid, blurFilter);
		blurFilter = NULL;
	}
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[NSNotificationCenter defaultCenter]
		postNotificationName:TermWindowClosedNotification object:self];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[window setDelegate:nil];
	[views release];			/* each view hangs up its shell */
	[bar release];
	[container release];
	[window release];
	[fontName release];
	[super dealloc];
}

@end
