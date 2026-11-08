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
#include <sys/select.h>
#include <signal.h>
#include <sys/time.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

#include "vterm.h"
#include "GlyphAtlas.h"
#include "Pty.h"
#import "Prefs.h"


/* Test hook: SIGUSR1 asks the next frame to be written to /tmp/pumaterm-frame.png,
 * so rendering can be checked over ssh without disturbing the desktop. */
static int pos_cmp(VTermPos a, VTermPos b)
{
	return a.row != b.row ? a.row - b.row : a.col - b.col;
}

NSString *const TermShellExitedNotification = @"TermShellExited";
NSString *const TermTitleChangedNotification = @"TermTitleChanged";

static volatile sig_atomic_t dump_requested;
static void on_usr1(int sig) { (void)sig; dump_requested = 1; }

/* The window as the window server composites it, alpha included, which is
 * what shows whether a translucent background really is. */
static void dump_window(CGWindowID wid)
{
	CGImageRef img = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
						 wid, kCGWindowImageBoundsIgnoreFraming);
	CFURLRef url;
	CGImageDestinationRef d;

	if (img == NULL)
		return;
	url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/pumaterm-window.png"),
					    kCFURLPOSIXPathStyle, false);
	d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	if (d) {
		CGImageDestinationAddImage(d, img, NULL);
		CGImageDestinationFinalize(d);
		CFRelease(d);
	}
	CFRelease(url);
	CGImageRelease(img);
}

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
	url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/pumaterm-frame.png"), kCFURLPOSIXPathStyle, false);
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

/* Input-side counters for the test dump (SIGUSR1). */
static unsigned in_notes, in_extra;
static double in_bytes, in_us;

static int cb_damage(VTermRect r, void *user)
{
	[(TermView *)user damageRows:r.start_row to:r.end_row - 1];
	return 1;
}

/*
 * libvterm reports every cursor move, which is every character printed: a
 * full-screen visualizer frame is thousands of them.  This was a KVC
 * setValue:forKey: with a fresh NSValue and two window invalidations each,
 * and held a 100x32 truecolor animation to 0.6 frames a second (measured on
 * board 1, 2026-11-08).  It is now a plain store and a widening of the
 * pending row range.
 */
static int cb_movecursor(VTermPos pos, VTermPos old, int visible, void *user)
{
	TermView *v = user;
	(void)visible;
	[v moveCursorTo:pos from:old];
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
	[(TermView *)user ringBell];
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
	"void main() {\n"
	"  float a = texture2D(tex, vuv).a;\n"
	"  float al = mix(vbg.a, vfg.a, a);\n"
	"  gl_FragColor = vec4(mix(vbg.rgb, vfg.rgb, a) * al, al);\n"
	"}\n";

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
		NSLog(@"pumaterm: shader: %s", log);
	}
	return s;
}

/*
 * The GL path: a child view that only draws, and only while the terminal
 * is opaque. Events pass through it to the TermView behind.
 */
@implementation TermGLView

- (id)initWithFrame:(NSRect)frame terminal:(TermView *)o
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
	if ((self = [super initWithFrame:frame pixelFormat:pf]) != nil)
		owner = o;
	return self;
}

- (BOOL)isOpaque			{ return YES; }
- (NSView *)hitTest:(NSPoint)p		{ (void)p; return nil; }
- (void)prepareOpenGL			{ [owner glPrepare]; }
- (void)drawRect:(NSRect)dirty		{ (void)dirty; [owner glDraw]; }

/* A tab that is not selected is out of the window, and its GL surface must
 * go with it: left attached, it stays composited over the window and the
 * selected terminal is drawn underneath it. */
- (void)viewWillMoveToWindow:(NSWindow *)w
{
	if (w == nil)
		[[self openGLContext] clearDrawable];
	[super viewWillMoveToWindow:w];
}

@end

@implementation TermView

