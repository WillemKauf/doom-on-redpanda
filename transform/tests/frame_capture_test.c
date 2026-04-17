#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "../src/doom_frame_capture.h"

int main(void) {
    doom_frame_capture_reset();

    // Fresh state: no frame yet, no palette yet.
    const uint8_t *pixels; const uint8_t *palette; int palette_dirty;
    assert(doom_frame_capture_has_frame() == 0);

    // Simulate DG_DrawFrame: copy a fake screen buffer.
    uint8_t fake_screen[DOOM_FRAME_BYTES];
    for (int i = 0; i < DOOM_FRAME_BYTES; i++) fake_screen[i] = (uint8_t)(i & 0xFF);
    doom_frame_capture_on_draw(fake_screen);

    assert(doom_frame_capture_has_frame() == 1);
    doom_frame_capture_get(&pixels, &palette, &palette_dirty);
    assert(memcmp(pixels, fake_screen, DOOM_FRAME_BYTES) == 0);
    // No palette has been set yet, so not dirty.
    assert(palette_dirty == 0);

    // After get, frame is consumed.
    assert(doom_frame_capture_has_frame() == 0);

    // Now simulate a palette change.
    uint8_t fake_palette[DOOM_PALETTE_BYTES];
    for (int i = 0; i < DOOM_PALETTE_BYTES; i++) fake_palette[i] = (uint8_t)(255 - i);
    doom_frame_capture_on_palette(fake_palette);

    // Next frame should report palette dirty.
    doom_frame_capture_on_draw(fake_screen);
    doom_frame_capture_get(&pixels, &palette, &palette_dirty);
    assert(palette_dirty == 1);
    assert(memcmp(palette, fake_palette, DOOM_PALETTE_BYTES) == 0);

    // Subsequent frame without palette change: not dirty.
    doom_frame_capture_on_draw(fake_screen);
    doom_frame_capture_get(&pixels, &palette, &palette_dirty);
    assert(palette_dirty == 0);

    printf("frame_capture_test: ok\n");
    return 0;
}
