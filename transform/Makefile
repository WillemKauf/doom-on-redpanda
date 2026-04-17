# doom-on-redpanda: transform Makefile.
# Top-level targets:
#   make               — default: build doom_transform.wasm
#   make test-native   — build + run native unit tests (input queue, frame capture)
#   make test-wasm     — load doom_transform.wasm in wasmtime and run a frame roundtrip
#   make clean
#
# The WASM build compiles doomgeneric (C) + the transform entry point (C++)
# inside the wasi-sdk docker image. Source lists, flags, and the two-stage
# C/C++ split live in tools/build_wasm.sh so this Makefile stays small.

DOOM_WAD       ?= $(HOME)/Downloads/doom1.wad
BUILD_DIR      ?= build
WASM           := $(BUILD_DIR)/doom_transform.wasm

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
	docker run --rm -v $(CURDIR):/src -w /src \
	  --user $(shell id -u):$(shell id -g) \
	  $(DOCKER_IMG) \
	  tools/build_wasm.sh
	@ls -l $(WASM)

test-native:
	mkdir -p $(BUILD_DIR)
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
