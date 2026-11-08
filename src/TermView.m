/*
 * TermView.m -- a terminal drawn with OpenGL 2.1 / GLSL 1.20.
 *
 * Leopard's OpenGL.framework stops at 2.1 whatever the driver underneath can
 * do (no core profile, no 3.x entry points), and 2.1 is all a GPU terminal
 * needs: every frame is one vertex array with a quad per cell, each carrying
 * the glyph's atlas coordinates and its foreground and background colours,
 * and one fragment shader mixes the two by the glyph's coverage. A frame is
 * a single draw call however much of the screen changed.
 *
 * Terminal state is libvterm's (MIT): it parses the byte stream, keeps the
 * screen, encodes keys and mouse reports, and tells us what changed; lines
 * scrolled off the top come out through sb_pushline into our ring.
 */
#import "TermView.h"

#include <OpenGL/gl.h>
#include <ApplicationServices/ApplicationServices.h>
#include <ctype.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

#include "vterm.h"
#include "GlyphAtlas.h"
#include "Pty.h"

#define SCROLLBACK	10000

/* Test hook: SIGUSR1 asks the next frame to be written to /tmp/term-frame.png,
 * so rendering can be checked over ssh without disturbing the desktop. */
static int pos_cmp(VTermPos a, VTermPos b)
{
	return a.row != b.row ? a.row - b.row : a.col - b.col;
}

static volatile sig_atomic_t dump_requested;
static void on_usr1(int sig) { (void)sig; dump_requested = 1; }

static void dump_frame(int w, int h)
{
	size_t stride = (size_t)w * 4;
	unsigned char *px = malloc(stride * h), *flip = malloc(stride * h);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef bc;
	CGImageRef img;
	CFURLRef url;
	CGImageDestinationRef dst;
	int y;

	glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
	for (y = 0; y < h; y++)		/* GL rows are bottom-up */
		memcpy(flip + (size_t)y * stride, px + (size_t)(h - 1 - y) * stride, stride);
	bc = CGBitmapContextCreate(flip, w, h, 8, stride, cs, kCGImageAlphaNoneSkipLast);
	img = CGBitmapContextCreateImage(bc);
	url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/term-frame.png"), kCFURLPOSIXPathStyle, false);
	dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	if (dst) {
		CGImageDestinationAddImage(dst, img, NULL);
		CGImageDestinationFinalize(dst);
		CFRelease(dst);
	}
	CFRelease(url);
	CGImageRelease(img);
	CGContextRelease(bc);
	CGColorSpaceRelease(cs);
	free(px);
	free(flip);
}


@interface TermView ()
- (void)ptyData:(NSNotification *)n;
- (void)outputBytes:(const char *)s length:(size_t)len;
- (int)pushLine:(const VTermScreenCell *)cells cols:(int)n;
- (int)popLine:(VTermScreenCell *)cells cols:(int)n;
- (void)setTitle:(NSString *)t;
- (int)cellAtRow:(int)r col:(int)c into:(VTermScreenCell *)cellOut;
- (void)pollDump:(NSTimer *)t;
- (void)shiftSelection:(int)d;
- (VTermPos)lineAt:(NSEvent *)e;
- (BOOL)isSelectedLine:(int)line col:(int)c;
- (BOOL)mouseIsReported:(NSEvent *)e;
- (void)expand:(VTermPos)p unit:(int)unit from:(VTermPos *)a to:(VTermPos *)b;
- (void)typeStartup:(NSString *)s;
@end

/* ---- libvterm callbacks ---------------------------------------------- */

static int cb_damage(VTermRect r, void *user)
{
	(void)r;
	[(TermView *)user setNeedsDisplay:YES];
	return 1;
}

static int cb_movecursor(VTermPos pos, VTermPos old, int visible, void *user)
{
	TermView *v = user;
	(void)old;
	(void)visible;
	[v setValue:[NSValue valueWithBytes:&pos objCType:@encode(VTermPos)] forKey:@"cursorPos"];
	[v setNeedsDisplay:YES];
	return 1;
}

static int cb_settermprop(VTermProp prop, VTermValue *val, void *user)
{
	TermView *v = user;

	switch (prop) {
	case VTERM_PROP_CURSORVISIBLE:
		[v setValue:[NSNumber numberWithBool:val->boolean] forKey:@"cursorShown"];
		break;
	case VTERM_PROP_MOUSE:
		[v setValue:[NSNumber numberWithInt:val->number] forKey:@"mouseReporting"];
		break;
	case VTERM_PROP_TITLE:
		if (val->string.initial && val->string.str) {
			NSString *t = [[[NSString alloc] initWithBytes:val->string.str
				length:val->string.len encoding:NSUTF8StringEncoding] autorelease];
			if (t)
				[v setTitle:t];
		}
		break;
	default:
		break;
	}
	return 1;
}

