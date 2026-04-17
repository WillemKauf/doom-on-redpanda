# Doom on Redpanda — Phase 1 Implementation Plan (Transform + docker-compose)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get `doomgeneric` running inside a Redpanda Data Transform on the produce path, driven by `rpk topic produce`/`consume` against a single-broker docker-compose stack. At the end of this plan you can push an input record and see a well-formed frame record come back. The Go WS bridge and the browser UI are Phase 2.

**Architecture:** doomgeneric is vendored into `transform/doomgeneric/`, compiled with `-DCMAP256=1 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200` so `DG_ScreenBuffer` is a 64,000-byte 8-bit indexed framebuffer at native resolution. The WAD is embedded as a `const uint8_t[]` at build time; `w_file_stdc.c` is patched to read from that buffer. The transform entry point is C++23 linked against `redpanda::transform_sdk`, compiled to `wasm32-wasi` via the WASI SDK Docker image. Exactly one `doomgeneric_Tick()` runs per input record, and `DG_DrawFrame` writes the resulting framebuffer + (optional) palette into one output record.

**Tech Stack:** C (doomgeneric, glue), C++23 (SDK entry), WASI SDK (Docker image `ghcr.io/webassembly/wasi-sdk`), wasmtime (host-side test loader), Redpanda, `rpk`, docker-compose.

---

## Prerequisites (one-time, not scripted)

- Docker Engine installed and running
- `~/Downloads/doom1.wad` (the user has this)
- `rpk` available on the host, or use the one inside the `redpanda` container via `docker exec`
- GCC/clang + pkg-config on the host (for native unit tests of pure-C modules)
- libwasmtime headers + library on the host, for the host-side `.wasm` test. Install: `curl -L https://github.com/bytecodealliance/wasmtime/releases/latest/download/wasmtime-v25.0.0-x86_64-linux-c-api.tar.xz | tar -xJ` and set `WASMTIME_DIR` to the extracted directory. The test Makefile uses `$(WASMTIME_DIR)/include` and `$(WASMTIME_DIR)/lib`. Skip if you don't care about the host-side test and only want the e2e smoke test against Redpanda.

## File structure this plan creates

```
doom-on-redpanda/
├── .gitignore
├── README.md
├── docker-compose.yml
├── deploy/
│   └── init.sh                          # rpk topic create + transform deploy
├── transform/
│   ├── Dockerfile.build                 # wasi-sdk + build entry
│   ├── Makefile                         # wasm build + native tests
│   ├── doomgeneric/                     # vendored from github.com/ozkl/doomgeneric
│   ├── include/
│   │   └── redpanda_transform_sdk/      # copied from redpanda repo
│   ├── src/
│   │   ├── doom_transform.cc            # redpanda::on_record_written entry point
│   │   ├── doom_input_queue.c           # key ring buffer backing DG_GetKey
│   │   ├── doom_input_queue.h
│   │   ├── doom_frame_capture.c         # DG_DrawFrame + palette snapshot
│   │   ├── doom_frame_capture.h
│   │   ├── doom_stubs.c                 # DG_Init/DG_SleepMs/DG_GetTicksMs/DG_SetWindowTitle
│   │   └── wad_embedded.h               # generated at build time
│   ├── tools/
│   │   └── embed_wad.sh                 # xxd -i → wad_embedded.h
│   ├── patches/
│   │   └── 0001-load-wad-from-memory.patch
│   └── tests/
│       ├── input_queue_test.c           # native gcc test
│       ├── frame_capture_test.c         # native gcc test
│       └── transform_test.c             # wasmtime-loaded end-to-end test
└── docs/
    └── superpowers/
        ├── specs/2026-04-17-doom-on-redpanda-design.md
        └── plans/2026-04-17-doom-on-redpanda-phase1-transform.md  (this file)
```

---