- (id)initWithFrame:(NSRect)frame fontName:(NSString *)font size:(float)size
{
	if ((self = [super initWithFrame:frame]) == nil)
		return nil;
	glView = [[TermGLView alloc] initWithFrame:[self bounds] terminal:self];
	[glView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

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
	vterm_screen_reset(screen, 1);

	/* Scrollback is sized once, at creation: a new value applies to new
	 * tabs. */
	sbSize = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kPrefScrollback];
	if (sbSize < 100) sbSize = 100;
	if (sbSize > 200000) sbSize = 200000;
	sb = calloc(sbSize, sizeof *sb);
	blinkOn = YES;
	[self applyPrefs];
	return self;
}

- (NSSize)cellSize
{
	return NSMakeSize(cellW, cellH);
}

- (int)columns	{ return cols; }
- (int)rows	{ return rows; }

static void vcolor(VTermColor *v, const unsigned char c[3])
{
	vterm_color_rgb(v, c[0], c[1], c[2]);
}

/* Re-read the settings this view draws with. A font change rebuilds the
 * glyph atlas and changes the cell size; the window controller then
 * resizes the window to keep the rows and columns. */
- (void)applyPrefs
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	VTermState *st = vterm_obtain_state(vt);
	VTermColor fg, bg;
	unsigned char c[3];
	float size;
	NSString *font = prefs_font(&size);
	int i;

	prefs_rgb(kPrefForeground, c);
	vcolor(&fg, c);
	prefs_rgb(kPrefBackground, c);
	vcolor(&bg, c);
	vterm_state_set_default_colors(st, &fg, &bg);
	for (i = 0; i < 16; i++) {
		VTermColor p;
		prefs_palette_rgb(i, c);
		vcolor(&p, c);
		vterm_state_set_palette_color(st, i, &p);
	}
	prefs_rgb(kPrefCursorColor, cursorRGB);
	prefs_rgb(kPrefSelection, selRGB);

	bgAlpha = [u floatForKey:kPrefOpacity];
	if (bgAlpha < 0.2f) bgAlpha = 0.2f;
	if (bgAlpha > 1) bgAlpha = 1;
	/*
	 * Opaque terminals draw with GL. A translucent one cannot: RadeonNI
	 * shows a GL window's new frame by copying the surface to the screen
	 * (RadeonNIAccel::flushSurface), which no alpha survives, so a
	 * non-opaque surface looked exactly like an opaque one. Translucent
	 * terminals therefore draw the same quads on the CPU into the
	 * window's ordinary backing store, which the window server
	 * composites with alpha like any other window.
	 */
	useGL = bgAlpha >= 1 && test_env("PUMATERM_NO_GL") == NULL;
	if (useGL && [glView superview] == nil) {
		[glView setFrame:[self bounds]];
		[self addSubview:glView];
	} else if (!useGL && [glView superview] != nil)
		[glView removeFromSuperview];
	cursorShape = [u integerForKey:kPrefCursorShape];
	cursorBlink = [u boolForKey:kPrefCursorBlink];
	bellMode = [u integerForKey:kPrefBell];
	optionMeta = [u boolForKey:kPrefOptionMeta];

	[blinkTimer invalidate];
	blinkTimer = nil;
	blinkOn = YES;
	if (cursorBlink)
		blinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.53 target:self
			selector:@selector(blink:) userInfo:nil repeats:YES];

	if (![font isEqualToString:fontName] || size != fontSize) {
		[fontName release];
		fontName = [font retain];
		fontSize = size;
		[[glView openGLContext] makeCurrentContext];	/* the texture's */
		atlas_destroy(atlas);
		atlas = atlas_create([font UTF8String], size);
		atlas_metrics(atlas, &cellW, &cellH);
		[self resizeTerminal];
	}
	/* Damage everything: cells hold palette indexes and default flags,
	 * so recolouring needs no change to the screen itself. */
	[self setNeedsDisplay:YES];
}

static unsigned blink_ticks, frames_drawn, cpu_frames;
static double cpu_us, cpu_rows, cpu_build_us, cpu_raster_us;

- (void)blink:(NSTimer *)t
{
	(void)t;
	blink_ticks++;
	blinkOn = !blinkOn;
	[self damageRows:cursor.row to:cursor.row];
}

- (void)endFlash:(id)o
{
	(void)o;
	flashing = NO;
	[self setNeedsDisplay:YES];
}

