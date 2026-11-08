/* TermView.h -- one terminal: libvterm state drawn through GL 2.1. */
#import <Cocoa/Cocoa.h>
#include <OpenGL/gl.h>
#include "vterm.h"
#include "GlyphAtlas.h"

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

	GLuint		 prog;
	GLint		 aPos, aUV, aFG, aBG, uTex, uProj;
	float		*verts;			/* x y u v per vertex */
	GLubyte		*fgc, *bgc;		/* rgba per vertex */
	int		 vertCap;
}
- (id)initWithFrame:(NSRect)frame fontName:(NSString *)font size:(float)size;
- (NSSize)cellSize;
- (void)startShell;
@end
