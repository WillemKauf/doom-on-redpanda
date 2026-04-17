# Doom on Redpanda — Design

- **Date:** 2026-04-17
- **Status:** Draft (pending user review)
- **Author:** Willem Kaufmann

## Summary

A single-player demo that runs the id Software *Doom* (1993) game loop inside a
Redpanda Data Transform on the produce path. A browser publishes input records
at 35 Hz, the transform advances one game tick per record and emits a 320×200
framebuffer record, and a Go WebSocket bridge forwards frames back to the
browser for rendering.

The interesting bit is that the game state lives in WebAssembly linear memory
inside the broker, clocked by messages on the produce path, with "one input
record in → one frame record out" as the transform's entire contract.

## Motivation

Redpanda Data Transforms are usually used for record-level ETL: filtering,
redaction, enrichment. This demo stretches the model to its conceptual limit by
treating the transform as a long-lived stateful process whose clock is the
input topic itself. It is a useful pedagogical artifact — it makes the "WASM
module is per-partition, per-shard, persists across invocations" property
concrete — and a fun conference/blog demo.

## Non-goals (v1)

- **Multiplayer.** One partition, one player. Multi-player is a trivial
  partition-keying extension but is out of scope for v1.
- **Audio.** Doom's mixer is self-contained; adding a second record type later
  does not require a redesign.
- **State survival across leadership transfer.** If the partition's leader
  moves, the WASM instance cold-inits and the player sees the intro screen
  again. Acceptable for a single-broker demo.
- **Running against a production cluster.** Target environment is
  docker-compose on a dev laptop.
- **Real Doom netcode.** The browser is not a Doom peer. It is a dumb input
  producer and a dumb frame consumer.
- **Frame compression / delta frames.** 2.2 MB/s over localhost is not a
  problem worth optimizing.

## Architecture

```
┌──────────────────┐   doom.input     ┌──────────────────────────┐   doom.frames    ┌──────────────────┐
│   browser.html   │ ───────────────▶ │  Redpanda broker + WASM  │ ───────────────▶ │   ws-bridge      │
│ (canvas + 35 Hz  │                  │  transform runtime       │                  │ (Go, franz-go)   │
│  input ticker)   │                  │  ─ doomgeneric.wasm ─    │                  │                  │
│                  │                  │                          │                  │                  │
└─────────▲────────┘                  └──────────────────────────┘                  └────────┬─────────┘
          │                                                                                  │
          │         WebSocket (frames down, input up)                                        │
          └──────────────────────────────────────────────────────────────────────────────────┘
```

### Components