- (void)ringBell
{
	if (bellMode == BellAudible)
		NSBeep();
	else if (bellMode == BellVisual && !flashing) {
		flashing = YES;
		[self setNeedsDisplay:YES];
		[self performSelector:@selector(endFlash:) withObject:nil afterDelay:0.12];
	}
}

/* Timers retain their target, so a closed tab must stop them itself or
 * it is never freed and its shell never hung up. */
- (void)shutdown
{
	[blinkTimer invalidate];
	blinkTimer = nil;
	[dumpTimer invalidate];
	dumpTimer = nil;
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	if (child > 0) {
		kill(child, SIGHUP);
		child = 0;
	}
}

- (BOOL)acceptsFirstResponder	{ return YES; }
- (BOOL)isOpaque		{ return useGL; }

/* Everything that changes the picture says setNeedsDisplay: to us; the GL
 * child, when it is the one drawing, has to hear it too. */
- (void)setNeedsDisplay:(BOOL)flag
{
	if (flag)
		dirtyAll = YES;
	[super setNeedsDisplay:flag];
	if (useGL)
		[glView setNeedsDisplay:flag];
}

/*
 * Rows of the live screen that changed. The CPU path rebuilds and redraws
 * only these, and asks the window server to take only their band; GL
 * draws everything anyway, so it is just told to draw.
 */
- (void)damageRows:(int)a to:(int)b
{
	NSRect bd = [self bounds];

	if (scrollOffset) {			/* history on screen: rows move */
		[self setNeedsDisplay:YES];
		return;
	}
	if (a < 0) a = 0;
	if (b >= rows) b = rows - 1;
	if (b < a)
		return;
	if (dirtyR1 < dirtyR0) {
		dirtyR0 = a;
		dirtyR1 = b;
	} else {
		if (a < dirtyR0) dirtyR0 = a;
		if (b > dirtyR1) dirtyR1 = b;
	}
	if (inInput) {				/* ptyData invalidates once at its end */
		invalPending = YES;
		return;
	}
	if (useGL) {
		[glView setNeedsDisplay:YES];
		return;
	}
	/* bottom-up view coordinates; the last row's band runs to the edge */
	{
		float top = bd.size.height - a * cellH;
		float bot = b == rows - 1 ? 0 : bd.size.height - (b + 1) * cellH;
		[super setNeedsDisplayInRect:NSMakeRect(0, bot, bd.size.width, top - bot)];
	}
}

/* KVC targets for the C callbacks. */
- (void)setCursorPos:(NSValue *)v	{ [v getValue:&cursor]; }

- (void)moveCursorTo:(VTermPos)pos from:(VTermPos)old
{
	cursor = pos;
	[self damageRows:(old.row < pos.row ? old.row : pos.row)
		      to:(old.row > pos.row ? old.row : pos.row)];
}

/* The one invalidation for everything damaged while input was processed. */
- (void)flushInvalidation
{
	NSRect bd = [self bounds];
	int a = dirtyR0, b = dirtyR1;

	if (!invalPending)
		return;
	invalPending = NO;
	if (b < a)
		return;
	if (useGL) {
		[glView setNeedsDisplay:YES];
		return;
	}
	{
		float top = bd.size.height - a * cellH;
		float bot = b == rows - 1 ? 0 : bd.size.height - (b + 1) * cellH;
		[super setNeedsDisplayInRect:NSMakeRect(0, bot, bd.size.width, top - bot)];
	}
}
- (void)setCursorShown:(NSNumber *)n	{ cursorVisible = [n boolValue]; }
- (void)setMouseReporting:(NSNumber *)n	{ mouseMode = [n intValue]; }
- (NSString *)title			{ return title ? title : @"PumaTerm"; }

- (void)setTitle:(NSString *)t
{
	[title release];
	title = [t copy];
	[[NSNotificationCenter defaultCenter]
		postNotificationName:TermTitleChangedNotification object:self];
}