static int cb_bell(void *user)
{
	(void)user;
	NSBeep();
	return 1;
}

static int cb_sb_pushline(int n, const VTermScreenCell *cells, void *user)
{
	return [(TermView *)user pushLine:cells cols:n];
}

static int cb_sb_popline(int n, VTermScreenCell *cells, void *user)
{
	return [(TermView *)user popLine:cells cols:n];
}

static void cb_output(const char *s, size_t len, void *user)
{
	[(TermView *)user outputBytes:s length:len];
}

static VTermScreenCallbacks screen_cbs = {
	.damage = cb_damage,
	.movecursor = cb_movecursor,
	.settermprop = cb_settermprop,
	.bell = cb_bell,
	.sb_pushline = cb_sb_pushline,
	.sb_popline = cb_sb_popline,
};

/* ---- shaders --------------------------------------------------------- */

static const char *vsrc =
	"#version 120\n"
	"attribute vec2 pos; attribute vec2 uv; attribute vec4 fg; attribute vec4 bg;\n"
	"uniform mat4 proj;\n"
	"varying vec2 vuv; varying vec4 vfg; varying vec4 vbg;\n"
	"void main() { vuv = uv; vfg = fg; vbg = bg; gl_Position = proj * vec4(pos, 0.0, 1.0); }\n";

static const char *fsrc =
	"#version 120\n"
	"uniform sampler2D tex;\n"
	"varying vec2 vuv; varying vec4 vfg; varying vec4 vbg;\n"
	"void main() { float a = texture2D(tex, vuv).a; gl_FragColor = mix(vbg, vfg, a); }\n";

static GLuint compile(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok = 0;
	char log[1024];

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		glGetShaderInfoLog(s, sizeof log, NULL, log);
		NSLog(@"term: shader: %s", log);
	}
	return s;
}

@implementation TermView

- (id)initWithFrame:(NSRect)frame fontName:(NSString *)font size:(float)size
{
	NSOpenGLPixelFormatAttribute attrs[] = {
		NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated,
		NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0
	};
	NSOpenGLPixelFormat *pf = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];

	if (pf == nil) {		/* no accelerated renderer: take any */
		NSOpenGLPixelFormatAttribute any[] = { NSOpenGLPFADoubleBuffer, 0 };
		pf = [[[NSOpenGLPixelFormat alloc] initWithAttributes:any] autorelease];
	}
	if ((self = [super initWithFrame:frame pixelFormat:pf]) == nil)
		return nil;

	fontName = [font retain];
	fontSize = size;
	atlas = atlas_create([font UTF8String], size);
	atlas_metrics(atlas, &cellW, &cellH);
	cols = (int)(frame.size.width / cellW);
	rows = (int)(frame.size.height / cellH);
	if (cols < 2) cols = 2;
	if (rows < 2) rows = 2;
	cursorVisible = YES;
	masterFd = -1;

	vt = vterm_new(rows, cols);
	vterm_set_utf8(vt, 1);
	vterm_output_set_callback(vt, cb_output, self);
	screen = vterm_obtain_screen(vt);
	vterm_screen_set_callbacks(screen, &screen_cbs, self);
	vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCROLL);
	vterm_screen_enable_altscreen(screen, 1);
	{
		VTermColor fg, bg;
		vterm_color_rgb(&fg, 0xD8, 0xD8, 0xD8);
		vterm_color_rgb(&bg, 0x12, 0x12, 0x14);
		vterm_state_set_default_colors(vterm_obtain_state(vt), &fg, &bg);
	}
	vterm_screen_reset(screen, 1);

	sb = calloc(SCROLLBACK, sizeof *sb);
	return self;
}

- (NSSize)cellSize
{
	return NSMakeSize(cellW, cellH);
}

- (BOOL)acceptsFirstResponder	{ return YES; }
- (BOOL)isOpaque		{ return YES; }

/* KVC targets for the C callbacks. */
- (void)setCursorPos:(NSValue *)v	{ [v getValue:&cursor]; }
- (void)setCursorShown:(NSNumber *)n	{ cursorVisible = [n boolValue]; }
- (void)setMouseReporting:(NSNumber *)n	{ mouseMode = [n intValue]; }
- (void)setTitle:(NSString *)t		{ [[self window] setTitle:t]; }