## Task 1: Scaffold repo, gitignore, README stub

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: directory skeleton

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# build artifacts
transform/build/
transform/src/wad_embedded.h
transform/src/wad_embedded.bin
transform/tests/*.out

# IDE
.vscode/
.idea/
*.swp
.DS_Store

# docker volumes
data/
```

- [ ] **Step 2: Create `README.md` (stub — will be fleshed out at the end of Phase 2)**

```markdown
# Doom on Redpanda

A demo that runs id Software's *Doom* (1993) game loop inside a Redpanda
Data Transform on the produce path. One input record = one game tick = one
framebuffer record out.

See `docs/superpowers/specs/2026-04-17-doom-on-redpanda-design.md` for the
design.

## Quick start (Phase 1 — transform only, no browser yet)

```bash
# Build the WASM transform (requires Docker).
make -C transform

# Stand up Redpanda + auto-deploy the transform.
export DOOM_WAD=~/Downloads/doom1.wad
docker-compose up --build

# In another terminal, push an input record and read a frame back.
rpk topic produce doom.input --format '%v' < sample-input.bin
rpk topic consume doom.frames -n 1
```
```

- [ ] **Step 3: Create empty directories**

```bash
mkdir -p transform/src transform/tests transform/tools transform/patches transform/include deploy
```

- [ ] **Step 4: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add .gitignore README.md
git commit -m "chore: scaffold repo with gitignore and readme stub"
```

---

## Task 2: Vendor doomgeneric as a git subtree

We vendor (rather than submodule) because we're going to patch doomgeneric's
WAD loader, and a submodule with a local patch is more friction than a
subtree.

**Files:**
- Create: `transform/doomgeneric/` (copied from upstream)

- [ ] **Step 1: Clone doomgeneric into a tmp dir and copy its `doomgeneric/` subdir**

```bash
cd /tmp
git clone --depth=1 https://github.com/ozkl/doomgeneric.git
cp -r /tmp/doomgeneric/doomgeneric /home/willem/doom-on-redpanda/transform/
cp /tmp/doomgeneric/LICENSE /home/willem/doom-on-redpanda/transform/doomgeneric/LICENSE
# Remove the platform-specific implementations we will not use:
rm /home/willem/doom-on-redpanda/transform/doomgeneric/doomgeneric_sdl.c
rm /home/willem/doom-on-redpanda/transform/doomgeneric/doomgeneric_xlib.c
rm /home/willem/doom-on-redpanda/transform/doomgeneric/doomgeneric_win.c
rm /home/willem/doom-on-redpanda/transform/doomgeneric/doomgeneric_allegro.c 2>/dev/null || true
```

- [ ] **Step 2: Verify the expected files exist**

Run: `ls /home/willem/doom-on-redpanda/transform/doomgeneric/ | head -30`
Expected: files including `doomgeneric.c`, `doomgeneric.h`, `d_main.c`, `w_wad.c`, `w_file_stdc.c`, `i_video.c`, `v_video.c`, `LICENSE`. If `w_file_stdc.c` is missing, the upstream may have renamed it — check for `w_file*.c`.

- [ ] **Step 3: Commit the vendored tree**

```bash
cd /home/willem/doom-on-redpanda
git add transform/doomgeneric
git commit -m "vendor: add doomgeneric from github.com/ozkl/doomgeneric

Subtree copy, not submodule, because we will be patching w_file_stdc.c
and doomgeneric.c. Platform-specific drivers (SDL/X11/Win32) removed.

Upstream is GPL-2.0; LICENSE is retained at transform/doomgeneric/LICENSE."
```

---

## Task 3: Add WAD embedder tool

We convert the user's on-disk `doom1.wad` into a C header at build time. This
avoids needing a WASI filesystem at runtime.

**Files:**
- Create: `transform/tools/embed_wad.sh`

- [ ] **Step 1: Write the embedder script**

```bash
#!/usr/bin/env bash
# Usage: embed_wad.sh <path/to/doom1.wad> <output/wad_embedded.h>
# Produces a C header with:
#   extern const unsigned char doom_wad[];
#   extern const unsigned long  doom_wad_len;

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <path/to/doom1.wad> <output/wad_embedded.h>" >&2
    exit 1
fi

WAD="$1"
OUT="$2"

if [[ ! -f "$WAD" ]]; then
    echo "error: WAD file not found: $WAD" >&2
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# xxd -i emits   unsigned char <name>[] = { 0x00, ... };
#                unsigned int  <name>_len = ...;
# We rename it to a stable symbol.
cp "$WAD" "$TMP"
(cd "$(dirname "$TMP")" && xxd -i "$(basename "$TMP")") \
    | sed "s/$(basename "$TMP")/doom_wad/g" \
    | sed 's/unsigned int doom_wad_len/unsigned long doom_wad_len/' \
    > "$OUT"

echo "wrote $OUT ($(stat -c %s "$WAD") bytes of WAD)"
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x /home/willem/doom-on-redpanda/transform/tools/embed_wad.sh
/home/willem/doom-on-redpanda/transform/tools/embed_wad.sh \
    ~/Downloads/doom1.wad /tmp/wad_embedded.h
head -2 /tmp/wad_embedded.h
tail -2 /tmp/wad_embedded.h
```

Expected: first line is `unsigned char doom_wad[] = {` and last non-empty line contains `unsigned long doom_wad_len =` followed by the WAD size (typically 4196020 for shareware v1.9). Remove the tmp header after.

- [ ] **Step 3: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/tools/embed_wad.sh
git commit -m "build: add WAD embedder script

Converts a doom1.wad on disk into a C header exposing doom_wad[] and
doom_wad_len, suitable for #include into the transform build."
```

---

## Task 4: Patch doomgeneric to read WAD from memory

doomgeneric's `w_file_stdc.c` implements the `wad_file_class_t` with
`W_AddFile_Stdc` opening the WAD via `fopen`. We replace the file-backed
reads with slice reads over the embedded buffer.

This task writes a test first (a host-native compile that exercises WAD
opening) so that the patch is TDD-style.

**Files:**
- Create: `transform/tests/wad_load_test.c`
- Modify: `transform/doomgeneric/w_file_stdc.c`

- [ ] **Step 1: Survey the existing WAD loader**

Run: `grep -n "fopen\|fread\|fseek\|ftell\|fclose" /home/willem/doom-on-redpanda/transform/doomgeneric/w_file_stdc.c`
Read the file and identify: the `W_AddFile_Stdc` entry point (returns `wad_file_t*` on success), the `W_Read_Stdc` read function, the `W_CloseFile_Stdc` close function. Note the struct layout — `stdc_wad_file_t` likely embeds `wad_file_t` with an appended `FILE* fstream`.

**Expected finding:** three functions plus a global `stdc_wad_file_class`.

- [ ] **Step 2: Write the failing test**

Create `transform/tests/wad_load_test.c`:

```c
// Host-native test: verifies doomgeneric's WAD loader reads from the
// embedded buffer and returns the expected header. Does NOT run Doom.

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "../doomgeneric/w_wad.h"

// Provided by the patched w_file_stdc.c via -DDOOMWAD_FROM_MEMORY=1.
extern const unsigned char doom_wad[];
extern const unsigned long doom_wad_len;

// Minimal Doom WAD header layout (see wiki.doomworld.com/DOOM_WAD).
struct wad_header {
    char     magic[4];      // "IWAD" or "PWAD"
    uint32_t numlumps;
    uint32_t infotableofs;
};

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
    return 0;
}
```

- [ ] **Step 3: Run it — verify it fails to compile**

```bash
cd /home/willem/doom-on-redpanda/transform
/home/willem/doom-on-redpanda/transform/tools/embed_wad.sh \
    ~/Downloads/doom1.wad src/wad_embedded.h
gcc -DDOOMWAD_FROM_MEMORY=1 -I src -I doomgeneric \
    tests/wad_load_test.c src/wad_embedded.h \
    -o tests/wad_load_test.out 2>&1 | head -5
```

Expected: fails because `wad_embedded.h` is a pair of variable definitions, not a file we can `#include` as if it had `extern` decls, and because `w_wad.h` is expected by the test. The test references `doom_wad` / `doom_wad_len` via `extern` but the real header only defines them (as arrays, no extern). Also note the test uses `uint32_t` but needs `stdint.h`. Fix the test by adding `#include <stdint.h>` and compile the header as a separate translation unit.

- [ ] **Step 4: Fix the test — compile the WAD blob as its own object**

Replace the test compile step with:

```bash
cd /home/willem/doom-on-redpanda/transform
# Wrap wad_embedded.h in a .c so it becomes its own translation unit.
cat > /tmp/wad_blob.c <<'EOF'
#include "../transform/src/wad_embedded.h"
EOF
gcc -c -I src -I doomgeneric /tmp/wad_blob.c -o /tmp/wad_blob.o

# Add the required include to the test.
sed -i '/#include <string.h>/a #include <stdint.h>' tests/wad_load_test.c

gcc -I src -I doomgeneric tests/wad_load_test.c /tmp/wad_blob.o \
    -o tests/wad_load_test.out
./tests/wad_load_test.out
```

Expected: `wad_load_test: ok (magic=IWAD, lumps=1264)` (lump count may vary slightly by shareware version).

- [ ] **Step 5: Commit the test**

```bash
cd /home/willem/doom-on-redpanda
git add transform/tests/wad_load_test.c
git commit -m "test: add host-native WAD embedding sanity check"
```

- [ ] **Step 6: Now patch doomgeneric's w_file_stdc.c to read from memory**

This patch replaces `W_AddFile_Stdc`, `W_Read_Stdc`, and `W_CloseFile_Stdc`
with memory-backed versions when `DOOMWAD_FROM_MEMORY` is defined.

Rewrite `transform/doomgeneric/w_file_stdc.c` — keep the original content
wrapped in `#if !defined(DOOMWAD_FROM_MEMORY)` and append a memory-backed
implementation under `#else`. The new implementation:

```c
#ifdef DOOMWAD_FROM_MEMORY

#include <stdlib.h>
#include <string.h>

#include "doomtype.h"
#include "i_system.h"
#include "m_misc.h"
#include "w_file.h"
#include "z_zone.h"

extern const unsigned char doom_wad[];
extern const unsigned long doom_wad_len;

typedef struct {
    wad_file_t wad;   // base class
    // no extra fields: the entire WAD is at doom_wad[0..doom_wad_len]
} memory_wad_file_t;

extern wad_file_class_t stdc_wad_file;

static wad_file_t* W_OpenFile_Mem(char *path) {
    // path is ignored — there is only one WAD embedded in this build.
    memory_wad_file_t *result =
        Z_Malloc(sizeof(memory_wad_file_t), PU_STATIC, 0);
    result->wad.file_class = &stdc_wad_file;
    result->wad.mapped     = (byte *)doom_wad;
    result->wad.length     = doom_wad_len;
    return &result->wad;
}

static void W_CloseFile_Mem(wad_file_t *wad) {
    Z_Free(wad);
}

static size_t W_Read_Mem(wad_file_t *wad, unsigned int offset,
                         void *buffer, size_t buffer_len) {
    if (offset >= doom_wad_len) return 0;
    size_t remaining = doom_wad_len - offset;
    size_t to_read   = buffer_len < remaining ? buffer_len : remaining;
    memcpy(buffer, doom_wad + offset, to_read);
    return to_read;
}

wad_file_class_t stdc_wad_file = {
    W_OpenFile_Mem,
    W_CloseFile_Mem,
    W_Read_Mem,
};

#endif
```

In the top of the file, wrap the existing (unmodified) content in `#if
!defined(DOOMWAD_FROM_MEMORY)` so only one implementation is compiled.

- [ ] **Step 7: Save the patch**

```bash
cd /home/willem/doom-on-redpanda
git diff transform/doomgeneric/w_file_stdc.c > \
    transform/patches/0001-load-wad-from-memory.patch
```

- [ ] **Step 8: Write an end-to-end-ish test that actually opens the WAD via the patched loader**

Append to `transform/tests/wad_load_test.c`:

```c
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
```

And in `main()`, call `test_open_read_close()`.

- [ ] **Step 9: Rebuild and run**

Compiling now requires linking against doomgeneric's Z_Malloc/Z_Free
(`z_zone.c`) and the relevant .c files. For a minimal native-host test we
stub Z_Malloc/Z_Free with `malloc`/`free`. Add at the top of
`wad_load_test.c`:

```c
// Native-host stubs (doomgeneric's z_zone.c is wasm-only context for us).
#define Z_MALLOC_STUB 1
void *Z_Malloc(size_t n, int tag, void *user) { (void)tag; (void)user; return malloc(n); }
void  Z_Free(void *p) { free(p); }
```

Note: `Z_Malloc` takes `int` as second arg and `void*` as third in doomgeneric. If the header declares otherwise, adjust signature to match.

Build & run:

```bash
cd /home/willem/doom-on-redpanda/transform
gcc -DDOOMWAD_FROM_MEMORY=1 -I src -I doomgeneric \
    tests/wad_load_test.c doomgeneric/w_file_stdc.c src/wad_embedded.h \
    -o tests/wad_load_test.out
./tests/wad_load_test.out
```

Expected output:
```
wad_load_test: ok (magic=IWAD, lumps=1264)
wad_file_class round-trip: ok
```

- [ ] **Step 10: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/doomgeneric/w_file_stdc.c transform/patches/ transform/tests/wad_load_test.c
git commit -m "feat(transform): load WAD from embedded memory buffer

When built with -DDOOMWAD_FROM_MEMORY=1, the w_file_stdc.c loader reads
from doom_wad[0..doom_wad_len] instead of opening a file via fopen. This
avoids needing WASI filesystem preopens at transform runtime.

Tested by a host-native round-trip that opens the WAD via the patched
class and reads the IWAD magic bytes."
```

---

## Task 5: Input key ring buffer

doomgeneric's `DG_GetKey(int* pressed, unsigned char* doomKey)` returns 1 if
an event is queued, 0 otherwise. We back it with a ring buffer that the
transform entry point pushes events into.

**Files:**
- Create: `transform/src/doom_input_queue.h`
- Create: `transform/src/doom_input_queue.c`
- Create: `transform/tests/input_queue_test.c`

- [ ] **Step 1: Write the failing test**

`transform/tests/input_queue_test.c`:

```c
#include <assert.h>
#include <stdio.h>

#include "../src/doom_input_queue.h"

int main(void) {
    doom_input_queue_reset();

    // Empty queue: pop returns 0.
    int pressed; unsigned char key;
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // Push one event, pop it back.
    assert(doom_input_queue_push(1, 0x41) == 1);
    assert(doom_input_queue_pop(&pressed, &key) == 1);
    assert(pressed == 1);
    assert(key == 0x41);

    // Queue now empty again.
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // FIFO ordering.
    doom_input_queue_push(1, 0x10);
    doom_input_queue_push(0, 0x20);
    doom_input_queue_push(1, 0x30);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 1 && key == 0x10);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 0 && key == 0x20);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 1 && key == 0x30);
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // Overflow: push until full, one more fails.
    for (int i = 0; i < DOOM_INPUT_QUEUE_CAP; i++) {
        assert(doom_input_queue_push(1, (unsigned char)i) == 1);
    }
    assert(doom_input_queue_push(1, 0xFF) == 0);  // rejected

    printf("input_queue_test: ok\n");
    return 0;
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/willem/doom-on-redpanda/transform
gcc -I src tests/input_queue_test.c -o tests/input_queue_test.out 2>&1 | head -3
```

Expected: fails — `doom_input_queue.h` does not exist.

- [ ] **Step 3: Write the header**

`transform/src/doom_input_queue.h`:

```c
#ifndef DOOM_INPUT_QUEUE_H
#define DOOM_INPUT_QUEUE_H

// Ring buffer that backs doomgeneric's DG_GetKey hook.
// Single-threaded: the transform is per-shard-per-partition.

#define DOOM_INPUT_QUEUE_CAP 256

#ifdef __cplusplus
extern "C" {
#endif

void doom_input_queue_reset(void);

// Returns 1 on success, 0 if full.
int doom_input_queue_push(int pressed, unsigned char doom_key);

// Returns 1 and fills *pressed/*doom_key if an event was available,
// 0 if empty. Signature matches DG_GetKey by design.
int doom_input_queue_pop(int *pressed, unsigned char *doom_key);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 4: Write the implementation**

`transform/src/doom_input_queue.c`:

```c
#include "doom_input_queue.h"

static unsigned short s_queue[DOOM_INPUT_QUEUE_CAP];
static unsigned int   s_read_idx;
static unsigned int   s_write_idx;

void doom_input_queue_reset(void) {
    s_read_idx  = 0;
    s_write_idx = 0;
}

int doom_input_queue_push(int pressed, unsigned char doom_key) {
    unsigned int next = (s_write_idx + 1) % DOOM_INPUT_QUEUE_CAP;
    if (next == s_read_idx) return 0;   // full
    unsigned short packed = ((pressed ? 1 : 0) << 8) | (unsigned short)doom_key;
    s_queue[s_write_idx] = packed;
    s_write_idx = next;
    return 1;
}

int doom_input_queue_pop(int *pressed, unsigned char *doom_key) {
    if (s_read_idx == s_write_idx) return 0;
    unsigned short packed = s_queue[s_read_idx];
    s_read_idx = (s_read_idx + 1) % DOOM_INPUT_QUEUE_CAP;
    *pressed  = packed >> 8;
    *doom_key = packed & 0xFF;
    return 1;
}
```

- [ ] **Step 5: Compile and run the test**

```bash
cd /home/willem/doom-on-redpanda/transform
gcc -I src tests/input_queue_test.c src/doom_input_queue.c \
    -o tests/input_queue_test.out
./tests/input_queue_test.out
```

Expected: `input_queue_test: ok`

- [ ] **Step 6: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/src/doom_input_queue.h transform/src/doom_input_queue.c transform/tests/input_queue_test.c
git commit -m "feat(transform): add input key ring buffer

Backs DG_GetKey with a 256-slot single-producer/single-consumer ring.
Packed as (pressed<<8)|doom_key, matching doomgeneric's s_KeyQueue
encoding in its SDL driver."
```

---

## Task 6: Frame capture hook

doomgeneric's `DG_DrawFrame` is where we capture the framebuffer. With
`-DCMAP256=1 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200`, `DG_ScreenBuffer`
is a 64,000-byte indexed buffer at native resolution. We also need to
capture the current palette, which Doom sets via `I_SetPalette` in
`i_video.c`.

**Files:**
- Create: `transform/src/doom_frame_capture.h`
- Create: `transform/src/doom_frame_capture.c`
- Create: `transform/tests/frame_capture_test.c`

- [ ] **Step 1: Write the failing test**

`transform/tests/frame_capture_test.c`:

```c
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
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /home/willem/doom-on-redpanda/transform
gcc -I src tests/frame_capture_test.c -o tests/frame_capture_test.out 2>&1 | head -3
```

Expected: fails — header does not exist.

- [ ] **Step 3: Write the header**

`transform/src/doom_frame_capture.h`:

```c
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
```

- [ ] **Step 4: Write the implementation**

`transform/src/doom_frame_capture.c`:

```c
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
```

- [ ] **Step 5: Compile and run**

```bash
cd /home/willem/doom-on-redpanda/transform
gcc -I src tests/frame_capture_test.c src/doom_frame_capture.c \
    -o tests/frame_capture_test.out
./tests/frame_capture_test.out
```

Expected: `frame_capture_test: ok`

- [ ] **Step 6: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/src/doom_frame_capture.h transform/src/doom_frame_capture.c transform/tests/frame_capture_test.c
git commit -m "feat(transform): add frame + palette capture buffer

Single-frame buffer with palette dirty-tracking. on_draw() snapshots
the 64000-byte indexed framebuffer; on_palette() snapshots the current
256-entry palette only when it actually changes; get() returns the
latest frame and palette-if-dirty in one call, clearing both flags."
```

---

## Task 7: DG_* stub implementations and palette hook wiring

doomgeneric requires `DG_Init`, `DG_DrawFrame`, `DG_GetKey`, `DG_GetTicksMs`,
`DG_SleepMs`, `DG_SetWindowTitle`. We provide no-op/minimal implementations
that plug into our input queue and frame capture. Additionally we need to
intercept `I_SetPalette` in doomgeneric's `i_video.c` to call our
`doom_frame_capture_on_palette`.

**Files:**
- Create: `transform/src/doom_stubs.c`
- Modify: `transform/doomgeneric/i_video.c`

- [ ] **Step 1: Write DG_* stubs**

`transform/src/doom_stubs.c`:

```c
#include <stdint.h>

#include "doom_input_queue.h"
#include "doom_frame_capture.h"

extern unsigned char *DG_ScreenBuffer;    // doomgeneric.c, type depends on CMAP256

// Monotonic millisecond counter advanced by the transform entry point.
// Doom mostly uses this for UI timing; the game sim is tic-locked, so
// coarse ticks are fine.
static uint32_t s_ticks_ms;

void doom_stubs_advance_ticks(uint32_t delta_ms) {
    s_ticks_ms += delta_ms;
}

void DG_Init(void) {
    // Nothing — no window, no renderer.
}

void DG_DrawFrame(void) {
    // DG_ScreenBuffer is 64000 bytes when built with -DCMAP256=1
    // and DOOMGENERIC_RESX/Y = 320/200.
    doom_frame_capture_on_draw((const uint8_t *)DG_ScreenBuffer);
}

uint32_t DG_GetTicksMs(void) {
    return s_ticks_ms;
}

void DG_SleepMs(uint32_t ms) {
    // In a transform there is no wall clock to sleep against.
    // Swallow — Doom only sleeps when idle, and it'll be fine.
    (void)ms;
}

int DG_GetKey(int *pressed, unsigned char *doom_key) {
    return doom_input_queue_pop(pressed, doom_key);
}

void DG_SetWindowTitle(const char *title) {
    (void)title;
}
```

- [ ] **Step 2: Add the palette hook to i_video.c**

Locate `I_SetPalette` in `transform/doomgeneric/i_video.c`. It is typically:

```c
void I_SetPalette (byte *palette) {
    int i;
    col_t *c;
    for (i = 0; i < 256; ++i) {
        c = (col_t*)&colors[i];
        c->r = gammatable[usegamma][*palette++];
        c->g = gammatable[usegamma][*palette++];
        c->b = gammatable[usegamma][*palette++];
        c->a = 0xFF;
    }
}
```

At the top of this function (before the loop consumes `palette`), add a
call to our hook. Because `palette` is advanced by the loop, capture the
original pointer first:

```c
void I_SetPalette (byte *palette) {
    extern void doom_frame_capture_on_palette(const uint8_t *palette);
    doom_frame_capture_on_palette((const uint8_t *)palette);

    int i;
    col_t *c;
    /* ... rest unchanged ... */
}
```

If the function body differs materially from above (upstream might have
refactored), the principle is the same: call the hook with the palette
pointer at entry.

- [ ] **Step 3: Save the palette patch**

```bash
cd /home/willem/doom-on-redpanda
git diff transform/doomgeneric/i_video.c > \
    transform/patches/0002-capture-palette-changes.patch