- (void)startShell
{
	NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
	NSString *cmd = [u integerForKey:kPrefShellMode] == 1 ? [u stringForKey:kPrefShellCommand] : nil;

	masterFd = pty_spawn(rows, cols, [cmd length] ? [cmd UTF8String] : NULL, &child);
	if (masterFd < 0) {
		NSLog(@"pumaterm: forkpty failed");
		[NSApp terminate:nil];
		return;
	}
	ptyHandle = [[NSFileHandle alloc] initWithFileDescriptor:masterFd closeOnDealloc:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ptyData:)
		name:NSFileHandleReadCompletionNotification object:ptyHandle];
	[ptyHandle readInBackgroundAndNotify];

	signal(SIGUSR1, on_usr1);
	dumpTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self
		selector:@selector(pollDump:) userInfo:nil repeats:YES];
	{
		/* Test hook: PUMATERM_STARTUP_INPUT is typed into the shell once it is up. */
		const char *in = test_env("PUMATERM_STARTUP_INPUT");
		if (in && *in)
			[self performSelector:@selector(typeStartup:)
				   withObject:[NSString stringWithUTF8String:in] afterDelay:1.5];
	}
}

- (void)pollDump:(NSTimer *)t
{
	(void)t;
	if (dump_requested) {
		/* Test hook: PUMATERM_TEST_SELECT="line col line col unit" makes the
		 * selection a click at the first cell and a drag to the second
		 * would, and prints what Copy would take, before the frame dump. */
		const char *sel = test_env("PUMATERM_TEST_SELECT");
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
	NSMutableString *m;
	const char *u;
	NSRange pause = [s rangeOfString:@"\\p"];

	/* "\p" pauses two seconds: keys for a program that has to start
	 * first, and that flushes typed-ahead input as it does. */
	if (pause.location != NSNotFound) {
		[self performSelector:@selector(typeStartup:)
			   withObject:[s substringFromIndex:NSMaxRange(pause)] afterDelay:2.0];
		s = [s substringToIndex:pause.location];
	}
	m = [NSMutableString stringWithString:s];

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
		child = 0;
		/* The observer closes this tab and releases us: last until the
		 * method returns. */
		[[self retain] autorelease];
		[[NSNotificationCenter defaultCenter]
			postNotificationName:TermShellExitedNotification object:self];
		return;
	}
	if (scrollOffset) {			/* new output returns to live */
		scrollOffset = 0;
		[self setNeedsDisplay:YES];
	}
	inInput = YES;
	{
		struct timeval i0, i1;
		gettimeofday(&i0, NULL);
		vterm_input_write(vt, [d bytes], [d length]);
		gettimeofday(&i1, NULL);
		in_us += (i1.tv_sec - i0.tv_sec) * 1e6 + (i1.tv_usec - i0.tv_usec);
		in_notes++;
		in_bytes += [d length];
	}
	{
		/*
		 * A program's screen update often arrives in several reads
		 * (btop's measured as a few kilobytes at a time), and drawing
		 * between them shows the picture being laid down in bands. So
		 * whatever is already waiting is read now, before this run-loop
		 * pass draws, for up to 8 ms. No background read is pending
		 * here (it is re-armed below), so reading the fd is safe.
		 */
		static char buf[65536];
		struct timeval t0, t;
		gettimeofday(&t0, NULL);
		for (;;) {
			/* select, not poll: 10.5's poll() does not support
			 * terminal devices (POLLNVAL), so this loop never read
			 * anything and every ~500-byte pty read cost a whole
			 * run-loop pass with a draw (measured: 0 extra reads,
			 * 0.6 frames a second of a 100x32 animation). */
			fd_set rf;
			struct timeval tmo = { 0, 1000 };
			ssize_t got;
			FD_ZERO(&rf);
			FD_SET(masterFd, &rf);
			if (select(masterFd + 1, &rf, NULL, NULL, &tmo) <= 0)
				break;
			got = read(masterFd, buf, sizeof buf);
			if (got <= 0)
				break;		/* EOF: the background read reports it */
			vterm_input_write(vt, buf, (size_t)got);
			in_extra++;
			in_bytes += got;
			gettimeofday(&t, NULL);
			if ((t.tv_sec - t0.tv_sec) * 1000000 + (t.tv_usec - t0.tv_usec) > 8000)
				break;
		}
	}
	vterm_screen_flush_damage(screen);
	inInput = NO;
	[self flushInvalidation];
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
	sbHead = (sbHead + 1) % sbSize;
	if (sbCount < sbSize)
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
	sbHead = (sbHead + sbSize - 1) % sbSize;
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
		SBLine *l = &sb[(sbHead - back + sbSize) % sbSize];
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

- (void)glPrepare
{
	GLuint vs, fs;
	GLint swap = 1;

	[[glView openGLContext] setValues:&swap forParameter:NSOpenGLCPSwapInterval];
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

static void add_rect(float *lv, GLubyte *lc, int *nl, float x0, float y0,
		     float x1, float y1, const GLubyte col[4])
{
	float q[16] = { x0, y0, 0, 0,  x1, y0, 0, 0,  x1, y1, 0, 0,  x0, y1, 0, 0 };
	int k;

	memcpy(lv + *nl * 4, q, sizeof q);
	for (k = 0; k < 4; k++)
		memcpy(lc + (*nl + k) * 4, col, 4);
	*nl += 4;
}

static void rgb_of(VTermScreen *s, VTermColor c, GLubyte *out)
{
	vterm_screen_convert_color_to_rgb(s, &c);
	out[0] = c.rgb.red;
	out[1] = c.rgb.green;
	out[2] = c.rgb.blue;
	out[3] = 255;
}

/* Every cell's quad, then line and cursor quads, into verts/fgc/bgc: the
 * one description of the picture both drawing paths consume. Returns the
 * vertex count; *clear gets the default background, premultiplied. */
- (int)buildQuads:(GLubyte *)clear rows:(int)r0 to:(int)r1
{
	frames_drawn++;
	/* Per cell: its quad plus up to three line quads (double underline
	 * and strikethrough). */
	int r, c, n = 0, need = rows * cols * 4 * 4 + 32;
	int nl = 0, lineCap = rows * cols * 3 * 4 + 16, thick = cellH >= 28 ? 2 : 1;
	/* PUMATERM_TEST_FOCUS draws as the key window would, so a test copy
	 * behind the user's windows can show the focused cursor. */
	int focused = [[self window] isKeyWindow] || test_env("PUMATERM_TEST_FOCUS") != NULL;
	GLubyte bgA = (GLubyte)lroundf(bgAlpha * 255), curc[4], selc[4];
	float cx0 = 0, cy0 = 0, cx1 = 0, cy1 = 0;
	int cursorAt = 0;
	float *lv;
	GLubyte *lc;
	GLubyte defbg[4], deffg[4];

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
		rgb_of(screen, fg, deffg);
		defbg[3] = bgA;
	}
	memcpy(curc, cursorRGB, 3); curc[3] = 255;
	memcpy(selc, selRGB, 3); selc[3] = 255;

	for (r = r0; r <= r1; r++) {
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
				/* A cell in the default colours stores whatever the
				 * default was when it was written; draw today's, so a
				 * new scheme recolours what is already on screen.
				 * Only the default background is translucent: a
				 * program's coloured cells stay solid, as in iTerm. */
				if (VTERM_COLOR_IS_DEFAULT_FG(&cell.fg))
					memcpy(fg, deffg, 4);
				if (VTERM_COLOR_IS_DEFAULT_BG(&cell.bg))
					memcpy(bg, defbg, 4);
				if (cell.width == 2)
					wide = 2;
			}
			if (cell.width == 0 && c > 0)	/* right half of a wide glyph */
				continue;
			if (cell.attrs.reverse != flashing) {
				GLubyte t[4];
				memcpy(t, fg, 4); memcpy(fg, bg, 4); memcpy(bg, t, 4);
				fg[3] = bg[3] = 255;
			}
			if ([self isSelectedLine:r - scrollOffset col:c])
				memcpy(bg, selc, 4);
			isCursor = cursorVisible && scrollOffset == 0 &&
				   r == cursor.row && c == cursor.col &&
				   (blinkOn || !cursorBlink || !focused);
			if (isCursor && focused && cursorShape == CursorBlock) {
				memcpy(bg, curc, 4);
				memcpy(fg, defbg, 3);
				fg[3] = 255;
			}
			atlas_lookup(atlas, cell.attrs.conceal ? ' ' : cell.chars[0],
				     (cell.attrs.bold ? ATLAS_BOLD : 0) |
				     (cell.attrs.italic ? ATLAS_ITALIC : 0), wide, uv);

			x0 = c * cellW;
			x1 = x0 + wide * cellW;
			y0 = r * cellH;
			y1 = y0 + cellH;
			if (isCursor) {
				cursorAt = 1;
				cx0 = x0; cy0 = y0; cx1 = x1; cy1 = y1;
			}
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

	/* Cursors other than the focused block are drawn over the cell: an
	 * underline, a bar, or an outline for a window that is not key, as
	 * Terminal.app does. */
	if (cursorAt && !(focused && cursorShape == CursorBlock)) {
		float w = cellW >= 10 ? 2 : 1;
		if (cursorShape == CursorUnderline)
			add_rect(lv, lc, &nl, cx0, cy1 - 2 * w, cx1, cy1, curc);
		else if (cursorShape == CursorBar)
			add_rect(lv, lc, &nl, cx0, cy0, cx0 + w, cy1, curc);
		else {
			add_rect(lv, lc, &nl, cx0, cy0, cx1, cy0 + 1, curc);
			add_rect(lv, lc, &nl, cx0, cy1 - 1, cx1, cy1, curc);
			add_rect(lv, lc, &nl, cx0, cy0, cx0 + 1, cy1, curc);
			add_rect(lv, lc, &nl, cx1 - 1, cy0, cx1, cy1, curc);
		}
	}

	/* A quad whose two colours are equal draws that colour whatever the
	 * atlas holds, so the lines need no texture of their own. */
	memmove(verts + n * 4, lv, sizeof(float) * 4 * nl);
	memmove(fgc + n * 4, lc, 4 * nl);
	memcpy(bgc + n * 4, fgc + n * 4, 4 * nl);
	n += nl;
	memcpy(clear, defbg, 4);
	return n;
}

- (void)glDraw
{
	NSRect b = [self bounds];
	float proj[16] = { 0 };
	GLubyte clear[4];
	int n;

	[[glView openGLContext] makeCurrentContext];
	n = [self buildQuads:clear rows:0 to:rows - 1];
	dirtyAll = NO;
	dirtyR0 = 1;
	dirtyR1 = 0;
	glViewport(0, 0, (GLsizei)b.size.width, (GLsizei)b.size.height);
	glClearColor(clear[0] / 255.0f, clear[1] / 255.0f, clear[2] / 255.0f, 1);
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
		dump_window((CGWindowID)[[self window] windowNumber]);
		printf("dumped (GL): %s blink ticks %u frames %u blinkOn %d\n", [[self title] UTF8String],
		       blink_ticks, frames_drawn, blinkOn);
		fflush(stdout);
	}
	[[glView openGLContext] flushBuffer];
}