- (void)startShell
{
	masterFd = pty_spawn(rows, cols, &child);
	if (masterFd < 0) {
		NSLog(@"term: forkpty failed");
		[NSApp terminate:nil];
		return;
	}
	ptyHandle = [[NSFileHandle alloc] initWithFileDescriptor:masterFd closeOnDealloc:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ptyData:)
		name:NSFileHandleReadCompletionNotification object:ptyHandle];
	[ptyHandle readInBackgroundAndNotify];

	signal(SIGUSR1, on_usr1);
	[NSTimer scheduledTimerWithTimeInterval:0.25 target:self
		selector:@selector(pollDump:) userInfo:nil repeats:YES];
	{
		/* Test hook: TERM_STARTUP_INPUT is typed into the shell once it is up. */
		const char *in = getenv("TERM_STARTUP_INPUT");
		if (in && *in)
			[self performSelector:@selector(typeStartup:)
				   withObject:[NSString stringWithUTF8String:in] afterDelay:1.5];
	}
}

- (void)pollDump:(NSTimer *)t
{
	(void)t;
	if (dump_requested) {
		/* Test hook: TERM_TEST_SELECT="line col line col unit" makes the
		 * selection a click at the first cell and a drag to the second
		 * would, and prints what Copy would take, before the frame dump. */
		const char *sel = getenv("TERM_TEST_SELECT");
		VTermPos a, b, p, q;
		static int selTested;

		if (sel && !selTested++ && sscanf(sel, "%d %d %d %d %d", &p.row, &p.col, &q.row, &q.col, &selUnit) == 5) {
			[self expand:p unit:selUnit from:&anchorA to:&anchorB];
			[self expand:q unit:selUnit from:&a to:&b];
			selA = pos_cmp(a, anchorA) < 0 ? a : anchorA;
			selB = pos_cmp(b, anchorB) > 0 ? b : anchorB;
			selActive = YES;
			printf("selection: [%s]\n", [[self selectionText] UTF8String]);
			fflush(stdout);
		}
		[self setNeedsDisplay:YES];
	}
}

- (void)typeStartup:(NSString *)s
{
	NSMutableString *m = [NSMutableString stringWithString:s];
	const char *u;

	[m replaceOccurrencesOfString:@"\\n" withString:@"\r"
			      options:0 range:NSMakeRange(0, [m length])];
	u = [m UTF8String];
	[self outputBytes:u length:strlen(u)];
}

- (void)ptyData:(NSNotification *)n
{
	NSData *d = [[n userInfo] objectForKey:NSFileHandleNotificationDataItem];

	if ([d length] == 0) {			/* the shell exited */
		int status;
		waitpid(child, &status, WNOHANG);
		[[self window] close];
		return;
	}
	vterm_input_write(vt, [d bytes], [d length]);
	vterm_screen_flush_damage(screen);
	if (scrollOffset)			/* new output returns to live */
		scrollOffset = 0;
	[ptyHandle readInBackgroundAndNotify];
}

- (void)outputBytes:(const char *)s length:(size_t)len
{
	if (masterFd >= 0)
		pty_write_all(masterFd, s, len);
}

/* ---- scrollback ------------------------------------------------------ */

- (int)pushLine:(const VTermScreenCell *)cells cols:(int)n
{
	SBLine *l = &sb[sbHead];

	free(l->cells);
	l->cells = malloc(sizeof(VTermScreenCell) * n);
	memcpy(l->cells, cells, sizeof(VTermScreenCell) * n);
	l->cols = n;
	sbHead = (sbHead + 1) % SCROLLBACK;
	if (sbCount < SCROLLBACK)
		sbCount++;
	[self shiftSelection:-1];
	return 1;
}

- (int)popLine:(VTermScreenCell *)cells cols:(int)n
{
	SBLine *l;
	int i;

	if (sbCount == 0)
		return 0;
	sbHead = (sbHead + SCROLLBACK - 1) % SCROLLBACK;
	sbCount--;
	l = &sb[sbHead];
	for (i = 0; i < n; i++) {
		if (i < l->cols) {
			cells[i] = l->cells[i];
		} else {
			memset(&cells[i], 0, sizeof cells[i]);
			cells[i].width = 1;
			cells[i].fg = l->cols ? l->cells[0].fg : cells[0].fg;
			cells[i].bg = l->cols ? l->cells[0].bg : cells[0].bg;
		}
	}
	free(l->cells);
	l->cells = NULL;
	l->cols = 0;
	[self shiftSelection:1];
	return 1;
}

