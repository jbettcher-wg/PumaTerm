/* GlyphAtlas.h -- glyphs rasterized once into one GL texture. */
#ifndef TERM_GLYPHATLAS_H
#define TERM_GLYPHATLAS_H
#include <stdint.h>
#include <OpenGL/gl.h>

typedef struct GlyphAtlas GlyphAtlas;

/* Create for a font at a point size; nothing touches GL until the first
 * lookup, which must run with the view's context current. */
GlyphAtlas *atlas_create(const char *font_name, float point_size);
void        atlas_destroy(GlyphAtlas *a);

/* Cell size in pixels, and the baseline's distance from the cell bottom. */
void atlas_metrics(const GlyphAtlas *a, int *cell_w, int *cell_h);

/* Texture coordinates {u0, v0, u1, v1} of the glyph for code point cp,
 * rasterizing and uploading it on first use. wide = 2 for a double-width
 * cell. v0 is the top of the cell. */
void atlas_lookup(GlyphAtlas *a, uint32_t cp, int bold, int wide, float uv[4]);

GLuint atlas_texture(GlyphAtlas *a);

#endif