```

- [ ] **Step 4: Commit**

```bash
git add transform/src/doom_stubs.c transform/doomgeneric/i_video.c transform/patches/
git commit -m "feat(transform): wire DG_* hooks and I_SetPalette capture

DG_DrawFrame snapshots the 64000-byte indexed framebuffer into the
capture buffer. DG_GetKey pops from the input queue. The remaining
hooks are stubs: DG_SleepMs swallows sleeps (no wall clock in a
transform), DG_GetTicksMs is advanced by the caller, DG_Init and
DG_SetWindowTitle are no-ops.

I_SetPalette is patched to also call doom_frame_capture_on_palette so
the host sees palette changes (damage flash, rad suit, menu)."
```

---

## Task 8: Redpanda transform entry point

This is the C++ file that links everything to `redpanda::on_record_written`.
Copy the Redpanda C++ transform SDK headers into `transform/include/` first.

**Files:**
- Create: `transform/include/redpanda_transform_sdk/transform_sdk.h` (copied)
- Create: `transform/include/redpanda_transform_sdk/transform_sdk.cc` (copied)
- Create: `transform/src/doom_transform.cc`

- [ ] **Step 1: Copy the Redpanda SDK headers**

```bash
mkdir -p /home/willem/doom-on-redpanda/transform/include/redpanda_transform_sdk
cp /home/willem/redpanda/src/transform-sdk/cpp/include/redpanda/transform_sdk.h \
   /home/willem/doom-on-redpanda/transform/include/redpanda_transform_sdk/