/* Premultiplied ARGB in a host-order word, as the bitmap context below
 * reads it. */
static uint32_t premul(const GLubyte c[4])
{
	unsigned a = c[3];

	return a << 24 | (c[0] * a / 255) << 16 | (c[1] * a / 255) << 8 | (c[2] * a / 255);
}

static uint32_t mix_px(uint32_t bg, uint32_t fg, unsigned a)
{
	unsigned na = 255 - a, sh;
	uint32_t out = 0;

	/* Channel by channel: dividing two packed channels at once lets one
	 * channel's remainder into the next (measured: colour fringes). */
	for (sh = 0; sh < 32; sh += 8)
		out |= ((((bg >> sh) & 0xff) * na + ((fg >> sh) & 0xff) * a + 127) / 255) << sh;
	return out;
}

/*
 * The software path: the same quads, rasterised as the shader would --
 * each pixel the background and foreground mixed by the glyph's coverage
 * -- into a premultiplied buffer that is drawn into the window's backing
 * store. Cells are pixel-aligned and the atlas holds them at 1:1, so a
 * quad is a rectangle copy with one coverage lookup per pixel.
 */
- (void)drawRect:(NSRect)dirty
{
	NSRect b = [self bounds];
	int w = (int)b.size.width, h = (int)b.size.height, n, q, x, y;
	const unsigned char *mir = atlas_mirror(atlas);
	GLubyte clear[4];
	uint32_t cl;
	CGContextRef ctx;
	CGImageRef img;

	struct timeval tA, tB;

	if (useGL || w <= 0 || h <= 0)
		return;
	gettimeofday(&tA, NULL);
	if (w != cpuW || h != cpuH) {
		free(cpuPix);
		cpuPix = malloc((size_t)w * h * 4);
		cpuW = w;
		cpuH = h;
		if (cpuCtx)
			CGContextRelease(cpuCtx);
		{
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			cpuCtx = CGBitmapContextCreate(cpuPix, w, h, 8, (size_t)w * 4, cs,
				kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
			CGColorSpaceRelease(cs);
		}
	}
	if (dirtyAll || w != lastW || h != lastH) {
		dirtyR0 = 0;
		dirtyR1 = rows - 1;
	}
	lastW = w;
	lastH = h;
	n = 0;
	if (dirtyR0 <= dirtyR1) {
		int py0 = dirtyR0 * cellH, py1 = dirtyR1 == rows - 1 ? h : (dirtyR1 + 1) * cellH;

		struct timeval tq;
		n = [self buildQuads:clear rows:dirtyR0 to:dirtyR1];
		gettimeofday(&tq, NULL);
		cpu_build_us += (tq.tv_sec - tA.tv_sec) * 1e6 + (tq.tv_usec - tA.tv_usec);
		cpu_rows += dirtyR1 - dirtyR0 + 1;
		cl = premul(clear);
		if (py1 > h) py1 = h;
		for (y = py0 * w; y < py1 * w; y++)	/* this band only */
			cpuPix[y] = cl;
	}
	dirtyAll = NO;
	dirtyR0 = 1;
	dirtyR1 = 0;
	for (q = 0; q < n; q += 4) {
		const float *v0 = verts + q * 4, *v2 = verts + (q + 2) * 4;
		int x0 = (int)v0[0], y0 = (int)v0[1], x1 = (int)v2[0], y1 = (int)v2[1];
		int u0 = (int)lroundf(v0[2] * ATLAS_PIXELS), t0 = (int)lroundf(v0[3] * ATLAS_PIXELS);
		uint32_t fg = premul(fgc + q * 4), bg = premul(bgc + q * 4);
		int solid = fg == bg;

		if (x0 < 0) x0 = 0;
		if (y0 < 0) y0 = 0;
		if (x1 > w) x1 = w;
		if (y1 > h) y1 = h;
		for (y = y0; y < y1; y++) {
			uint32_t *row = cpuPix + (size_t)y * w;
			const unsigned char *cov = mir + (size_t)(t0 + y - (int)v0[1]) * ATLAS_PIXELS
						   + u0 - (int)v0[0];
			if (solid) {
				for (x = x0; x < x1; x++)
					row[x] = fg;
				continue;
			}
			for (x = x0; x < x1; x++) {
				unsigned a = cov[x];
				row[x] = a == 0 ? bg : a == 255 ? fg : mix_px(bg, fg, a);
			}
		}
	}
	{
		struct timeval tr;
		gettimeofday(&tr, NULL);
		cpu_raster_us += (tr.tv_sec - tA.tv_sec) * 1e6 + (tr.tv_usec - tA.tv_usec);
	}
	/* An image straight over the buffer: CGBitmapContextCreateImage
	 * snapshots copy-on-write, so the next frame's first store copied
	 * all of it. This one is drawn and released before the buffer is
	 * written again. */
	{
		CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, cpuPix, (size_t)w * h * 4, NULL);
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
			kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host, dp, NULL, false,
			kCGRenderingIntentDefault);
		CGColorSpaceRelease(cs);
		CGDataProviderRelease(dp);
	}
	ctx = [[NSGraphicsContext currentContext] graphicsPort];
	CGContextSetBlendMode(ctx, kCGBlendModeCopy);
	{
		/* Only the part the window server asked for: the image's rows
		 * run top-down, the view's coordinates bottom-up. */
		NSRect d = NSIntersectionRect(NSIntegralRect(dirty), b);
		CGImageRef part = CGImageCreateWithImageInRect(img,
			CGRectMake(d.origin.x, h - d.origin.y - d.size.height, d.size.width, d.size.height));
		if (part) {
			CGContextDrawImage(ctx, NSRectToCGRect(d), part);
			CGImageRelease(part);
		}
	}
	gettimeofday(&tB, NULL);
	cpu_frames++;
	cpu_us += (tB.tv_sec - tA.tv_sec) * 1e6 + (tB.tv_usec - tA.tv_usec);
	if (dump_requested) {
		CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/pumaterm-frame.png"),
							     kCFURLPOSIXPathStyle, false);
		CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);

		dump_requested = 0;
		if (d) {
			CGImageDestinationAddImage(d, img, NULL);
			CGImageDestinationFinalize(d);
			CFRelease(d);
		}
		CFRelease(url);
		/* the backing store reaches the screen after this returns */
		[self performSelector:@selector(dumpWindowLater) withObject:nil afterDelay:0.3];
		printf("input: %u notifications + %u extra reads, %.0f bytes, %.0f us in vterm (%.0f bytes per notification)\n",
		       in_notes, in_extra, in_bytes, in_us, in_notes ? in_bytes / in_notes : 0);
		printf("dumped (CPU): %s blink ticks %u frames %u blinkOn %d; cpu frames %u, %.0f us (build %.0f, to raster end %.0f) and %.1f rows each\n",
		       [[self title] UTF8String], blink_ticks, frames_drawn, blinkOn,
		       cpu_frames, cpu_frames ? cpu_us / cpu_frames : 0,
		       cpu_frames ? cpu_build_us / cpu_frames : 0, cpu_frames ? cpu_raster_us / cpu_frames : 0,
		       cpu_frames ? cpu_rows / cpu_frames : 0);
		fflush(stdout);
	}
	CGImageRelease(img);
}

