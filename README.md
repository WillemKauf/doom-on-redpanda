# 🎮 Doom on Redpanda

> Play id Software's **DOOM** (1993) inside a web browser, where every
> button press is a Kafka record and every frame you see was rendered
> by a WebAssembly transform running *inside the broker*.

![status: demo](https://img.shields.io/badge/status-demo-informational)
![license: GPL--2.0](https://img.shields.io/badge/license-GPL--2.0-blue)

This is a toy — but a real one. It's actually DOOM, actually on
Redpanda, actually rendered through real Kafka records. If you've ever
wanted to feel how fast a Redpanda **data transform** can run, this
lets you feel it: the game is only playable because the transform
executes synchronously on the produce path, in roughly 1 ms per
round-trip.

---

## How it works (in one picture)

```
 ┌────────────────────────┐
 │   your browser         │
 │   ┌────────────────┐   │
 │   │     canvas     │   │ ◀── renders 320×200 framebuffer
 │   │  DOOM 320×200  │   │
 │   └────────────────┘   │
 └──────────┬─────────────┘
            │   keystrokes in / frames out
            │   (binary WebSocket)
            ▼
 ┌────────────────────────┐
 │   doom-bridge  (Go)    │
 │   WebSocket ↔ Kafka    │
 └──────────┬─────────────┘
            │   Kafka protocol
            ▼
 ┌────────────────────────┐     ┌─────────────────────────┐
 │   Redpanda broker      │ ──▶ │ WASM transform runs     │
 │   topic: "doom"        │     │ one doomgeneric_Tick()  │
 │                        │ ◀── │ and emits a framebuffer │
 └────────────────────────┘     └─────────────────────────┘
```

Three containers, one topic, one WASM module with DOOM baked in.
That's the whole demo.

---

## 🏁 Quick start

You need Docker, a shareware `doom1.wad`, and — for `MODE=sync` — a
custom Redpanda build with **produce-path transforms** (the built-in
`make broker-image` target will fetch + build it).

```bash
# 1. Get a shareware doom1.wad and point us at it.
#    (free from id — archive.org has it if you need a link:
#     https://archive.org/details/DoomsharewareEpisode )
export DOOM_WAD=~/Downloads/doom1.wad

# 2. First-time setup: fetch doomgeneric, apply patches, check the WAD.
#    Runs in a few seconds.
make setup

# 3. Fetch + build the produce-path Redpanda image. First run takes
#    30-90 minutes (cold bazel cache) and needs ~30 GB disk. Clones
#    github.com/redpanda-data/redpanda at branch ai-jam/produce-path-wasm
#    into ../redpanda-src by default.
#
#    Runs inside Docker — works on macOS and Linux, no host bazel
#    required. Skip this step if you only want to try MODE=async on
#    stock Redpanda.
make broker-image

# 4. Build the WASM transform. First build pulls the wasi-sdk image
#    (~500 MB) and takes 2-3 minutes; cached after that.
make rebuild-wasm

# 5. Start Redpanda + the init container + the bridge. ~20s.
make up

# 6. Play!
open http://localhost:8090/     # macOS
xdg-open http://localhost:8090/ # Linux
```

**Skipping `make broker-image`?** You can, as long as you play in
async mode: `make switch MODE=async`. The demo will still run against
stock Redpanda, it'll just be unplayably stuttery. That's useful for
demonstrating *why* produce-path matters, though.

**Build fails with "does not depend on a module exporting …" errors?**
The produce-path branch is a DNM branch that wasn't CI-tested on ARM,
so some of its BUILD files carry incomplete dep declarations that clang
catches only on non-x86_64 platforms (notably Apple Silicon Macs
building inside Docker). Bypass the strict-deps layering check for the
build:

```bash
BAZEL_EXTRA_FLAGS='--features=-layering_check' make broker-image
```

The binaries are semantically sound — `layering_check` is a build-
hygiene lint, not a correctness gate. More knobs (cache reset, OOM
recovery, etc.) in the macOS sizing notes below.

### Redpanda developers: skip the Docker wrapper

If you already have a Redpanda source tree and a working bazel setup,
you can build natively: `make broker-image-native REDPANDA_DIR=~/co/redpanda`.
By default this uses whatever branch is currently checked out in
`REDPANDA_DIR` — it won't touch your working state. To force-fetch the
produce-path branch (as `make broker-image` does for fresh clones),
set `REDPANDA_FETCH=1`.

### macOS: Docker Desktop sizing

Give Docker Desktop **≥ 24 GB RAM** and **≥ 60 GB disk** for a smooth
build. **16 GB is the absolute minimum** — Redpanda compile actions
peak at 2–4 GB each and bazel's default `--jobs` scales with container
cores, so allocations below ~24 GB can OOM-kill the bazel server
mid-build.

If your host is memory-constrained, cap parallelism before running
`make broker-image`:

```bash
BAZEL_JOBS=2 make broker-image     # safe at 8 GB
BAZEL_JOBS=4 make broker-image     # safe at 16 GB
# or let bazel pick jobs itself from a RAM budget (MiB):
BAZEL_RAM_MB=6000 make broker-image
```

If a previous build was OOM-killed or aborted mid-compile, the bazel
action cache on the volume can end up inconsistent and reject correct
source with strict-deps errors that don't match your BUILDs. Force a
clean rebuild:

```bash
BAZEL_CLEAN=all make broker-image        # full rebuild, keeps deps
BAZEL_CLEAN=expunge make broker-image    # also re-download deps
```

For any other one-off bazel flags (notably: disabling clang-modules
strict-deps checks on a DNM branch that wasn't CI-tested on your
platform), use `BAZEL_EXTRA_FLAGS`:

```bash
BAZEL_EXTRA_FLAGS='--features=-layering_check' make broker-image
```

The bazel output base lives in a Docker named volume called
`rp-bazel-cache` (~30 GB cold). Nuke with `docker volume rm
rp-bazel-cache` to reclaim the space.

Click the canvas to give it keyboard focus, then `arrow keys` /
`ctrl` / `space` / `enter`. Standard DOOM controls.

If something looks stuck:

```bash
make status     # what's running; transform state; produce-path on/off
make logs       # live broker + bridge logs
```

---

## 🎛️ Controls in the browser

| key                      | action                |
|--------------------------|-----------------------|
| arrow keys               | move / turn           |
| `ctrl`                   | fire                  |
| `space`                  | use (open doors, etc) |
| `alt` + arrow            | strafe                |
| `shift` (held)           | run                   |
| `enter`                  | menu / select         |
| `esc`                    | menu / back           |
| `1`–`7`                  | switch weapon         |
| `y` / `n`                | yes / no prompts      |

The UI above the canvas also has:

- a **target FPS** slider (defaults to 35, DOOM's native rate — drag
  higher to see what uncapped looks like),
- an **uncapped** checkbox if you want the browser to draw as fast as
  records arrive,
- a live **FPS counter** in the status line showing real frames-
  per-second over the last second.

---

## 🧪 The fun stuff: what this demo proves

Every input record a player produces runs a full DOOM tick in a
sandboxed WASM module inside the broker. That WASM module holds DOOM's
entire game state in its linear memory between invocations. The broker
commits the resulting framebuffer as the same record's output. You can
see it happen in numbers:

```bash
make bench MODE=sync     # produce-path transforms
make bench MODE=async    # post-write transforms
```

```
             throughput     p50         p99
  sync         ~820 Hz     1.2 ms       2.2 ms     ← playable
  async        ~0.8 Hz     1230 ms      1495 ms    ← unplayable
```

The benchmark correlates each sent input to its matching output by
`tick_seq` so it measures true per-request end-to-end latency
(not "how fast can I pull a buffered stale frame from franz-go").
Try switching mid-game to feel the difference:

```bash
make switch MODE=async   # wipe state, restart in post-write mode → stutter
make switch MODE=sync    # back to produce-path → smooth again
```

---

## 📦 Record formats

Every Kafka record on the `doom` topic (in sync mode) is one of two
things — the browser sends the first, the transform replaces it with
the second.

**Input** (what the browser produces):

```
| u32 tick_seq | u8 event_count | (u8 doom_key, u8 down)* |
```

**Frame** (what lands in the log after the transform runs):

```
| u32 tick_seq | u8 palette_present | [palette? 768] | [pixels 64000] |
```

All fields little-endian. The transform guarantees strict
one-in-one-out.

You can tap into the stream from any Kafka tool via the **EXTERNAL**
listener:

```bash
rpk -X brokers=localhost:19092 topic consume doom -n 1 \
    --format 'offset=%o size=%V\n'

kcat -b localhost:19092 -t doom -C -o -5 -e -f 'offset=%o size=%S\n'
```

The bridge also samples every 10th record to `dump/{in,out}.jsonl`
for offline inspection — see `make dump-clean` if you want to reset
those files.

---

## 🗂️ What's in this repo

```
doom-on-redpanda/
├── bridge/             Go WebSocket ↔ Kafka bridge + embedded HTML/JS
│   ├── main.go
│   └── web/            index.html + doom.js
├── transform/          the WASM side of the demo
│   ├── src/            our C/C++ code (transform entry, input queue,
│   │                   frame capture, DG stubs)
│   ├── patches/        three patches applied to upstream doomgeneric
│   ├── include/        Redpanda C++ transform SDK (Apache-2.0)
│   ├── tools/          WAD embedder, build helpers
│   ├── tests/          native unit tests
│   └── doomgeneric/    fetched by `make setup` (gitignored)
├── deploy/             init container shell scripts
├── tests/              smoke / burst / bench
├── scripts/
│   └── setup.sh        one-time setup flow
├── docs/superpowers/   design spec + implementation plan
├── docker-compose.yml
└── Makefile            your entry point — run `make help`
```

---

## 🧰 Makefile reference

```
make help             show all targets
make setup            one-time: fetch doomgeneric, apply patches, check WAD
make broker-image     build redpandadata/redpanda-dev:latest in Docker
                      (cross-platform, default)
make broker-image-native
                      same, but bazel runs on the host (Redpanda devs)
make rebuild-wasm     compile the transform, redeploy to the broker
make rebuild-bridge   rebuild only the Go bridge container
make up               start the stack in $(MODE)
make down             stop + remove containers, keep volumes
make reset            wipe EVERYTHING (containers, volumes, dumps)
make switch MODE=x    reset + up in mode x (sync | async)
make status           containers + transform state + cluster config
make logs             tail broker + bridge
make smoke            single-record round-trip smoke
make burst            40-record burst (set N=... to override)
make bench            p50/p95/p99 round-trip latency report
make dump-clean       truncate dump/*.jsonl
```

`MODE` defaults to `sync`. Set it via `make bench MODE=async`, etc.

---