1. **`doom_transform`** — C source tree: [doomgeneric](https://github.com/ozkl/doomgeneric)
   plus a `doomgeneric_redpanda.c` shim linked against the Redpanda C++
   transform SDK (`src/transform-sdk/cpp/`). Compiled to `wasm32-wasi` via
   wasi-sdk. Single entry point: `on_record_written(event, writer)` runs one
   `doomgeneric_Tick()` per input record.

2. **`ws-bridge`** — Go process using
   [franz-go](https://github.com/twmb/franz-go) as the Kafka client and
   `nhooyr.io/websocket` for the browser socket. Three responsibilities:
   - Serves the static `index.html` + JS.
   - Produces input records from the browser's WS messages to `doom.input`.
   - Consumes frame records from `doom.frames` and forwards them over the WS.

3. **`browser`** — static HTML + vanilla JS (no framework). Maintains a
   WebSocket, a keydown/keyup buffer, a 35 Hz `setInterval` that flushes the
   buffer as an input record, and a `<canvas>` that draws incoming frames via
   `ImageData`.

4. **Topics** — created at stack start by `rpk topic create`:
   - `doom.input` — 1 partition, retention 1 minute (just a queue).
   - `doom.frames` — 1 partition, retention 1 minute.

5. **`docker-compose.yml`** — three services: one `redpanda` broker, one
   `ws-bridge` container, one `init` container that runs `rpk topic create`
   and `rpk transform deploy` once on startup.

### Toolchain

- **WASM build:** [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) via the
  `ghcr.io/webassembly/wasi-sdk` Docker image. Build command (from the C++
  SDK README):
  ```
  $CXX $CXX_FLAGS -std=c++23 -fno-exceptions -O3 -flto \
       -Iinclude doom_transform.cc src/transform_sdk.cc \
       <doomgeneric sources>
  ```
- **Bridge build:** `go build` against franz-go + `nhooyr.io/websocket`.
- **Deploy:** `rpk transform deploy --file doom_transform.wasm \
  --input-topic=doom.input --output-topic=doom.frames`.

## Record schemas

All fields little-endian, hand-rolled packed binary.

### `doom.input`

```
value layout:
  u32  tick_seq         // monotonic, browser-assigned
  u8   event_count
  repeat event_count times:
    u8 doom_key          // DOS scancode (KEY_UPARROW, KEY_FIRE, ...)
    u8 down              // 1 = keydown, 0 = keyup
key: "p1"               // fixed player id for v1
```

### `doom.frames`

```
value layout:
  u32     tick_seq            // echoed from the input that produced this frame
  u8      palette_present     // 1 if palette follows, else 0
  [768]   palette             // only if palette_present == 1: 256 RGB triplets
  [64000] pixels              // 320*200 bytes of 8-bit indexed pixel data
key: "p1"
```

Palette is included on the first frame and whenever
`I_SetPalette` is called (damage flash, rad suit, menu open). Steady-state
frames are ~64 KB.

## Data flow

Happy path for a single tick:

1. User presses `W`. Browser `keydown` handler appends
   `{scancode: KEY_UPARROW, down: 1}` to the pending events list.
2. The 35 Hz `setInterval` fires. It drains the pending events, builds an
   input record, sends it as a binary WS frame to the bridge.
3. Bridge produces the record to `doom.input` partition 0.
4. Redpanda's transform runtime invokes `on_record_written(event, writer)` on
   that shard.
   - **First call ever:** lazy-init — decompress the embedded WAD, call
     `doomgeneric_Create()`, which runs Doom's init through to the title
     screen.
   - Deserialize input record, push key events into the ring buffer read by
     our `DG_GetKey` implementation.
   - Call `doomgeneric_Tick()`. Doom internally runs one `TryRunTics` +
     `D_Display`, ending with a call to our `DG_DrawFrame`.
   - `DG_DrawFrame` writes the current `screens[0]` and (if dirty) the palette
     into the output record buffer.
   - `writer->write(frame_record)` emits it.
5. Bridge's frame consumer reads the record and forwards it over the WS.
6. Browser unpacks, indexes palette → RGBA in a typed-array loop, calls
   `ctx.putImageData`. One frame drawn.

### Invariant

**Exactly one input record in → exactly one frame record out.** This makes
`tick_seq` a reliable correlation key for debugging and means back-pressure in
either direction is handled by Redpanda's existing flow control — no
custom pacing logic.

## WAD handling

Doom requires a WAD file (`doom1.wad` shareware, ~4 MB). doomgeneric normally
reads it via `fopen`, but the Redpanda transform runtime does not expose
arbitrary WASI filesystem preopens.

**Approach:** embed the WAD as a `const uint8_t[]` in the WASM binary
(generated by a build-time `xxd -i` or equivalent) and patch
`w_wad.c:W_AddFile` to read from that buffer instead of disk. Isolated change,
one file modified.

Alternative considered: ship the WAD as a control record on `doom.input` at
startup. Rejected as more complex for no practical benefit.

## State lifetime

Doom's globals live in WASM linear memory, which the transform runtime keeps
alive across `on_record_written` invocations on the same shard. Init runs
exactly once per instance lifetime.

If the partition's leadership moves, the replacement instance cold-inits and
the player is returned to the title screen. In the docker-compose single-broker
target this essentially never happens. Documented as a v1 limitation.

## Error handling

- **Transform panics / Doom asserts:** doomgeneric's `I_Error` is stubbed to
  log via the transform SDK logger and `abort()`. The runtime restarts the
  instance; user sees the intro screen again. No retry loops — hard reset is
  the correct behavior.
- **Malformed input record:** log once, return without emitting a frame. One
  dropped tick; the browser's next tick overwrites pending state.
- **WS disconnect (browser side):** auto-reconnect with 1 s backoff. Frames
  emitted during the gap are dropped on the bridge (forwards from current
  offset on reconnect).
- **Bridge crash:** docker-compose `restart: unless-stopped`. Browser
  auto-reconnects.
- **`setjmp`/`longjmp` in Doom source:** the few call sites are all fatal
  `I_Error` bailouts. Stub them to log + `abort()`, matching the
  panic-means-restart model.

## Testing

- **Transform unit test (host-side):** a small C++ gtest that loads the
  compiled `.wasm` via the wasmtime C API, sends a hand-crafted input
  record, asserts a frame record comes back with the correct shape (`tick_seq`
  echoed, 64000 bytes of pixels, optional palette). Proves the whole loop
  without requiring a Redpanda broker.
- **End-to-end smoke test:** shell script that brings up docker-compose,
  uses `rpk topic produce` to push ~100 pre-recorded input records, uses
  `rpk topic consume` to verify ~100 frame records come back.
- **Manual eye-test:** open the browser, press keys, verify it's Doom.

### Out of scope for testing

- Frame timing accuracy (browser-driven, not our problem).
- Leadership-transfer recovery (single broker, does not occur).
- Multi-player, audio (out of scope entirely).

## Known v1 limitations

- Game resets on transform restart / leadership transfer.
- No audio.
- Single player only. (Extending to N independent players is trivial — key by
  `player_id` and let Redpanda distribute partitions.)
- Shareware WAD only. Users who want the full game replace the embedded bytes
  at build time.
- No save/load. (Would be nice as a follow-up: emit save-state as a control
  record to a third topic.)

## Future work (out of scope)

- Audio output as a second record type on `doom.frames` or its own
  `doom.audio` topic.
- Multi-player as N independent games, keyed by `player_id`.
- Frame compression (QOI) for over-the-WAN demos.
- State snapshots to a compacted topic for leadership-transfer recovery.
- A rendering-side consumer that writes frames to a file as a video (easy: one
  more consumer, ffmpeg in a pipe).

## Repository layout

Proposed structure for the `doom-on-redpanda` repo (separate from
`redpanda-data/redpanda`):

```
doom-on-redpanda/
├── README.md
├── docker-compose.yml
├── docs/superpowers/specs/2026-04-17-doom-on-redpanda-design.md  (this file)
├── transform/
│   ├── Dockerfile.build                 # wasi-sdk image
│   ├── Makefile
│   ├── doomgeneric/                     # vendored, with WAD-from-memory patch
│   ├── doom_transform.cc                # SDK entry point
│   ├── doomgeneric_redpanda.c           # DG_* hooks + key ring buffer
│   └── wad_embedded.h                   # generated: const uint8_t doom1_wad[]
├── bridge/
│   ├── Dockerfile
│   ├── go.mod
│   ├── main.go                          # franz-go + WS server
│   └── web/
│       ├── index.html
│       └── doom.js                      # input ticker + canvas renderer
└── test/
    ├── transform_test.cc                # wasmtime-loaded unit test
    └── smoke.sh                         # rpk-driven e2e
```
