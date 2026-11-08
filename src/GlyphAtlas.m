/*
 * GlyphAtlas.m -- rasterize glyphs once, into a 2048 x 2048 GL_ALPHA texture.
 *
 * Every slot is two cells wide (so a double-width glyph fits) and one cell
 * high; slot 0 stays blank and is what a space maps to. Lookups go through a
 * small open-addressed table keyed by code point and style. When the
 * atlas fills it is cleared and refilled from the glyphs on screen, which a
 * terminal's working set never comes near.
 *
 * Mac OS X 10.5 constraints: Core Text is there (CTFontCreateWithName,
 * CTFontGetGlyphsForCharacters, CTFontCreateForString for fallback), but
 * CTFontDrawGlyphs is 10.7, so glyphs are drawn with the font's CGFont and
 * CGContextShowGlyphsAtPoint.
 *
 * Braille (U+2800-28FF), block elements (U+2580-259F) and the light/heavy
 * box-drawing lines are drawn here instead of taken from a font: btop and
 * friends build graphs and frames from them, and a fallback font's glyphs do
 * not fill the cell exactly, which shows as gaps and steps.
 *
 * Bold and italic use the family's own faces when Core Text finds them
 * (Hack Nerd Font Mono ships all four); a family without them, Monaco among
 * them, gets a stroked bold and a sheared italic instead.
 */
#include "GlyphAtlas.h"

#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define ATLAS_SIZE	2048
#define TABLE_SIZE	8192		/* power of two */

struct entry { uint32_t key; uint16_t slot; uint16_t used; };

struct GlyphAtlas {
	CTFontRef	font;
	CTFontRef	face[4];		/* indexed by ATLAS_BOLD|ATLAS_ITALIC */
	int		synth[4];		/* the same bits, where faked */
	int		cell_w, cell_h;
	float		descent;
	int		slot_w, slots_x, slots_y, next_slot;
	GLuint		tex;
	unsigned char  *bitmap;			/* one slot's pixels */
	CGContextRef	ctx;
	struct entry	table[TABLE_SIZE];
};

/*
 * The face for a style, from the font's own family when it has one. Core
 * Text hands back the same face, or NULL, when the family lacks the trait,
 * so the PostScript names are compared rather than trusting a non-NULL
 * result.
 */
static CTFontRef style_face(CTFontRef base, int style, int *synth)
{
	CTFontSymbolicTraits t = ((style & ATLAS_BOLD) ? kCTFontBoldTrait : 0) |
				 ((style & ATLAS_ITALIC) ? kCTFontItalicTrait : 0);
	CTFontRef f = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, t, t);
	CTFontSymbolicTraits got;

	if (f == NULL) {
		*synth = style;
		return (CTFontRef)CFRetain(base);
	}
	got = CTFontGetSymbolicTraits(f);
	*synth = 0;
	if ((style & ATLAS_BOLD) && !(got & kCTFontBoldTrait))
		*synth |= ATLAS_BOLD;
	if ((style & ATLAS_ITALIC) && !(got & kCTFontItalicTrait))
		*synth |= ATLAS_ITALIC;
	{
		CFStringRef bn = CTFontCopyPostScriptName(base), fn = CTFontCopyPostScriptName(f);
		if (CFStringCompare(bn, fn, 0) == kCFCompareEqualTo)
			*synth = style;
		CFRelease(bn);
		CFRelease(fn);
	}
	return f;
}