/* The cell at (row, col) of what is displayed: a scrollback line when
 * scrolled back, else the live screen. Returns 0 past a short line. */
- (int)cellAtRow:(int)r col:(int)c into:(VTermScreenCell *)cellOut
{
	int back = scrollOffset - r;		/* > 0: this row is history */

	if (back > 0) {
		SBLine *l = &sb[(sbHead - back + SCROLLBACK) % SCROLLBACK];
		if (c >= l->cols)
			return 0;
		*cellOut = l->cells[c];
		return 1;
	}
	{
		VTermPos p = { r - scrollOffset, c };
		return vterm_screen_get_cell(screen, p, cellOut);
	}
}

/* ---- GL -------------------------------------------------------------- */

- (void)prepareOpenGL
{
	GLuint vs, fs;
	GLint swap = 1;

	[[self openGLContext] setValues:&swap forParameter:NSOpenGLCPSwapInterval];
	vs = compile(GL_VERTEX_SHADER, vsrc);
	fs = compile(GL_FRAGMENT_SHADER, fsrc);
	prog = glCreateProgram();
	glAttachShader(prog, vs);
	glAttachShader(prog, fs);
	glLinkProgram(prog);
	aPos = glGetAttribLocation(prog, "pos");
	aUV = glGetAttribLocation(prog, "uv");
	aFG = glGetAttribLocation(prog, "fg");
	aBG = glGetAttribLocation(prog, "bg");
	uTex = glGetUniformLocation(prog, "tex");
	uProj = glGetUniformLocation(prog, "proj");
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_BLEND);
}

static void rgb_of(VTermScreen *s, VTermColor c, GLubyte *out)
{
	vterm_screen_convert_color_to_rgb(s, &c);
	out[0] = c.rgb.red;
	out[1] = c.rgb.green;
	out[2] = c.rgb.blue;
	out[3] = 255;
}

