#!/usr/bin/env bash
# One-time setup: fetch doomgeneric from upstream, strip the platform
# drivers we don't use, apply our patches, and check that a Doom WAD
# is available. Idempotent — safe to re-run.
#
# Environment:
#   DOOM_WAD  — absolute path to a shareware doom1.wad.
#               Defaults to ~/Downloads/doom1.wad.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DG_DIR="$REPO_ROOT/transform/doomgeneric"
DG_UPSTREAM="https://github.com/ozkl/doomgeneric.git"
PATCH_DIR="$REPO_ROOT/transform/patches"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

# ---------- 1) doomgeneric ----------

log "checking doomgeneric at $DG_DIR"

if [ -d "$DG_DIR" ] && [ -f "$DG_DIR/doomgeneric.h" ]; then
    info "already present — skipping fetch. To force re-fetch: rm -rf transform/doomgeneric"
else
    info "fetching from $DG_UPSTREAM ..."

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    git clone --depth=1 --quiet "$DG_UPSTREAM" "$TMP/dg"
    mkdir -p "$DG_DIR"
    cp -r "$TMP/dg/doomgeneric/." "$DG_DIR/"
    cp "$TMP/dg/LICENSE" "$DG_DIR/LICENSE"

    # Remove platform drivers we can't/don't build against.
    for f in doomgeneric_sdl.c doomgeneric_xlib.c doomgeneric_win.c \
             doomgeneric_allegro.c doomgeneric_emscripten.c \
             doomgeneric_linuxvt.c doomgeneric_soso.c doomgeneric_sosox.c; do
        rm -f "$DG_DIR/$f"
    done

    info "applying patches from $PATCH_DIR"
    shopt -s nullglob
    patches=("$PATCH_DIR"/*.patch)
    shopt -u nullglob
    if [ ${#patches[@]} -eq 0 ]; then
        err "no patches found — is the repo corrupt?"
        exit 1
    fi
    for p in "${patches[@]}"; do
        info "  - $(basename "$p")"
        if ! (cd "$REPO_ROOT" && patch -p1 --forward --silent < "$p"); then
            err "patch $(basename "$p") did not apply cleanly"
            err "the upstream may have diverged; inspect $p and fix manually"
            exit 1
        fi
    done
    info "doomgeneric ready"
fi

# ---------- 2) Redpanda C++ transform SDK ----------

SDK_BRANCH="${REDPANDA_BRANCH:-ai-jam/produce-path-wasm}"
SDK_BASE_URL="https://raw.githubusercontent.com/redpanda-data/redpanda/$SDK_BRANCH/src/transform-sdk/cpp"
SDK_HEADER="$REPO_ROOT/transform/include/redpanda/transform_sdk.h"
SDK_IMPL="$REPO_ROOT/transform/include/redpanda_transform_sdk/transform_sdk.cc"

log "checking Redpanda C++ transform SDK"

if [ -f "$SDK_HEADER" ] && [ -f "$SDK_IMPL" ]; then
    info "SDK already present — skipping fetch."
else
    info "fetching from branch '$SDK_BRANCH' ..."
    mkdir -p "$(dirname "$SDK_HEADER")" "$(dirname "$SDK_IMPL")"
    curl -fsSL "$SDK_BASE_URL/include/redpanda/transform_sdk.h" -o "$SDK_HEADER"
    curl -fsSL "$SDK_BASE_URL/src/transform_sdk.cc"            -o "$SDK_IMPL"
    info "SDK ready:"
    info "  $SDK_HEADER ($(wc -l <"$SDK_HEADER") lines)"
    info "  $SDK_IMPL ($(wc -l <"$SDK_IMPL") lines)"
fi

# ---------- 3) WAD ----------

WAD_PATH="${DOOM_WAD:-$HOME/Downloads/doom1.wad}"
log "checking WAD at $WAD_PATH"

if [ ! -f "$WAD_PATH" ]; then
    err "WAD not found."
    cat <<EOF

    Provide a shareware doom1.wad (the free one id ships) by either:

      (a) placing it at:  $WAD_PATH
      (b) exporting DOOM_WAD before running make:
              export DOOM_WAD=/path/to/your/doom1.wad

    You can get the shareware WAD from:
      https://archive.org/details/DoomsharewareEpisode
      or extract it from any copy of the DOOM shareware install.

    (The commercial WADs — doom.wad, doom2.wad, plutonia.wad, tnt.wad —
     also work but are not freely redistributable. Shareware is the
     safest choice.)

EOF
    exit 1
fi

wad_bytes="$(stat -Lc %s "$WAD_PATH" 2>/dev/null || stat -Lf %z "$WAD_PATH")"
info "WAD present: $WAD_PATH ($wad_bytes bytes)"

# Sanity: first 4 bytes should be IWAD or PWAD.
magic="$(head -c 4 "$WAD_PATH" 2>/dev/null || true)"
if [ "$magic" != "IWAD" ] && [ "$magic" != "PWAD" ]; then
    err "WAD magic is '$magic' — expected IWAD or PWAD. File may be corrupt."
    exit 1
fi
info "WAD magic: $magic"

# ---------- 4) broker image check ----------

DEV_IMAGE="redpandadata/redpanda-dev:latest"
log "checking for produce-path broker image: $DEV_IMAGE"

if docker image inspect "$DEV_IMAGE" >/dev/null 2>&1; then
    info "image found — MODE=sync (produce-path) will work."
else
    cat <<EOF

    \033[1;33m!\033[0m  '$DEV_IMAGE' is NOT in your local docker.

    MODE=sync (produce-path transforms, ~1 ms round-trip) requires a
    Redpanda build from the produce-path branch. Three options:

    (a) Let us build it for you in Docker (recommended — works on
        macOS and Linux, no host bazel required):

            make broker-image

        This clones github.com/redpanda-data/redpanda at branch
        'ai-jam/produce-path-wasm' into ../redpanda-src (override
        with REDPANDA_DIR=...) and runs bazel inside a container.
        Cold builds take 30-90 minutes and need ~30 GB of docker
        storage for a named bazel cache volume. On macOS, give
        Docker Desktop >= 16 GB RAM and >= 60 GB disk.

    (b) Redpanda developers: build natively on the host instead:

            make broker-image-native REDPANDA_DIR=~/co/redpanda

        By default this leaves your checkout untouched. Set
        REDPANDA_FETCH=1 to fetch+reset to the produce-path branch.

    (c) Skip it and run in post-write mode against stock Redpanda:

            make switch MODE=async

        This works on redpandadata/redpanda:latest but is bimodal-
        stuttery — the demo will look broken. Useful for showing
        *why* produce-path matters.

EOF
fi

log "setup complete"
cat <<EOF

    next steps:
      make broker-image    # build produce-path Redpanda (skip for async only)
      make rebuild-wasm    # compile the transform + redeploy
      make up              # start the docker-compose stack
      make bench           # measure pipeline round-trip latency
      open http://localhost:8090/

    to switch modes:
      make switch MODE=async
      make switch MODE=sync
EOF
