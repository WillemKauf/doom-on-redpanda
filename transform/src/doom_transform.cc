// Redpanda transform: one doomgeneric_Tick() per input record.
//
// Input record format:
//   u32  tick_seq
//   u8   event_count
//   repeat event_count times:
//     u8 doom_key
//     u8 down
//
// Output record format:
//   u32    tick_seq  (echoed)
//   u8     palette_present
//   [768]  palette   (iff palette_present == 1)
//   [64000] pixels

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <system_error>

#include <redpanda/transform_sdk.h>

extern "C" {
#include "doom_input_queue.h"
#include "doom_frame_capture.h"

// doomgeneric API.
void doomgeneric_Create(int argc, char **argv);
void doomgeneric_Tick(void);

// Provided by doom_stubs.c.
void doom_stubs_advance_ticks(uint32_t delta_ms);
}

namespace {

constexpr uint32_t kTickMs = 29;   // ~35 Hz, matching Doom's native tic rate.
bool g_doom_ready = false;

void ensure_doom_initialized() {
    if (g_doom_ready) return;
    // doomgeneric_Create inspects argv for -iwad etc. We embed the WAD
    // so argc=1 is fine; the patched loader ignores the path.
    static char argv0[] = "doom";
    static char *argv[] = {argv0, nullptr};
    doomgeneric_Create(1, argv);
    doom_input_queue_reset();
    doom_frame_capture_reset();
    g_doom_ready = true;
}

uint32_t read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void write_u32_le(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
    p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}

std::error_code on_record(redpanda::write_event event,
                          redpanda::record_writer *writer) {
    ensure_doom_initialized();
    doom_stubs_advance_ticks(kTickMs);

    // ---- decode input ----
    if (!event.record.value.has_value() || event.record.value->size() < 5) {
        std::fprintf(stderr, "doom: malformed input record: size < 5\n");
        return {};
    }
    redpanda::bytes_view value = *event.record.value;
    const uint8_t *p   = value.begin();
    const uint8_t *end = value.end();
    uint32_t tick_seq  = read_u32_le(p); p += 4;
    uint8_t  n         = *p++;
    if (end - p < (ptrdiff_t)(2 * (size_t)n)) {
        std::fprintf(stderr, "doom: truncated input record\n");
        return {};
    }
    for (uint8_t i = 0; i < n; i++) {
        unsigned char doom_key = *p++;
        int pressed            = (*p++) ? 1 : 0;
        doom_input_queue_push(pressed, doom_key);
    }

    // ---- run one tick ----
    doomgeneric_Tick();

    // ---- encode output ----
    if (!doom_frame_capture_has_frame()) {
        std::fprintf(stderr, "doom: no frame produced this tick\n");
        return {};
    }
    const uint8_t *pixels; const uint8_t *palette; int palette_dirty;
    doom_frame_capture_get(&pixels, &palette, &palette_dirty);

    size_t header_sz = 4 + 1 + (palette_dirty ? 768 : 0);
    size_t out_sz    = header_sz + 64000;
    redpanda::bytes out(out_sz);
    uint8_t *w = out.data();
    write_u32_le(w, tick_seq); w += 4;
    *w++ = palette_dirty ? 1 : 0;
    if (palette_dirty) { std::memcpy(w, palette, 768); w += 768; }
    std::memcpy(w, pixels, 64000);

    redpanda::record out_record;
    // Echo the input key ("p1" in practice).
    if (event.record.key.has_value()) {
        redpanda::bytes_view kv = *event.record.key;
        out_record.key = redpanda::bytes(kv.begin(), kv.end());
    }
    out_record.value = std::move(out);
    return writer->write(out_record);
}

}  // namespace

int main() {
    redpanda::on_record_written(on_record);
    return 0;
}
