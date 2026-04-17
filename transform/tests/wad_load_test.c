// Host-native test: verifies doomgeneric's WAD loader reads from the
// embedded buffer and returns the expected header. Does NOT run Doom.

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Provided by the patched w_file_stdc.c via -DDOOMWAD_FROM_MEMORY=1.
extern const unsigned char doom_wad[];
extern const unsigned long doom_wad_len;

// Minimal Doom WAD header layout (see wiki.doomworld.com/DOOM_WAD).
struct wad_header {
    char     magic[4];      // "IWAD" or "PWAD"
    uint32_t numlumps;
    uint32_t infotableofs;
};

// Native-host stubs (doomgeneric's z_zone.c is wasm-only context for us).
void *Z_Malloc(int n, int tag, void *user) { (void)tag; (void)user; return malloc((size_t)n); }
void  Z_Free(void *p) { free(p); }
void  Z_ChangeTag2(void *ptr, int tag, char *file, int line) {
    (void)ptr; (void)tag; (void)file; (void)line;
}
void I_Error(const char *fmt, ...) { (void)fmt; abort(); }

// M_FileLength is used by the unpatched loader path. Provide a stub so
// linking succeeds even when DOOMWAD_FROM_MEMORY is not defined.
long M_FileLength(FILE *handle) {
    if (!handle) return 0;
    long cur = ftell(handle);
    fseek(handle, 0, SEEK_END);
    long len = ftell(handle);
    fseek(handle, cur, SEEK_SET);
    return len;
}

// --- second test: exercise the patched wad_file_class_t ---
#include "../doomgeneric/w_file.h"

extern wad_file_class_t stdc_wad_file;

static int test_open_read_close(void) {
    wad_file_t *w = stdc_wad_file.OpenFile("ignored");
    if (!w) { printf("OpenFile returned NULL\n"); return 1; }

    char magic[4] = {0};
    size_t n = stdc_wad_file.Read(w, 0, magic, 4);
    if (n != 4 || memcmp(magic, "IWAD", 4) != 0) {
        printf("Read failed: n=%zu magic=%.4s\n", n, magic);
        return 1;
    }

    stdc_wad_file.CloseFile(w);
    printf("wad_file_class round-trip: ok\n");
    return 0;
}

int main(void) {
    assert(doom_wad_len > sizeof(struct wad_header));

    struct wad_header h;
    memcpy(&h, doom_wad, sizeof(h));

    // Shareware doom1.wad is an IWAD.
    assert(memcmp(h.magic, "IWAD", 4) == 0);
    assert(h.numlumps > 0 && h.numlumps < 1000000);
    assert(h.infotableofs < doom_wad_len);

    printf("wad_load_test: ok (magic=%.4s, lumps=%u)\n",
           h.magic, h.numlumps);

    if (test_open_read_close() != 0) return 1;
    return 0;
}