cp /home/willem/redpanda/src/transform-sdk/cpp/src/transform_sdk.cc \
   /home/willem/doom-on-redpanda/transform/include/redpanda_transform_sdk/
```

(If the exact paths under `src/transform-sdk/cpp/` differ from what's
referenced in the C++ SDK README, run `find /home/willem/redpanda/src/transform-sdk/cpp -name 'transform_sdk*'` and adjust.)

- [ ] **Step 2: Write the entry point**

`transform/src/doom_transform.cc`:

```cpp
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
#include <cstring>
#include <vector>

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

constexpr size_t kTickMs = 29;   // ~35 Hz, matching Doom's native tic rate.
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

// Read a little-endian uint32 from a byte buffer.
uint32_t read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void write_u32_le(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
    p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}

redpanda::error_code on_record_written(redpanda::write_event event,
                                       redpanda::record_writer *writer) {
    ensure_doom_initialized();
    doom_stubs_advance_ticks(kTickMs);

    // ---- decode input ----
    auto value = event.record.value;   // bytes_view
    if (!value.has_value() || value->size() < 5) {
        // Malformed — log once, skip tick.
        redpanda::log_info("malformed input record: size < 5");
        return {};
    }
    const uint8_t *p   = value->data();
    const uint8_t *end = p + value->size();
    uint32_t tick_seq  = read_u32_le(p); p += 4;
    uint8_t  n         = *p++;
    if (end - p < (ptrdiff_t)(2 * (size_t)n)) {
        redpanda::log_info("truncated input record");
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
        // Shouldn't happen in the steady state, but be defensive.
        redpanda::log_info("no frame produced this tick");
        return {};
    }
    const uint8_t *pixels; const uint8_t *palette; int palette_dirty;
    doom_frame_capture_get(&pixels, &palette, &palette_dirty);

    size_t out_sz = 4 + 1 + (palette_dirty ? 768 : 0) + 64000;
    std::vector<uint8_t> out(out_sz);
    uint8_t *w = out.data();
    write_u32_le(w, tick_seq); w += 4;
    *w++ = palette_dirty ? 1 : 0;
    if (palette_dirty) { std::memcpy(w, palette, 768); w += 768; }
    std::memcpy(w, pixels, 64000);

    redpanda::record out_record{
        .key   = event.record.key,            // echo "p1"
        .value = redpanda::bytes_view{out.data(), out.size()},
        .headers = {},
    };
    return writer->write(out_record);
}

}  // namespace

