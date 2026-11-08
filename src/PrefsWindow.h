/* PrefsWindow.h -- the Preferences window. */
#import <Cocoa/Cocoa.h>

/* Built in code like the rest of the app. Every control writes its
 * setting at once and open windows follow, as in Terminal.app. Ivars are
 * here because 32-bit 10.5 is the legacy Objective-C runtime. */
@interface PrefsWindow : NSObject {
	NSWindow	*window;
	NSMatrix	*shellMode;
	NSTextField	*shellCommand, *columns, *rowsField, *scrollback;
	NSPopUpButton	*bell, *cursorShape, *scheme;
	NSButton	*optionMeta, *cursorBlink, *blur;
	NSTextField	*fontLabel, *opacityLabel;
	NSSlider	*opacity, *blurRadius;
	NSColorWell	*fg, *bg, *cursorColor, *selection, *ansi[16];
}
+ (PrefsWindow *)shared;
- (void)show;
- (void)showForTest;
@end