- (void)drawRect:(NSRect)dirty
{
	NSRect b = [self bounds];
	/* Per cell: its quad plus up to three line quads (double underline
	 * and strikethrough). */
	int r, c, n = 0, need = rows * cols * 4 * 4;
	int nl = 0, lineCap = rows * cols * 3 * 4, thick = cellH >= 28 ? 2 : 1;
	float *lv;
	GLubyte *lc;
	float proj[16] = { 0 };
	GLubyte defbg[4];

	(void)dirty;
	[[self openGLContext] makeCurrentContext];
	if (need > vertCap) {
		vertCap = need;
		verts = realloc(verts, sizeof(float) * 4 * need);
		fgc = realloc(fgc, 4 * need);
		bgc = realloc(bgc, 4 * need);
	}
	/* Line quads go in the top three quarters of each array, after the
	 * cells, and are packed down behind them before the draw. */
	lv = verts + (size_t)(need - lineCap) * 4;
	lc = fgc + (size_t)(need - lineCap) * 4;
	{
		VTermColor fg, bg;
		vterm_state_get_default_colors(vterm_obtain_state(vt), &fg, &bg);
		rgb_of(screen, bg, defbg);
	}

	for (r = 0; r < rows; r++) {
		for (c = 0; c < cols; c++) {
			VTermScreenCell cell;
			GLubyte fg[4], bg[4];
			float uv[4], x0, y0, x1, y1;
			int wide = 1, k, isCursor;

			if (![self cellAtRow:r col:c into:&cell]) {
				memset(&cell, 0, sizeof cell);
				cell.width = 1;
				memcpy(fg, defbg, 4);
				memcpy(bg, defbg, 4);
			} else {
				rgb_of(screen, cell.fg, fg);
				rgb_of(screen, cell.bg, bg);
				if (cell.width == 2)
					wide = 2;
			}
			if (cell.width == 0 && c > 0)	/* right half of a wide glyph */
				continue;
			if (cell.attrs.reverse) {
				GLubyte t[4];
				memcpy(t, fg, 4); memcpy(fg, bg, 4); memcpy(bg, t, 4);
			}
			isCursor = cursorVisible && scrollOffset == 0 &&
				   r == cursor.row && c == cursor.col && [[self window] isKeyWindow];
			if (isCursor != [self isSelectedLine:r - scrollOffset col:c]) {
				GLubyte t[4];
				memcpy(t, fg, 4); memcpy(fg, bg, 4); memcpy(bg, t, 4);
			}
			atlas_lookup(atlas, cell.attrs.conceal ? ' ' : cell.chars[0],
				     (cell.attrs.bold ? ATLAS_BOLD : 0) |
				     (cell.attrs.italic ? ATLAS_ITALIC : 0), wide, uv);

			x0 = c * cellW;
			x1 = x0 + wide * cellW;
			y0 = r * cellH;
			y1 = y0 + cellH;
			{
				float q[16] = { x0, y0, uv[0], uv[1],  x1, y0, uv[2], uv[1],
						x1, y1, uv[2], uv[3],  x0, y1, uv[0], uv[3] };
				memcpy(verts + n * 4, q, sizeof q);
			}
			for (k = 0; k < 4; k++) {
				memcpy(fgc + (n + k) * 4, fg, 4);
				memcpy(bgc + (n + k) * 4, bg, 4);
			}
			n += 4;

			/* Underline just below the baseline, a second one under it
			 * for SGR 21; curly (4:3) draws straight. Strikethrough at
			 * half the x-height, which is about 0.62 of the cell. */
			if (!cell.attrs.conceal) {
				float ys[3];
				int m = 0, j;
				float base = y1 - atlas_descent(atlas);

				if (cell.attrs.underline) {
					ys[m++] = base + 1;
					if (cell.attrs.underline == VTERM_UNDERLINE_DOUBLE)
						ys[m++] = base + 1 + 2 * thick;
				}
				if (cell.attrs.strike)
					ys[m++] = y0 + roundf(cellH * 0.62f);
				for (j = 0; j < m; j++) {
					float q[16] = { x0, ys[j], 0, 0,  x1, ys[j], 0, 0,
							x1, ys[j] + thick, 0, 0,  x0, ys[j] + thick, 0, 0 };
					memcpy(lv + nl * 4, q, sizeof q);
					for (k = 0; k < 4; k++)
						memcpy(lc + (nl + k) * 4, fg, 4);
					nl += 4;
				}
			}
		}
	}

	/* A quad whose two colours are equal draws that colour whatever the
	 * atlas holds, so the lines need no texture of their own. */
	memmove(verts + n * 4, lv, sizeof(float) * 4 * nl);
	memmove(fgc + n * 4, lc, 4 * nl);
	memcpy(bgc + n * 4, fgc + n * 4, 4 * nl);
	n += nl;

	glViewport(0, 0, (GLsizei)b.size.width, (GLsizei)b.size.height);
	glClearColor(defbg[0] / 255.0f, defbg[1] / 255.0f, defbg[2] / 255.0f, 1);
	glClear(GL_COLOR_BUFFER_BIT);

	/* Pixels, y down: (0,0) is the top left of the view. */
	proj[0] = 2.0f / b.size.width;
	proj[5] = -2.0f / b.size.height;
	proj[10] = -1;
	proj[12] = -1;
	proj[13] = 1;
	proj[15] = 1;

	glUseProgram(prog);
	glUniformMatrix4fv(uProj, 1, GL_FALSE, proj);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, atlas_texture(atlas));
	glUniform1i(uTex, 0);
	glEnableVertexAttribArray(aPos);
	glEnableVertexAttribArray(aUV);
	glEnableVertexAttribArray(aFG);
	glEnableVertexAttribArray(aBG);
	glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 16, verts);
	glVertexAttribPointer(aUV, 2, GL_FLOAT, GL_FALSE, 16, verts + 2);
	glVertexAttribPointer(aFG, 4, GL_UNSIGNED_BYTE, GL_TRUE, 0, fgc);
	glVertexAttribPointer(aBG, 4, GL_UNSIGNED_BYTE, GL_TRUE, 0, bgc);
	glDrawArrays(GL_QUADS, 0, n);
	glDisableVertexAttribArray(aPos);
	glDisableVertexAttribArray(aUV);
	glDisableVertexAttribArray(aFG);
	glDisableVertexAttribArray(aBG);
	glUseProgram(0);

	if (dump_requested) {
		dump_requested = 0;
		dump_frame((int)b.size.width, (int)b.size.height);
	}
	[[self openGLContext] flushBuffer];
}

- (void)reshape
{
	NSRect b = [self bounds];
	int nc = (int)(b.size.width / cellW), nr = (int)(b.size.height / cellH);

	[super reshape];
	if (nc < 2) nc = 2;
	if (nr < 2) nr = 2;
	if (nc != cols || nr != rows) {
		cols = nc;
		rows = nr;
		vterm_set_size(vt, rows, cols);
		vterm_screen_flush_damage(screen);
		if (masterFd >= 0)
			pty_resize(masterFd, rows, cols, (int)b.size.width, (int)b.size.height);
		if (scrollOffset > sbCount)
			scrollOffset = sbCount;
	}
	[self setNeedsDisplay:YES];
}