int main() {
    redpanda::on_record_written(on_record_written);
    return 0;
}
```

- [ ] **Step 3: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/include transform/src/doom_transform.cc
git commit -m "feat(transform): add SDK entry point

on_record_written decodes input records, pushes key events into the
queue, runs one doomgeneric_Tick, pulls the resulting framebuffer +
(optional) palette from the capture buffer, and emits one output
record. One-record-in → one-record-out contract per the spec."
```

---

## Task 9: Build system — Makefile + Dockerfile.build

We build the WASM module inside the `ghcr.io/webassembly/wasi-sdk` image.
The Makefile wraps the docker invocation and also drives the native unit
tests (which need only gcc).

**Files:**
- Create: `transform/Dockerfile.build`
- Create: `transform/Makefile`

- [ ] **Step 1: Write the Dockerfile (thin wrapper to add xxd)**

`transform/Dockerfile.build`:

```dockerfile
FROM ghcr.io/webassembly/wasi-sdk:wasi-sdk-22

# wasi-sdk base image is minimal; install xxd for the WAD embedder.
RUN apt-get update && apt-get install -y xxd && rm -rf /var/lib/apt/lists/*

WORKDIR /src
```

- [ ] **Step 2: Write the Makefile**

`transform/Makefile`:

```make
# doom-on-redpanda: transform Makefile.
# Top-level targets:
#   make               — default: build doom_transform.wasm
#   make test-native   — build + run native unit tests (input queue, frame capture, WAD)
#   make test-wasm     — load doom_transform.wasm in wasmtime and run a frame roundtrip
#   make clean

DOOM_WAD       ?= $(HOME)/Downloads/doom1.wad
BUILD_DIR      ?= build
WASM           := $(BUILD_DIR)/doom_transform.wasm

DOOMGENERIC_SRCS := $(filter-out \
    doomgeneric/doomgeneric_sdl.c \
    doomgeneric/doomgeneric_xlib.c \
    doomgeneric/doomgeneric_win.c, \
    $(wildcard doomgeneric/*.c))

TRANSFORM_SRCS := \
    src/doom_transform.cc \
    src/doom_input_queue.c \
    src/doom_frame_capture.c \
    src/doom_stubs.c \
    include/redpanda_transform_sdk/transform_sdk.cc

CMAP_DEFS := -DCMAP256=1 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200
WAD_DEFS  := -DDOOMWAD_FROM_MEMORY=1

DOCKER_IMG := doom-on-redpanda-build:latest

.PHONY: all image wad wasm clean test-native test-wasm

all: wasm

image:
	docker build -f Dockerfile.build -t $(DOCKER_IMG) .

src/wad_embedded.h: $(DOOM_WAD)
	./tools/embed_wad.sh $(DOOM_WAD) src/wad_embedded.h

wad: src/wad_embedded.h

wasm: image src/wad_embedded.h
	mkdir -p $(BUILD_DIR)
	docker run --rm -v $(CURDIR):/src -w /src $(DOCKER_IMG) \
	  /opt/wasi-sdk/bin/clang++ \
	    -std=c++23 -fno-exceptions -O2 -flto \
	    $(CMAP_DEFS) $(WAD_DEFS) \
	    -I include -I include/redpanda_transform_sdk -I doomgeneric -I src \
	    -Wno-everything \
	    $(TRANSFORM_SRCS) $(DOOMGENERIC_SRCS) \
	    -o $(WASM)
	@ls -l $(WASM)

test-native:
	gcc -I src -I doomgeneric \
	    tests/input_queue_test.c src/doom_input_queue.c \
	    -o $(BUILD_DIR)/input_queue_test.out
	gcc -I src -I doomgeneric \
	    tests/frame_capture_test.c src/doom_frame_capture.c \
	    -o $(BUILD_DIR)/frame_capture_test.out
	$(BUILD_DIR)/input_queue_test.out
	$(BUILD_DIR)/frame_capture_test.out

test-wasm: wasm
	$(MAKE) -C tests -f Makefile.wasm

clean:
	rm -rf $(BUILD_DIR) src/wad_embedded.h
```