- (void)dumpWindowLater
{
	dump_window((CGWindowID)[[self window] windowNumber]);
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self resizeTerminal];
}

- (void)resizeTerminal
{
	NSRect b = [self bounds];
	int nc, nr;

	if (vt == NULL || cellW <= 0 || cellH <= 0)	/* NSView's init sizes us first */
		return;
	nc = (int)(b.size.width / cellW);
	nr = (int)(b.size.height / cellH);

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

static VTermModifier mods_of(NSEvent *e, BOOL optionMeta)
{
	NSUInteger f = [e modifierFlags];
	int m = VTERM_MOD_NONE;

	if (f & NSShiftKeyMask)		m |= VTERM_MOD_SHIFT;
	if (f & NSControlKeyMask)	m |= VTERM_MOD_CTRL;
	if (optionMeta && (f & NSAlternateKeyMask))
		m |= VTERM_MOD_ALT;	/* else Option composes characters */
	return (VTermModifier)m;
}

- (void)keyDown:(NSEvent *)e
{
	NSString *s = [e charactersIgnoringModifiers];
	VTermModifier mod = mods_of(e, optionMeta);
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
	blinkOn = YES;			/* the cursor shows while typing */
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
		vterm_mouse_move(vt, row, col, mods_of(e, optionMeta));
		vterm_mouse_button(vt, dy > 0 ? 4 : 5, true, mods_of(e, optionMeta));
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
	vterm_mouse_move(vt, row, col, mods_of(e, optionMeta));
	if (button)
		vterm_mouse_button(vt, button, pressed, mods_of(e, optionMeta));
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
	/* GL names are per context: delete this tab's texture in its own
	 * context, not in whichever another tab left current. */
	[[glView openGLContext] makeCurrentContext];
	atlas_destroy(atlas);
	for (i = 0; i < sbSize; i++)
		free(sb[i].cells);
	free(sb);
	free(verts);
	free(fgc);
	free(bgc);
	free(cpuPix);
	if (cpuCtx)
		CGContextRelease(cpuCtx);
	[glView release];
	[fontName release];
	[title release];
	[super dealloc];
}

@end