/* ---- input ----------------------------------------------------------- */

static VTermModifier mods_of(NSEvent *e)
{
	NSUInteger f = [e modifierFlags];
	int m = VTERM_MOD_NONE;

	if (f & NSShiftKeyMask)		m |= VTERM_MOD_SHIFT;
	if (f & NSControlKeyMask)	m |= VTERM_MOD_CTRL;
	if (f & NSAlternateKeyMask)	m |= VTERM_MOD_ALT;	/* Option is Meta */
	return (VTermModifier)m;
}

- (void)keyDown:(NSEvent *)e
{
	NSString *s = [e charactersIgnoringModifiers];
	VTermModifier mod = mods_of(e);
	unichar ch;
	VTermKey key = VTERM_KEY_NONE;

	if ([s length] == 0)
		return;
	ch = [s characterAtIndex:0];
	switch (ch) {
	case NSUpArrowFunctionKey:	key = VTERM_KEY_UP; break;
	case NSDownArrowFunctionKey:	key = VTERM_KEY_DOWN; break;
	case NSLeftArrowFunctionKey:	key = VTERM_KEY_LEFT; break;
	case NSRightArrowFunctionKey:	key = VTERM_KEY_RIGHT; break;
	case NSHomeFunctionKey:		key = VTERM_KEY_HOME; break;
	case NSEndFunctionKey:		key = VTERM_KEY_END; break;
	case NSPageUpFunctionKey:	key = VTERM_KEY_PAGEUP; break;
	case NSPageDownFunctionKey:	key = VTERM_KEY_PAGEDOWN; break;
	case NSInsertFunctionKey:	key = VTERM_KEY_INS; break;
	case NSDeleteFunctionKey:	key = VTERM_KEY_DEL; break;
	case '\r': case 3:		key = VTERM_KEY_ENTER; break;
	case '\t': case 25:		key = VTERM_KEY_TAB; break;
	case 127:			key = VTERM_KEY_BACKSPACE; break;
	case 27:			key = VTERM_KEY_ESCAPE; break;
	default:
		if (ch >= NSF1FunctionKey && ch <= NSF12FunctionKey)
			key = VTERM_KEY_FUNCTION(ch - NSF1FunctionKey + 1);
		break;
	}

	/* Shift-PageUp/Down scroll the view, as in Terminal.app. */
	if ((key == VTERM_KEY_PAGEUP || key == VTERM_KEY_PAGEDOWN) && (mod & VTERM_MOD_SHIFT)) {
		scrollOffset += (key == VTERM_KEY_PAGEUP ? 1 : -1) * (rows - 1);
		if (scrollOffset < 0) scrollOffset = 0;
		if (scrollOffset > sbCount) scrollOffset = sbCount;
		[self setNeedsDisplay:YES];
		return;
	}

	scrollOffset = 0;
	if (selActive) {		/* typing drops the selection */
		selActive = NO;
		[self setNeedsDisplay:YES];
	}
	if (key != VTERM_KEY_NONE) {
		vterm_keyboard_key(vt, key, mod);
	} else if (mod & (VTERM_MOD_CTRL | VTERM_MOD_ALT)) {
		vterm_keyboard_unichar(vt, ch, mod);
	} else {
		/* Plain typing: the characters as the keyboard layout made them,
		 * so dead keys and Option-letter accents work. */
		NSString *t = [e characters];
		NSUInteger i;
		for (i = 0; i < [t length]; i++)
			vterm_keyboard_unichar(vt, [t characterAtIndex:i], VTERM_MOD_NONE);
	}
	[self setNeedsDisplay:YES];
}

- (void)paste:(id)sender
{
	NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSStringPboardType];
	const char *u;

	(void)sender;
	if (s == nil)
		return;
	u = [s UTF8String];
	vterm_keyboard_start_paste(vt);
	{
		/* libvterm's paste brackets only wrap; the text goes straight out,
		 * with LF turned into CR the way a typed Return would be. */
		NSMutableData *d = [NSMutableData dataWithBytes:u length:strlen(u)];
		char *p = [d mutableBytes];
		NSUInteger i;
		for (i = 0; i < [d length]; i++)
			if (p[i] == '\n')
				p[i] = '\r';
		[self outputBytes:p length:[d length]];
	}
	vterm_keyboard_end_paste(vt);
}