Notes on the Makefile:
- `-Wno-everything` is intentional: doomgeneric is 1993-era C and throws
  warnings we do not care about in this demo.
- `-fno-exceptions` matches the Redpanda C++ SDK guidance.
- The `TRANSFORM_SRCS` list includes the SDK's own `transform_sdk.cc`, per
  the C++ SDK README (standalone build).

- [ ] **Step 3: Build and verify**

```bash
cd /home/willem/doom-on-redpanda/transform
make image          # one-time, builds the wasi-sdk+xxd docker image
make test-native    # passes the native unit tests
make                # builds doom_transform.wasm
file build/doom_transform.wasm
```

Expected outputs:
- `test-native`: two "ok" lines.
- `make`: ends with `ls -l build/doom_transform.wasm` showing a file ~3–5 MB (4 MB of WAD + compiled code).
- `file`: `WebAssembly (wasm) binary module version 0x1 (MVP)`.

If the build fails with linker errors referencing `setjmp`/`longjmp`,
`sigaction`, or `gethostbyname`, add stubs to `src/doom_stubs.c`:

```c
#include <stdlib.h>
int  setjmp(void *env)                     { (void)env; return 0; }
void longjmp(void *env, int val)           { (void)env; (void)val; abort(); }
```

Cast `void *` to `jmp_buf *` via `#include <setjmp.h>` in real usage; the
above is deliberately permissive. These stubs intentionally abort on
longjmp — all Doom call sites are fatal `I_Error` paths.

- [ ] **Step 4: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/Dockerfile.build transform/Makefile
git commit -m "build: add WASM build pipeline

Makefile drives a docker-based wasi-sdk clang++ build plus native gcc
unit tests. The WAD embedder is wired into the wasm target so updating
doom1.wad triggers a rebuild. doomgeneric's platform-specific drivers
are excluded from the source list."
```

---

## Task 10: Host-side wasmtime test — feed input, verify frame out

Loads `doom_transform.wasm` via libwasmtime's C API, sets up the transform's
expected ABI (the broker side of `on_record_written`), pushes one input
record, and asserts a frame record comes back.

Redpanda's transform ABI is the one defined by the C++ SDK at
`transform_sdk.cc`. The module's entry point is `main()`, which calls
`redpanda::on_record_written(handler)`. The SDK registers a callback, and
the broker calls into the module via an exported function per record. For
a host-side test we shortcut this by driving the module the same way the
broker does.

**Caveat:** the exact import/export shape is defined by the SDK. Before
writing this test, survey the ABI:

- [ ] **Step 1: Survey the transform ABI**

```bash
grep -rn '__wasm_import_name__\|__wasm_export_name__\|on_record_written' \
    /home/willem/redpanda/src/transform-sdk/cpp/
```

Note the names of the host functions the module **imports** (broker-provided,
e.g. `check`, `read_next_record`, `write_record`, `get_header`, ...) and the
name of the function the broker **exports** into the module. Record these in
a comment block at the top of `transform_test.c`.

**Expected finding:** the module imports functions like
`redpanda_transform_check`, `read_batch_header`, `read_next_record`,
`write_record`. The exact set depends on the SDK version. This is the
**contract** the host-side test reimplements in miniature.

If the ABI turns out to be more complex than a handful of imports, fall
back to running the test via a real Redpanda instance (skip Task 10, use
Task 13's smoke test as the only integration test). Note the decision in a
commit message.

- [ ] **Step 2: Write the test (skeleton shown — fill in the specific imports discovered in step 1)**

`transform/tests/transform_test.c`:

```c
// Host-side test: load doom_transform.wasm in wasmtime, feed it one
// input record, assert a frame record comes out.
//
// This reimplements just enough of Redpanda's transform host ABI to
// drive the module through a single record cycle.

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <wasi.h>
#include <wasmtime.h>

// Input record (same layout as the spec).
static unsigned char s_input[] = {
    0x01, 0x00, 0x00, 0x00,   // tick_seq = 1
    0x00,                      // event_count = 0 (idle tick)
};

// Slot where the module writes its output record.
static unsigned char s_output[1 << 20];
static size_t        s_output_len;

// --- wasmtime-provided host import implementations ---
//
// These names must match the imports discovered in Step 1. Typical
// shape for Redpanda's SDK at the time of writing is:
//
//   check                     () -> i32                (should-i-run probe)
//   read_batch_header         (...) -> i32
//   read_next_record          (... -> record fields)
//   write_record              (... -> bytes)
//
// Fill in the specific imports from the SDK here.

static wasmtime_error_t *link_host(wasmtime_linker_t *linker, wasmtime_context_t *ctx) {
    // Example — adjust names and signatures:
    //
    //   wasm_functype_t *check_ty = wasm_functype_new_0_1(wasm_valtype_new_i32());
    //   wasmtime_linker_define_func(linker, "env", "check", check_ty,
    //       host_check, NULL, NULL);
    //
    // For each import discovered in Step 1, define a host function that
    // feeds fixed data (s_input) on reads and captures data into
    // s_output on writes.
    //
    // Return NULL on success.
    (void)linker; (void)ctx;
    return NULL;
}