GlyphAtlas *atlas_create(const char *font_name, float point_size)
{
	GlyphAtlas *a = calloc(1, sizeof *a);
	CFStringRef name = CFStringCreateWithCString(NULL, font_name, kCFStringEncodingUTF8);
	UniChar m = 'M';
	CGGlyph g;
	CGSize adv;
	CGColorSpaceRef gray;
	int i;

	a->font = CTFontCreateWithName(name, point_size, NULL);
	CFRelease(name);
	a->face[0] = (CTFontRef)CFRetain(a->font);
	for (i = 1; i < 4; i++)
		a->face[i] = style_face(a->font, i, &a->synth[i]);

	CTFontGetGlyphsForCharacters(a->font, &m, &g, 1);
	CTFontGetAdvancesForGlyphs(a->font, kCTFontDefaultOrientation, &g, &adv, 1);
	a->cell_w = (int)ceilf(adv.width);
	a->cell_h = (int)ceilf(CTFontGetAscent(a->font) + CTFontGetDescent(a->font)
			       + CTFontGetLeading(a->font));
	a->descent = ceilf(CTFontGetDescent(a->font));

	a->slot_w = 2 * a->cell_w;
	a->slots_x = ATLAS_SIZE / a->slot_w;
	a->slots_y = ATLAS_SIZE / a->cell_h;
	a->next_slot = 1;

	a->bitmap = calloc((size_t)a->slot_w * a->cell_h, 1);
	gray = CGColorSpaceCreateDeviceGray();
	a->ctx = CGBitmapContextCreate(a->bitmap, a->slot_w, a->cell_h, 8, a->slot_w,
				       gray, kCGImageAlphaNone);
	CGColorSpaceRelease(gray);
	CGContextSetGrayFillColor(a->ctx, 1.0, 1.0);
	CGContextSetGrayStrokeColor(a->ctx, 1.0, 1.0);
	CGContextSetShouldAntialias(a->ctx, true);
	CGContextSetShouldSmoothFonts(a->ctx, false);
	return a;
}

void atlas_destroy(GlyphAtlas *a)
{
	int i;

	if (!a)
		return;
	if (a->tex)
		glDeleteTextures(1, &a->tex);
	CGContextRelease(a->ctx);
	free(a->bitmap);
	CFRelease(a->font);
	for (i = 0; i < 4; i++)
		CFRelease(a->face[i]);
	free(a);
}

void atlas_metrics(const GlyphAtlas *a, int *cell_w, int *cell_h)
{
	*cell_w = a->cell_w;
	*cell_h = a->cell_h;
}

GLuint atlas_texture(GlyphAtlas *a)
{
	if (a->tex == 0) {
		unsigned char *zero = calloc(ATLAS_SIZE, ATLAS_SIZE);

		glGenTextures(1, &a->tex);
		glBindTexture(GL_TEXTURE_2D, a->tex);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA8, ATLAS_SIZE, ATLAS_SIZE, 0,
			     GL_ALPHA, GL_UNSIGNED_BYTE, zero);
		free(zero);
	}
	return a->tex;
}

/* ---- the procedural glyphs ------------------------------------------ */

/* Fill a rectangle in cell coordinates measured from the TOP left, which is
 * how the shapes are described; the bitmap context's origin is bottom left. */
static void fill(GlyphAtlas *a, float x, float y, float w, float h)
{
	CGContextFillRect(a->ctx, CGRectMake(x, a->cell_h - y - h, w, h));
}

static int draw_braille(GlyphAtlas *a, uint32_t cp, int w)
{
	/* Dots 1-8: bits 0-7, columns (1,2,3,7) left and (4,5,6,8) right. */
	static const int col[8] = { 0, 0, 0, 1, 1, 1, 0, 1 };
	static const int row[8] = { 0, 1, 2, 0, 1, 2, 3, 3 };
	unsigned bits = cp - 0x2800;
	float cw = (float)w / 2, rh = (float)a->cell_h / 4;
	float d = floorf(fminf(cw, rh) * 0.6f);
	int i;

	if (d < 1)
		d = 1;
	for (i = 0; i < 8; i++)
		if (bits & (1u << i))
			fill(a, floorf(col[i] * cw + (cw - d) / 2),
			     floorf(row[i] * rh + (rh - d) / 2), d, d);
	return 1;
}