- (BOOL)performKeyEquivalent:(NSEvent *)e
{
	if (([e modifierFlags] & NSCommandKeyMask) &&
	    [[e charactersIgnoringModifiers] isEqualToString:@"v"]) {
		[self paste:nil];
		return YES;
	}
	if (([e modifierFlags] & NSCommandKeyMask) &&
	    [[e charactersIgnoringModifiers] isEqualToString:@"c"]) {
		[self copy:nil];
		return YES;
	}
	return [super performKeyEquivalent:e];
}

- (void)scrollWheel:(NSEvent *)e
{
	float dy = [e deltaY];

	if (mouseMode != VTERM_PROP_MOUSE_NONE) {
		NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
		int row = (int)(([self bounds].size.height - p.y) / cellH), col = (int)(p.x / cellW);
		vterm_mouse_move(vt, row, col, mods_of(e));
		vterm_mouse_button(vt, dy > 0 ? 4 : 5, true, mods_of(e));
		return;
	}
	scrollOffset += (int)(dy > 0 ? ceilf(dy) : floorf(dy)) * 3;
	if (scrollOffset < 0) scrollOffset = 0;
	if (scrollOffset > sbCount) scrollOffset = sbCount;
	[self setNeedsDisplay:YES];
}

- (void)mouseEvent:(NSEvent *)e button:(int)button pressed:(BOOL)pressed
{
	NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
	int row = (int)(([self bounds].size.height - p.y) / cellH), col = (int)(p.x / cellW);

	if (mouseMode == VTERM_PROP_MOUSE_NONE)
		return;
	vterm_mouse_move(vt, row, col, mods_of(e));
	if (button)
		vterm_mouse_button(vt, button, pressed, mods_of(e));
}

/* The mouse belongs to the program when it asked for reports; Shift takes
 * it back for selecting, as in xterm. */
- (BOOL)mouseIsReported:(NSEvent *)e
{
	return mouseMode != VTERM_PROP_MOUSE_NONE && !([e modifierFlags] & NSShiftKeyMask);
}

