/* TermView.h -- one terminal: libvterm state drawn through GL 2.1. */
#import <Cocoa/Cocoa.h>
#include <OpenGL/gl.h>
#include "vterm.h"
#include "GlyphAtlas.h"

/* Posted with the view as object: its shell exited (the view's window
 * controller closes the tab), or the program set a new title. */
extern NSString *const TermShellExitedNotification;
extern NSString *const TermTitleChangedNotification;

typedef struct {
	int		cols;
	VTermScreenCell *cells;
} SBLine;

/* The instance variables live here and not in a class extension: 32-bit
 * PowerPC on 10.5 is the legacy Objective-C runtime, which has no
 * extension ivars. */
@interface TermView : NSOpenGLView {
	VTerm		*vt;
	VTermScreen	*screen;
	GlyphAtlas	*atlas;
	NSString	*fontName;
	NSString	*title;			/* as the program set it (OSC 0/2) */
	float		 fontSize;
	int		 rows, cols, cellW, cellH;
	int		 masterFd;
	pid_t		 child;
	NSFileHandle	*ptyHandle;
	VTermPos	 cursor;
	BOOL		 cursorVisible;
	int		 mouseMode;

	SBLine		*sb;			/* ring of SCROLLBACK lines */
	int		 sbHead, sbCount;	/* newest at sbHead - 1 */
	int		 scrollOffset;		/* lines scrolled back from live */

	/* Selection, in lines counted from the top of the live screen
	 * (negative = scrollback, -1 the newest history line), so it stays on
	 * its text as the view scrolls; pushLine/popLine move it with the
	 * text. anchor is what the click covered (a cell, word or line),
	 * sel the whole range, both inclusive. */
	VTermPos	 anchorA, anchorB, selA, selB;
	BOOL		 selActive;
	int		 selUnit;		/* 1 cell, 2 word, 3 line */

	GLuint		 prog;
	GLint		 aPos, aUV, aFG, aBG, uTex, uProj;
	float		*verts;			/* x y u v per vertex */
	GLubyte		*fgc, *bgc;		/* rgba per vertex */
	int		 vertCap;

	/* From the preferences (applyPrefs). */
	int		 sbSize;
	float		 bgAlpha;		/* default background opacity */
	unsigned char	 cursorRGB[3], selRGB[3];
	int		 cursorShape, bellMode;
	BOOL		 cursorBlink, blinkOn, optionMeta, flashing;
	NSTimer		*blinkTimer, *dumpTimer;
}
- (id)initWithFrame:(NSRect)frame fontName:(NSString *)font size:(float)size;
- (NSSize)cellSize;
- (void)startShell;
- (NSString *)title;
- (int)columns;
- (int)rows;
- (void)applyPrefs;		/* re-read settings; may change cellSize */
- (void)ringBell;
- (void)shutdown;		/* stop timers, hang up: before release */
- (NSString *)selectionText;
- (void)copy:(id)sender;
@end