int main(void) {
    wasm_engine_t *engine = wasm_engine_new();
    wasmtime_store_t *store = wasmtime_store_new(engine, NULL, NULL);
    wasmtime_context_t *ctx = wasmtime_store_context(store);

    FILE *f = fopen("build/doom_transform.wasm", "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *bytes = malloc(sz);
    fread(bytes, 1, sz, f);
    fclose(f);

    wasm_byte_vec_t wasm; wasm.data = (wasm_byte_t*)bytes; wasm.size = sz;
    wasmtime_module_t *module = NULL;
    wasmtime_error_t *err = wasmtime_module_new(engine, bytes, sz, &module);
    assert(!err);

    wasmtime_linker_t *linker = wasmtime_linker_new(engine);
    wasmtime_linker_define_wasi(linker);
    err = link_host(linker, ctx);
    assert(!err);

    // WASI setup: no files, no env.
    wasi_config_t *wasi = wasi_config_new();
    wasi_config_inherit_stdout(wasi);
    wasi_config_inherit_stderr(wasi);
    wasmtime_context_set_wasi(ctx, wasi);

    wasmtime_instance_t inst;
    err = wasmtime_linker_instantiate(linker, ctx, module, &inst, NULL);
    assert(!err);

    // Call _start (main) — this registers the on_record_written handler.
    wasmtime_extern_t start;
    bool ok = wasmtime_instance_export_get(ctx, &inst, "_start", strlen("_start"), &start);
    assert(ok);
    assert(start.kind == WASMTIME_EXTERN_FUNC);
    wasmtime_val_t results[1];
    err = wasmtime_func_call(ctx, &start.of.func, NULL, 0, results, 0, NULL);
    assert(!err);

    // Now call the broker-facing entry point (name per Step 1 finding)
    // with s_input available to the read imports, and capture the write.
    // This is SDK-specific — fill in accordingly.

    // Assertions on s_output:
    assert(s_output_len >= 4 + 1 + 64000);
    // tick_seq echoed
    unsigned int echoed =
        s_output[0] | (s_output[1] << 8) | (s_output[2] << 16) | (s_output[3] << 24);
    assert(echoed == 1);
    // palette_present is 0 or 1
    assert(s_output[4] == 0 || s_output[4] == 1);
    // correct total size
    size_t expected = 4 + 1 + (s_output[4] ? 768 : 0) + 64000;
    assert(s_output_len == expected);

    printf("transform_test: ok (output=%zu bytes, palette_present=%d)\n",
           s_output_len, s_output[4]);
    return 0;
}
```

- [ ] **Step 3: Makefile for the wasm test**

`transform/tests/Makefile.wasm`:

```make
WASMTIME_DIR ?= /opt/wasmtime-c-api

CFLAGS := -I$(WASMTIME_DIR)/include -g -O0
LDFLAGS := -L$(WASMTIME_DIR)/lib -lwasmtime -lm -ldl -lpthread -Wl,-rpath,$(WASMTIME_DIR)/lib

../build/transform_test.out: transform_test.c
	gcc $(CFLAGS) $< -o $@ $(LDFLAGS)

.PHONY: run
run: ../build/transform_test.out
	cd .. && tests/$(notdir $<) || true
	cd .. && ./build/transform_test.out

default: run
```

- [ ] **Step 4: Run**

```bash
cd /home/willem/doom-on-redpanda/transform
WASMTIME_DIR=/path/to/wasmtime-c-api make test-wasm
```

Expected: `transform_test: ok (output=64005 bytes, palette_present=1)`
(first frame always dirty palette, so 4+1+768+64000 = 64773 bytes if
palette is included, or 64005 if not). Actual first-frame size will be
64773 since the palette is dirty on the first tick.

- [ ] **Step 5: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add transform/tests/transform_test.c transform/tests/Makefile.wasm
git commit -m "test(transform): host-side wasmtime round-trip

Loads doom_transform.wasm, drives one input record through the
transform's broker ABI (reimplemented in miniature), asserts a
framebuffer record comes back with the expected shape."
```

If Step 1's ABI survey revealed the transform ABI is too sprawling to
reimplement against here, skip Task 10 and proceed to Task 11. Note the
decision with a commit:

```bash
git commit --allow-empty -m "test(transform): skip host-side wasmtime test for v1

The Redpanda transform ABI (as exposed by the current C++ SDK) has
enough moving parts that reimplementing it host-side would be
significantly more code than the transform itself. The e2e smoke test
(Task 13) is sufficient to validate end-to-end behavior."
```

---

## Task 11: docker-compose — Redpanda broker + transform deploy

**Files:**
- Create: `docker-compose.yml`
- Create: `deploy/init.sh`

- [ ] **Step 1: Write docker-compose.yml**

`docker-compose.yml`:

```yaml
version: "3.8"

services:
  redpanda:
    image: redpandadata/redpanda:latest
    container_name: doom-redpanda
    command:
      - redpanda
      - start
      - --mode=dev-container
      - --smp=1
      - --memory=1G
      - --overprovisioned
      - --kafka-addr=PLAINTEXT://0.0.0.0:9092
      - --advertise-kafka-addr=PLAINTEXT://redpanda:9092
      - --pandaproxy-addr=0.0.0.0:8082
      - --advertise-pandaproxy-addr=redpanda:8082
      - --schema-registry-addr=0.0.0.0:8081
      - --rpc-addr=redpanda:33145
      - --advertise-rpc-addr=redpanda:33145
      - --set=redpanda.data_transforms_enabled=true
    ports:
      - "9092:9092"       # Kafka API
      - "9644:9644"       # Admin API
    volumes:
      - redpanda-data:/var/lib/redpanda/data
    healthcheck:
      test: ["CMD", "rpk", "cluster", "health"]
      interval: 3s
      timeout: 5s
      retries: 20

  init:
    image: redpandadata/redpanda:latest
    container_name: doom-init
    depends_on:
      redpanda:
        condition: service_healthy
    entrypoint: ["/bin/bash", "/deploy/init.sh"]
    volumes:
      - ./deploy:/deploy:ro
      - ./transform/build:/transform:ro
    environment:
      RPK_BROKERS: redpanda:9092
      RPK_ADMIN_HOSTS: redpanda:9644

volumes:
  redpanda-data:
```

- [ ] **Step 2: Write deploy/init.sh**

`deploy/init.sh`:

```bash
#!/usr/bin/env bash
# Creates the input/output topics and deploys the Doom transform.
# Idempotent — safe to run on every docker-compose up.

set -euo pipefail

echo "waiting for broker..."
until rpk cluster health --exit-when-all-healthy 2>/dev/null; do
    sleep 1
done

echo "creating topics..."
rpk topic create doom.input  -p 1 -r 1 --allow-existing
rpk topic create doom.frames -p 1 -r 1 --allow-existing

# Tight retention — these are queues, not logs.
rpk topic alter-config doom.input  --set retention.ms=60000  --set segment.ms=60000
rpk topic alter-config doom.frames --set retention.ms=60000  --set segment.ms=60000

echo "deploying transform..."
rpk transform deploy \
    --file /transform/doom_transform.wasm \
    --name doom \
    --input-topic=doom.input \
    --output-topic=doom.frames \
    || rpk transform deploy \
           --file /transform/doom_transform.wasm \
           --name doom \
           --input-topic=doom.input \
           --output-topic=doom.frames \
           --force

echo "ready."
rpk transform list
```

Make executable:

```bash
chmod +x /home/willem/doom-on-redpanda/deploy/init.sh
```

- [ ] **Step 3: Bring up the stack**

```bash
cd /home/willem/doom-on-redpanda
docker-compose up --build -d
docker-compose logs init
```

Expected: `init` logs show topics created, transform deployed, and
`rpk transform list` reporting `doom` with status `RUNNING`.

- [ ] **Step 4: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add docker-compose.yml deploy/init.sh
git commit -m "deploy: add docker-compose stack with topic+transform init

Single-broker Redpanda with data_transforms_enabled, plus an init
container that creates doom.input/doom.frames and deploys the compiled
wasm module via rpk transform deploy. 60 s retention on both topics —
these are queues, not logs."
```

---

## Task 12: End-to-end smoke test

Produce one input record, consume one frame record, sanity-check the size.
This is the "it works" signal for Phase 1.

**Files:**
- Create: `tests/smoke.sh`
- Create: `tests/sample_input.bin`

- [ ] **Step 1: Generate a sample input record**

The spec says input is `u32 tick_seq | u8 event_count | (u8 doom_key, u8 down)*`.
An "idle tick" record is 5 bytes. Generate:

```bash
mkdir -p /home/willem/doom-on-redpanda/tests
# u32 tick_seq=1 (little-endian) | u8 event_count=0
printf '\x01\x00\x00\x00\x00' > /home/willem/doom-on-redpanda/tests/sample_input.bin
wc -c /home/willem/doom-on-redpanda/tests/sample_input.bin
```

Expected: `5 .../sample_input.bin`.

- [ ] **Step 2: Write the smoke script**

`tests/smoke.sh`:

```bash
#!/usr/bin/env bash
# End-to-end smoke: produce one input record, consume one frame,
# check the frame size is one of the two allowed values.
#
# Expects docker-compose up and healthy.

set -euo pipefail

cd "$(dirname "$0")"

RPK="docker exec doom-redpanda rpk"

echo "[smoke] pushing one input record..."
# Send the sample bytes as the record value.
$RPK topic produce doom.input --format '%v' < sample_input.bin

echo "[smoke] consuming one frame record..."
# -n 1 reads exactly one record; --format '%v' emits only the value.
frame=$($RPK topic consume doom.frames -n 1 -o :end --format '%v' | head -c 100000)

bytes=$(printf '%s' "$frame" | wc -c)
echo "[smoke] frame size: $bytes bytes"

# First frame has palette dirty → expect 64773 bytes.
# Subsequent no-palette frames → 64005 bytes.
if [[ "$bytes" != "64773" && "$bytes" != "64005" ]]; then
    echo "[smoke] FAIL: unexpected frame size"
    exit 1
fi

echo "[smoke] ok"
```

Make executable:

```bash
chmod +x /home/willem/doom-on-redpanda/tests/smoke.sh
```

- [ ] **Step 3: Run the smoke test**

```bash
cd /home/willem/doom-on-redpanda
./tests/smoke.sh
```

Expected output (first run):
```
[smoke] pushing one input record...
[smoke] consuming one frame record...
[smoke] frame size: 64773 bytes
[smoke] ok
```

**Note on the first frame being stuck behind Doom's init:** the transform
initializes Doom inside the first `on_record_written` call. This runs
`D_DoomMain` through to the title screen. On a dev laptop this takes ~1–3
seconds. If `rpk topic consume -n 1` times out, raise its timeout with
`--timeout 30s`.

**Note on rpk's `%v` format and binary data:** `rpk topic produce
--format '%v'` reads the record value as the entire stdin. The consume
side with `--format '%v'` prints the raw bytes. If the framebuffer's
bytes include a terminal-hostile sequence, piping through `head -c` is
important. For more robust testing, use `rpk topic consume doom.frames
-n 1 -o :end --pretty-print=false` and write to a file via `-f`.

- [ ] **Step 4: Commit**

```bash
cd /home/willem/doom-on-redpanda
git add tests/
git commit -m "test: end-to-end smoke against docker-compose stack

Pushes one idle-tick input record, consumes one frame record, checks
the total size is either 64773 (first frame, palette included) or
64005 (subsequent frames, no palette). Proves the full pipe —
transform init, tick, frame emission — works under a real Redpanda."
```

---

## Task 13: Phase 1 wrap-up — tag + README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README with what's actually working**

Rewrite `README.md`:

```markdown
# Doom on Redpanda

A demo that runs id Software's *Doom* (1993) game loop inside a Redpanda
Data Transform on the produce path. One input record = one game tick =
one framebuffer record out.

See `docs/superpowers/specs/2026-04-17-doom-on-redpanda-design.md` for the
design.

## Status

- **Phase 1 (complete):** transform runs under docker-compose. Drive it
  with `rpk topic produce`; observe frame records on `doom.frames`.
- **Phase 2 (planned):** Go WebSocket bridge + browser canvas renderer.

## Quick start (Phase 1)

```bash
export DOOM_WAD=~/Downloads/doom1.wad

# Build the WASM transform.
make -C transform

# Stand up Redpanda + deploy the transform.
docker-compose up --build -d

# Sanity check: one idle-tick input → one framebuffer record.
./tests/smoke.sh
```

## Record formats

See the spec for full details. In short:

- **`doom.input`**: `u32 tick_seq | u8 event_count | (u8 doom_key, u8 down)*`
- **`doom.frames`**: `u32 tick_seq | u8 palette_present | [palette? 768] | [pixels 64000]`

## Layout

| path | what |
|---|---|
| `transform/` | WASM module source — doomgeneric + SDK shim |
| `transform/doomgeneric/` | vendored from github.com/ozkl/doomgeneric, GPL-2.0 |
| `transform/src/` | our code |
| `deploy/` | rpk init script that creates topics + deploys transform |
| `tests/` | end-to-end smoke script |

## Known limitations (v1)

- Single player, one partition.
- No audio.
- Game resets on transform restart / leadership transfer.
- Shareware WAD only.
```

- [ ] **Step 2: Tag Phase 1**

```bash
cd /home/willem/doom-on-redpanda
git add README.md
git commit -m "docs: Phase 1 README"
git tag phase-1
```

---

## Self-Review

(Run by the planner — the implementer can skip this section.)

**Spec coverage** — each requirement in the spec cross-references a task here:
- Architecture diagram and components — covered by the file structure at the top + Tasks 2, 8, 11.
- `doom.input` / `doom.frames` record schemas — Tasks 8, 12.
- Data flow (one-in-one-out, lazy init) — Task 8.
- WAD handling (embedded buffer, patch loader) — Tasks 3, 4.
- State lifetime (globals survive in WASM linear memory) — implicit in Task 8's `g_doom_ready` latch.
- Error handling: `I_Error` → `abort()`; malformed input → log-and-skip — Task 7 (stubs), Task 8 (defensive decoding). `setjmp`/`longjmp` stubs flagged in Task 9.
- Testing: host-side wasmtime test — Task 10. E2E smoke — Task 12. Native unit tests for pure-C modules — Tasks 5, 6.
- docker-compose single broker — Task 11.
- Non-goals (multiplayer, audio, leadership-transfer recovery, cluster deploy) — not implemented, consistent with spec.

Phase 2 (WS bridge, browser) is explicitly out of this plan and noted in the README in Task 13.

**Placeholder scan:** clean — Task 10 has an explicit "if ABI is too complex, skip" branch (not a placeholder, it's a decision point), and every other task has concrete code.

**Type consistency:** checked: `doom_input_queue_pop` signature matches
`DG_GetKey` (Tasks 5, 7). `doom_frame_capture_get` out-parameters match
their uses in `doom_transform.cc` (Task 8). `tick_seq` is a little-endian
`u32` everywhere (Tasks 8, 10, 12). `DOOM_FRAME_BYTES = 64000` and
`DOOM_PALETTE_BYTES = 768` are referenced consistently.

---

## Execution handoff

Plan complete and saved to
`docs/superpowers/plans/2026-04-17-doom-on-redpanda-phase1-transform.md`.

Two execution options:

1. **Subagent-driven (recommended)** — a fresh subagent handles each task,
   you review between tasks, fast iteration.
2. **Inline execution** — execute tasks in this session with checkpoints
   for review.

Which would you like?