- (void)mouseDown:(NSEvent *)e
{
	VTermPos p;

	if ([self mouseIsReported:e]) {
		[self mouseEvent:e button:1 pressed:YES];
		return;
	}
	p = [self lineAt:e];
	selUnit = [e clickCount] >= 3 ? 3 : [e clickCount] == 2 ? 2 : 1;
	[self expand:p unit:selUnit from:&anchorA to:&anchorB];
	selA = anchorA;
	selB = anchorB;
	/* A single click only places the anchor; dragging makes a selection. */
	selActive = selUnit > 1;
	[self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)e
{
	VTermPos p, a, b;

	if ([self mouseIsReported:e]) {
		[self mouseEvent:e button:0 pressed:NO];
		return;
	}
	p = [self lineAt:e];
	[self expand:p unit:selUnit from:&a to:&b];
	selA = pos_cmp(a, anchorA) < 0 ? a : anchorA;
	selB = pos_cmp(b, anchorB) > 0 ? b : anchorB;
	selActive = YES;
	[self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
	if ([self mouseIsReported:e])
		[self mouseEvent:e button:1 pressed:NO];
}

- (void)rightMouseDown:(NSEvent *)e	{ [self mouseEvent:e button:3 pressed:YES]; }
- (void)rightMouseUp:(NSEvent *)e	{ [self mouseEvent:e button:3 pressed:NO]; }

/* ---- selection ------------------------------------------------------- */

/* The line and column under the mouse, clamped to what exists. */
- (VTermPos)lineAt:(NSEvent *)e
{
	NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
	VTermPos q;
	int row = (int)floorf(([self bounds].size.height - p.y) / cellH);

	if (row < 0) row = 0;
	if (row >= rows) row = rows - 1;
	q.row = row - scrollOffset;
	q.col = (int)(p.x / cellW);
	if (q.col < 0) q.col = 0;
	if (q.col >= cols) q.col = cols - 1;
	return q;
}

- (void)shiftSelection:(int)d
{
	anchorA.row += d; anchorB.row += d;
	selA.row += d; selB.row += d;
	if (selActive && selB.row < -sbCount)	/* scrolled out of history */
		selActive = NO;
}

- (BOOL)isSelectedLine:(int)line col:(int)c
{
	VTermPos p = { line, c };

	return selActive && pos_cmp(p, selA) >= 0 && pos_cmp(p, selB) <= 0;
}

- (uint32_t)charAtLine:(int)line col:(int)c
{
	VTermScreenCell cell;

	if (![self cellAtRow:line + scrollOffset col:c into:&cell] || cell.chars[0] == 0)
		return ' ';
	return cell.chars[0];
}

/* What a double click takes as one word: letters and digits plus the
 * punctuation of paths, URLs and identifiers. */
static int word_char(uint32_t ch)
{
	return ch > 127 ? ch != 0xA0 : (isalnum((int)ch) || strchr("-_./~:@%+#?=&", (int)ch) != NULL);
}

- (void)expand:(VTermPos)p unit:(int)unit from:(VTermPos *)a to:(VTermPos *)b
{
	*a = *b = p;
	if (unit == 3) {
		a->col = 0;
		b->col = cols - 1;
	} else if (unit == 2 && word_char([self charAtLine:p.row col:p.col])) {
		while (a->col > 0 && word_char([self charAtLine:p.row col:a->col - 1]))
			a->col--;
		while (b->col < cols - 1 && word_char([self charAtLine:p.row col:b->col + 1]))
			b->col++;
	}
}

static void put_utf8(NSMutableData *d, uint32_t ch)
{
	unsigned char u[4];
	int n;

	if (ch < 0x80)		{ u[0] = ch; n = 1; }
	else if (ch < 0x800)	{ u[0] = 0xC0 | ch >> 6; u[1] = 0x80 | (ch & 0x3F); n = 2; }
	else if (ch < 0x10000)	{ u[0] = 0xE0 | ch >> 12; u[1] = 0x80 | ((ch >> 6) & 0x3F);
				  u[2] = 0x80 | (ch & 0x3F); n = 3; }
	else			{ u[0] = 0xF0 | ch >> 18; u[1] = 0x80 | ((ch >> 12) & 0x3F);
				  u[2] = 0x80 | ((ch >> 6) & 0x3F); u[3] = 0x80 | (ch & 0x3F); n = 4; }
	[d appendBytes:u length:n];
}

/* The selected text, one line per screen line with trailing blanks
 * dropped; a line the terminal wrapped joins its continuation without a
 * newline, so a long command copies as the command. */
- (NSString *)selectionText
{
	NSMutableData *d = [NSMutableData data];
	int line;

	if (!selActive)
		return nil;
	for (line = selA.row; line <= selB.row; line++) {
		int c0 = line == selA.row ? selA.col : 0;
		int c1 = line == selB.row ? selB.col : cols - 1;
		NSUInteger keep;
		int c, k, wrapped = 0;

		if (line >= 0 && line < rows - 1) {
			VTermLineInfo const *li = vterm_state_get_lineinfo(vterm_obtain_state(vt), line + 1);
			wrapped = li && li->continuation && line != selB.row;
		}
		keep = [d length];
		for (c = c0; c <= c1; c++) {
			VTermScreenCell cell;

			if (![self cellAtRow:line + scrollOffset col:c into:&cell] || cell.chars[0] == 0) {
				[d appendBytes:" " length:1];
				continue;
			}
			if (cell.width == 0)
				continue;
			for (k = 0; k < VTERM_MAX_CHARS_PER_CELL && cell.chars[k]; k++)
				put_utf8(d, cell.chars[k]);
			if (cell.width == 2)
				c++;
		}
		if (!wrapped) {
			/* trim the line's trailing blanks, then end it */
			const char *p = [d bytes];
			NSUInteger len = [d length];
			while (len > keep && p[len - 1] == ' ')
				len--;
			[d setLength:len];
			if (line != selB.row)
				[d appendBytes:"\n" length:1];
		}
	}
	return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
}

- (void)copy:(id)sender
{
	NSString *s = [self selectionText];
	NSPasteboard *pb = [NSPasteboard generalPasteboard];

	(void)sender;
	if ([s length] == 0) {
		NSBeep();
		return;
	}
	[pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
	[pb setString:s forType:NSStringPboardType];
}

- (void)dealloc
{
	int i;

	[[NSNotificationCenter defaultCenter] removeObserver:self];
	if (child > 0)
		kill(child, SIGHUP);
	[ptyHandle release];
	vterm_free(vt);
	atlas_destroy(atlas);
	for (i = 0; i < SCROLLBACK; i++)
		free(sb[i].cells);
	free(sb);
	free(verts);
	free(fgc);
	free(bgc);
	[fontName release];
	[super dealloc];
}

@end
