/* TermWindow.h -- one window: a strip of tabs over the selected TermView. */
#import <Cocoa/Cocoa.h>

@class TermView;
@class TabBar;

/* Posted with the controller as object when its window has closed. */
extern NSString *const TermWindowClosedNotification;

/* The window's delegate, so it sits in the responder chain behind the
 * terminal and the menu's tab actions reach it. Ivars are here because
 * 32-bit 10.5 is the legacy Objective-C runtime. */
@interface TermWindow : NSObject {
	NSWindow	*window;
	NSView		*container;
	TabBar		*bar;
	NSMutableArray	*views;
	int		 active;
	NSString	*fontName;
	float		 fontSize;
	NSSize		 cell;
	void		*blurFilter;		/* CGSWindowFilterRef */
}
/* Font, size and colours come from the preferences. */
- (id)initWithCascadeFrom:(NSPoint *)cascade;
- (NSWindow *)window;
- (NSArray *)views;
- (int)activeIndex;
- (void)selectTabAtIndex:(int)i;
- (void)newTab:(id)sender;
- (void)closeTab:(id)sender;
- (void)selectNextTab:(id)sender;
- (void)selectPreviousTab:(id)sender;
@end
