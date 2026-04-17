#!/bin/bash
# Two-stage wasm build: compile C and C++ sources to wasm object files with
# the right -std flag, then link. Runs inside the wasi-sdk docker container.
set -euo pipefail

OUT_DIR="${OUT_DIR:-build}"
OBJ_DIR="${OUT_DIR}/obj"
WASM="${OUT_DIR}/doom_transform.wasm"

CC=clang-17
CXX=clang++-17
TARGET_FLAGS="--target=wasm32-wasi --sysroot=/wasi-sysroot"
COMMON_FLAGS="-O2 -flto -Wno-everything \
  -DCMAP256=1 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DDOOMWAD_FROM_MEMORY=1 \
  -I include -I include/redpanda_transform_sdk -I doomgeneric -I src"
CFLAGS="-std=gnu11"
CXXFLAGS="-std=c++23 -fno-exceptions"

mkdir -p "$OBJ_DIR"

# doomgeneric .c files we do NOT compile: platform-specific drivers.
SKIP_C=(
    "doomgeneric/doomgeneric_sdl.c"
    "doomgeneric/doomgeneric_xlib.c"
    "doomgeneric/doomgeneric_win.c"
    "doomgeneric/i_sdlmusic.c"
    "doomgeneric/i_sdlsound.c"
    "doomgeneric/i_allegromusic.c"
    "doomgeneric/i_allegrosound.c"
)

is_skipped() {
    local src="$1"
    local s
    for s in "${SKIP_C[@]}"; do
        [[ "$src" == "$s" ]] && return 0
    done
    return 1
}

obj_for() {
    echo "$OBJ_DIR/$(echo "$1" | tr '/' '_').o"
}

OBJS=()

# C sources: transform helpers + all non-skipped doomgeneric .c files.
C_SRCS=(src/doom_input_queue.c src/doom_frame_capture.c src/doom_stubs.c)
for src in doomgeneric/*.c; do
    is_skipped "$src" && continue
    C_SRCS+=("$src")
done
for src in "${C_SRCS[@]}"; do
    obj="$(obj_for "$src")"
    echo "CC  $src" >&2
    $CC $TARGET_FLAGS $COMMON_FLAGS $CFLAGS -c "$src" -o "$obj"
    OBJS+=("$obj")
done

# C++ sources: the transform entry point and the Redpanda SDK.
CXX_SRCS=(src/doom_transform.cc include/redpanda_transform_sdk/transform_sdk.cc)
for src in "${CXX_SRCS[@]}"; do
    obj="$(obj_for "$src")"
    echo "CXX $src" >&2
    $CXX $TARGET_FLAGS $COMMON_FLAGS $CXXFLAGS -c "$src" -o "$obj"
    OBJS+=("$obj")
done

echo "LINK $WASM" >&2
$CXX $TARGET_FLAGS -O2 -flto -fno-exceptions "${OBJS[@]}" -o "$WASM"