static int draw_block(GlyphAtlas *a, uint32_t cp, int w)
{
	float h = a->cell_h;

	if (cp >= 0x2581 && cp <= 0x2588) {		/* lower 1/8 .. full */
		float fh = roundf(h * (cp - 0x2580) / 8.0f);
		fill(a, 0, h - fh, w, fh);
	} else if (cp == 0x2580) {			/* upper half */
		fill(a, 0, 0, w, roundf(h / 2));
	} else if (cp >= 0x2589 && cp <= 0x258F) {	/* left 7/8 .. 1/8 */
		fill(a, 0, 0, roundf(w * (0x2590 - cp) / 8.0f), h);
	} else if (cp == 0x2590) {			/* right half */
		fill(a, roundf(w / 2.0f), 0, w - roundf(w / 2.0f), h);
	} else if (cp >= 0x2591 && cp <= 0x2593) {	/* light, medium, dark shade */
		CGContextSetGrayFillColor(a->ctx, 1.0, 0.25f * (cp - 0x2590));
		fill(a, 0, 0, w, h);
		CGContextSetGrayFillColor(a->ctx, 1.0, 1.0);
	} else if (cp == 0x2594) {			/* upper 1/8 */
		fill(a, 0, 0, w, roundf(h / 8));
	} else if (cp == 0x2595) {			/* right 1/8 */
		fill(a, w - roundf(w / 8.0f), 0, roundf(w / 8.0f), h);
	} else if (cp >= 0x2596 && cp <= 0x259F) {	/* quadrants */
		/* bit 0 upper-left, 1 upper-right, 2 lower-left, 3 lower-right */
		static const unsigned char q[10] = { 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
		unsigned m = q[cp - 0x2596];
		float hw = roundf(w / 2.0f), hh = roundf(h / 2);
		if (m & 1) fill(a, 0, 0, hw, hh);
		if (m & 2) fill(a, hw, 0, w - hw, hh);
		if (m & 4) fill(a, 0, hh, hw, h - hh);
		if (m & 8) fill(a, hw, hh, w - hw, h - hh);
	} else {
		return 0;
	}
	return 1;
}

/* Box drawing: each of U+2500-257F that is made of straight lines is four
 * arms (up, right, down, left), each 0 = none, 1 = light, 2 = heavy, 3 =
 * double. Arcs (256D-2570) are drawn as corners, which is what fixed-cell
 * renderers do; diagonals and dashes fall through to the font. */
static const char *const box_arms[] = {
	/* 2500 */ "0101", "0202", "1010", "2020", 0, 0, 0, 0, 0, 0, 0, 0,
	/* 250C */ "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",
	/* 2514 */ "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",
	/* 251C */ "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
	/* 2524 */ "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",
	/* 252C */ "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",
	/* 2534 */ "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
	/* 253C */ "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",
	/* 2544 */ "2211", "1122", "1221", "2212", "2122", "1222", "2221", "2222",
	/* 254C */ 0, 0, 0, 0,
	/* 2550 */ "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033",
	/* 2558 */ "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
	/* 2560 */ "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",
	/* 2568 */ "3101", "3303", "1313", "3131", "3333",
	/* 256D */ "0110", "0011", "1001", "1100",
	/* 2571 */ 0, 0, 0,
	/* 2574 */ "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",
	/* 257C */ "0201", "1020", "0102", "2010",
};

static int draw_box(GlyphAtlas *a, uint32_t cp, int w)
{
	const char *arms;
	float h = a->cell_h, cx = floorf(w / 2.0f), cy = floorf(h / 2);
	float lt = fmaxf(1, floorf(a->cell_w / 8.0f)), ht = lt * 2;
	int i;

	if (cp < 0x2500 || cp > 0x257F || (arms = box_arms[cp - 0x2500]) == 0)
		return 0;
	for (i = 0; i < 4; i++) {
		int k = arms[i] - '0';
		float t = (k == 2) ? ht : lt;
		float off[2] = { 0, 0 };
		int n = 1, j;

		if (k == 0)
			continue;
		if (k == 3) {			/* double: two light strokes */
			n = 2;
			off[0] = -lt;
			off[1] = lt;
		}
		for (j = 0; j < n; j++) {
			float o = off[j];
			switch (i) {
			case 0: fill(a, cx - t / 2 + o, 0, t, cy + t / 2); break;		/* up */
			case 1: fill(a, cx - t / 2, cy - t / 2 + o, w - cx + t / 2, t); break;	/* right */
			case 2: fill(a, cx - t / 2 + o, cy - t / 2, t, h - cy + t / 2); break;	/* down */
			case 3: fill(a, 0, cy - t / 2 + o, cx + t / 2, t); break;		/* left */
			}
		}
	}
	return 1;
}

/* ---- font glyphs ----------------------------------------------------- */

static void draw_font_glyph(GlyphAtlas *a, uint32_t cp, int style)
{
	CTFontRef f = a->face[style];
	CTFontRef use = f, fallback = NULL;
	UniChar u[2];
	CGGlyph g[2] = { 0, 0 };
	CFIndex n;
	CGFontRef cg;

	if (cp > 0xFFFF) {
		u[0] = (UniChar)(0xD800 + ((cp - 0x10000) >> 10));
		u[1] = (UniChar)(0xDC00 + ((cp - 0x10000) & 0x3FF));
		n = 2;
	} else {
		u[0] = (UniChar)cp;
		n = 1;
	}
	if (!CTFontGetGlyphsForCharacters(f, u, g, n) || g[0] == 0) {
		CFStringRef s = CFStringCreateWithCharacters(NULL, u, n);
		fallback = CTFontCreateForString(f, s, CFRangeMake(0, n));
		CFRelease(s);
		if (fallback && CTFontGetGlyphsForCharacters(fallback, u, g, n) && g[0])
			use = fallback;
		else
			goto out;
	}
	cg = CTFontCopyGraphicsFont(use, NULL);
	CGContextSetFont(a->ctx, cg);
	CGContextSetFontSize(a->ctx, CTFontGetSize(use));
	/* Shear about the baseline, 0.2 being about 11 degrees, the slant of
	 * a typical oblique; stroke with 1/24 em, about one step of weight. */
	CGContextSetTextMatrix(a->ctx, (a->synth[style] & ATLAS_ITALIC)
			       ? CGAffineTransformMake(1, 0, 0.2f, 1, 0, 0)
			       : CGAffineTransformIdentity);
	if (a->synth[style] & ATLAS_BOLD) {
		CGContextSetTextDrawingMode(a->ctx, kCGTextFillStroke);
		CGContextSetLineWidth(a->ctx, CTFontGetSize(use) / 24);
	} else
		CGContextSetTextDrawingMode(a->ctx, kCGTextFill);
	CGContextShowGlyphsAtPoint(a->ctx, 0, a->descent, g, 1);
	CGFontRelease(cg);
out:
	if (fallback)
		CFRelease(fallback);
}

/* ---- lookup ------------------------------------------------------------ */

static void slot_uv(const GlyphAtlas *a, int slot, int wide, float uv[4])
{
	int sx = (slot % a->slots_x) * a->slot_w, sy = (slot / a->slots_x) * a->cell_h;

	uv[0] = (float)sx / ATLAS_SIZE;
	uv[1] = (float)sy / ATLAS_SIZE;
	uv[2] = (float)(sx + wide * a->cell_w) / ATLAS_SIZE;
	uv[3] = (float)(sy + a->cell_h) / ATLAS_SIZE;
}

void atlas_lookup(GlyphAtlas *a, uint32_t cp, int style, int wide, float uv[4])
{
	/* Code points stop at 21 bits; style takes 29 and 31, width 30. */
	uint32_t key = cp | ((style & ATLAS_BOLD) ? 0x80000000u : 0) |
		       ((style & ATLAS_ITALIC) ? 0x20000000u : 0) |
		       (wide == 2 ? 0x40000000u : 0);
	unsigned h = (key * 2654435761u) & (TABLE_SIZE - 1);
	int slot, w = wide * a->cell_w;

	if (cp == 0 || cp == ' ') {
		slot_uv(a, 0, wide, uv);
		return;
	}
	while (a->table[h].used) {
		if (a->table[h].key == key) {
			slot_uv(a, a->table[h].slot, wide, uv);
			return;
		}
		h = (h + 1) & (TABLE_SIZE - 1);
	}

	if (a->next_slot >= a->slots_x * a->slots_y || a->next_slot >= 0xFFFF) {
		/* Full: start again. Whatever is on screen is re-rasterized on the
		 * next frame; a terminal's working set never gets near this. */
		memset(a->table, 0, sizeof a->table);
		a->next_slot = 1;
		h = (key * 2654435761u) & (TABLE_SIZE - 1);
	}
	slot = a->next_slot++;

	memset(a->bitmap, 0, (size_t)a->slot_w * a->cell_h);
	if (!((cp >= 0x2800 && cp <= 0x28FF && draw_braille(a, cp, w)) ||
	      (cp >= 0x2580 && cp <= 0x259F && draw_block(a, cp, w)) ||
	      (cp >= 0x2500 && cp <= 0x257F && draw_box(a, cp, w))))
		draw_font_glyph(a, cp, style & 3);
	CGContextFlush(a->ctx);

	glBindTexture(GL_TEXTURE_2D, atlas_texture(a));
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexSubImage2D(GL_TEXTURE_2D, 0, (slot % a->slots_x) * a->slot_w,
			(slot / a->slots_x) * a->cell_h, a->slot_w, a->cell_h,
			GL_ALPHA, GL_UNSIGNED_BYTE, a->bitmap);

	a->table[h].key = key;
	a->table[h].slot = (uint16_t)slot;
	a->table[h].used = 1;
	slot_uv(a, slot, wide, uv);
}
