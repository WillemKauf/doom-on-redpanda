#ifndef DOOM_FRAME_CAPTURE_H
#define DOOM_FRAME_CAPTURE_H

#include <stdint.h>

// 320x200 native Doom resolution, 1 byte per pixel (palette index).
#define DOOM_FRAME_WIDTH   320
#define DOOM_FRAME_HEIGHT  200
#define DOOM_FRAME_BYTES   (DOOM_FRAME_WIDTH * DOOM_FRAME_HEIGHT)

// 256 RGB triplets.
#define DOOM_PALETTE_BYTES (256 * 3)

#ifdef __cplusplus
extern "C" {
#endif

void doom_frame_capture_reset(void);

// Called from DG_DrawFrame. screen_buf must point to DOOM_FRAME_BYTES
// of 8-bit palette-indexed pixels.
void doom_frame_capture_on_draw(const uint8_t *screen_buf);

// Called when Doom's I_SetPalette fires. palette must point to
// DOOM_PALETTE_BYTES of RGB triplets (24-bit).
void doom_frame_capture_on_palette(const uint8_t *palette);

int doom_frame_capture_has_frame(void);

// Retrieves the most recent frame + palette, and marks the frame as
// consumed. After this call, has_frame() returns 0 until on_draw is
// called again. palette_dirty is set to 1 iff the palette changed since
// the last get() call; if so, *palette points to DOOM_PALETTE_BYTES,
// else *palette is NULL.
void doom_frame_capture_get(const uint8_t **pixels,
                            const uint8_t **palette,
                            int *palette_dirty);

#ifdef __cplusplus
}
#endif

#endif
