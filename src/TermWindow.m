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
#include <stdlib.h>

#define DEFAULT_COLS	100
#define DEFAULT_ROWS	32
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
- (void)shellExited:(NSNotification *)n;
- (void)titleChanged:(NSNotification *)n;
@end

@implementation TermWindow

- (id)initWithFont:(NSString *)font size:(float)size cascadeFrom:(NSPoint *)cascade
{
	TermView *probe;
	NSRect frame;

	if ((self = [super init]) == nil)
		return nil;
	fontName = [font retain];
	fontSize = size;
	views = [[NSMutableArray alloc] init];

	/* Size the window to whole cells. */
	probe = [[TermView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) fontName:font size:size];
	cell = [probe cellSize];
	[probe release];
	frame = NSMakeRect(0, 0, cell.width * DEFAULT_COLS, cell.height * DEFAULT_ROWS);

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
	[self newTab:nil];
	{
		/* Test hook: PUMATERM_TEST_TABS=n opens n tabs and, a few seconds
		 * on, writes the strip to /tmp/pumaterm-tabs.png. */
		const char *nt = getenv("PUMATERM_TEST_TABS");
		int i;
		for (i = 1; nt && i < atoi(nt); i++)
			[self newTab:nil];
		if (nt)
			[self performSelector:@selector(dumpBar) withObject:nil afterDelay:5.0];
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

- (NSWindow *)window	{ return window; }
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
	if ([views count])
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
	[v removeFromSuperview];
	[views removeObjectAtIndex:i];		/* releases it: SIGHUP to its shell */
	if ([views count] == 0) {
		[window close];
		return;
	}
	if ([views count] == 1)
		[self fitBar:NO];
	if (active > i || active >= (int)[views count])
		active--;
	if (active < 0)
		active = 0;
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
	(void)n;
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
