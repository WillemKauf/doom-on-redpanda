#include "doom_frame_capture.h"

#include <string.h>

static uint8_t s_pixels[DOOM_FRAME_BYTES];
static uint8_t s_palette[DOOM_PALETTE_BYTES];
static int     s_has_frame;
static int     s_palette_set;         // has a palette ever been captured
static int     s_palette_dirty;       // palette changed since last get()

void doom_frame_capture_reset(void) {
    s_has_frame     = 0;
    s_palette_set   = 0;
    s_palette_dirty = 0;
}

void doom_frame_capture_on_draw(const uint8_t *screen_buf) {
    memcpy(s_pixels, screen_buf, DOOM_FRAME_BYTES);
    s_has_frame = 1;
}

void doom_frame_capture_on_palette(const uint8_t *palette) {
    if (!s_palette_set || memcmp(s_palette, palette, DOOM_PALETTE_BYTES) != 0) {
        memcpy(s_palette, palette, DOOM_PALETTE_BYTES);
        s_palette_dirty = 1;
        s_palette_set   = 1;
    }
}

int doom_frame_capture_has_frame(void) {
    return s_has_frame;
}

void doom_frame_capture_get(const uint8_t **pixels,
                            const uint8_t **palette,
                            int *palette_dirty) {
    *pixels = s_pixels;
    if (s_palette_dirty) {
        *palette       = s_palette;
        *palette_dirty = 1;
    } else {
        *palette       = 0;
        *palette_dirty = 0;
    }
    s_palette_dirty = 0;
    s_has_frame     = 0;
}
