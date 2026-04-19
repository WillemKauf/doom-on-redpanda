# Doom-on-Redpanda top-level controls.
#
# MODE=sync (default) runs the transform on the produce path
#                     (input-topic == output-topic == 'doom'),
#                     synchronously inside the produce request.
#
# MODE=async           runs the traditional post-write transform
#                     (doom.input -> doom.frames), async fiber.
#
# Switch modes:
#   make switch MODE=sync
#   make switch MODE=async
#
# Compare performance:
#   make bench MODE=sync
#   make bench MODE=async

MODE ?= sync

ifeq ($(MODE),sync)
  TOPIC_IN  := doom
  TOPIC_OUT := doom
else ifeq ($(MODE),async)
  TOPIC_IN  := doom.input
  TOPIC_OUT := doom.frames
else
  $(error MODE must be 'sync' or 'async', got '$(MODE)')
endif

# Every target that talks to docker compose exports these so the
# init container + bridge see consistent values.
export DOOM_MODE          := $(MODE)
export DOOM_INPUT_TOPIC   := $(TOPIC_IN)
export DOOM_FRAMES_TOPIC  := $(TOPIC_OUT)

.PHONY: help setup up down stop restart reset switch \
        rebuild-wasm rebuild-bridge wasm broker-image broker-image-native \
        status logs smoke burst bench dump-clean check-setup dump-dir

help: ## This help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Current MODE=$(MODE)  (input=$(TOPIC_IN)  output=$(TOPIC_OUT))"

# ---- setup -------------------------------------------------------------

setup: ## Fetch doomgeneric from upstream, apply patches, check WAD
	./scripts/setup.sh

# Fetch the Redpanda source at branch 'ai-jam/produce-path-wasm', build
# the produce-path broker image, and load it as redpandadata/redpanda-dev:latest.
#
# `broker-image` runs the build inside a container (works on Mac +
# Linux). `broker-image-native` runs bazel on the host — for Redpanda
# developers who already have the toolchain set up.
#
# Both paths share scripts/lib-redpanda-src.sh: if REDPANDA_DIR already
# exists the script leaves the checkout alone unless you also set
# REDPANDA_FETCH=1 to fetch and reset to the produce-path branch.
REDPANDA_DIR ?= ../redpanda-src

broker-image: ## Build the produce-path Redpanda image in Docker (Mac + Linux)
	./scripts/build-broker-docker.sh "$(REDPANDA_DIR)"

broker-image-native: ## Build natively on the host (Redpanda devs with bazel)
	./scripts/build-broker.sh "$(REDPANDA_DIR)"

# Internal: fail fast with a helpful message if the user skipped setup.
check-setup:
	@missing=""; \
	 [ -f transform/doomgeneric/doomgeneric.h ] || missing="$$missing doomgeneric"; \
	 [ -f transform/include/redpanda/transform_sdk.h ] || missing="$$missing redpanda-sdk"; \
	 if [ -n "$$missing" ]; then \
		echo "!! missing:$$missing"; \
		echo "   Run 'make setup' first."; \
		exit 1; \
	 fi

# ---- lifecycle ---------------------------------------------------------

up: check-setup dump-dir ## Start the stack in $(MODE) (keeps existing state)
	docker compose up -d

# Ensure the bind-mounted dump dir exists and is writable by the
# bridge's nonroot uid (65532). Without this, the bridge crash-loops
# on a permission denied when it tries to create in.jsonl.
dump-dir:
	@mkdir -p dump
	@chmod 777 dump

stop: ## Stop containers, keep state
	docker compose stop

down: ## Stop + remove containers, keep volumes
	docker compose down

restart: stop up ## Stop then start

reset: ## Wipe everything — containers, volumes, dumps (keeps dump/ dir)
	docker compose down -v
	rm -f dump/*.jsonl

switch: reset up ## Wipe state and start in $(MODE)
	@echo "now running in MODE=$(MODE)"

# ---- rebuilds ---------------------------------------------------------

rebuild-wasm: check-setup ## Rebuild doom_transform.wasm and redeploy
	$(MAKE) -C transform
	docker compose up -d --build

rebuild-bridge: ## Rebuild only the Go bridge
	docker compose up -d --build bridge

wasm: check-setup ## Just the WASM build (no redeploy)
	$(MAKE) -C transform

# ---- introspection ----------------------------------------------------

status: ## Show container state + cluster config + transform list
	@docker compose ps
	@echo ""
	@echo "produce_path_enabled:"
	@curl -s http://localhost:9644/v1/cluster_config 2>/dev/null \
	   | python3 -c "import sys,json; print(' ',json.load(sys.stdin).get('data_transforms_produce_path_enabled'))" 2>/dev/null || echo "  (admin api unreachable)"
	@echo ""
	@docker exec doom-redpanda /opt/redpanda/bin/rpk transform list 2>&1 || true

logs: ## Tail broker + bridge logs
	docker compose logs -f redpanda bridge

# ---- tests / bench ----------------------------------------------------

smoke: ## Single-record round-trip smoke
	./tests/smoke.sh

burst: ## 40-record burst
	./tests/smoke_burst.sh

bench: ## Measure WS round-trip latency (100 ticks)
	@python3 tests/bench.py

dump-clean: ## Truncate the sampled JSONL dumps
	: > dump/in.jsonl
	: > dump/out.jsonl
	@wc -l dump/*.jsonl
