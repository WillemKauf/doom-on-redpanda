#!/usr/bin/env bash
# Build the produce-path Redpanda OCI image natively on the host and
# load it into docker as redpandadata/redpanda-dev:latest.
#
# This is the native path, meant for Redpanda developers who already
# have bazel and `install-deps.sh` set up. Most users want the Docker
# path instead: see scripts/build-broker-docker.sh (via
# `make broker-image`).
#
# Usage:
#   scripts/build-broker.sh                       # clone into ../redpanda-src
#   scripts/build-broker.sh /path/to/checkout     # or use this checkout
#   REDPANDA_DIR=... scripts/build-broker.sh
#   REDPANDA_FETCH=1 ... (force fetch+reset of the produce-path branch
#                         on an existing checkout; otherwise left alone)
#
# Requirements:
#   - Bazel (via `bazelisk`)
#   - `./bazel/install-deps.sh` run once inside $REDPANDA_DIR
#   - Docker, with enough disk for Bazel's cache (~30 GB)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REDPANDA_DIR="${REDPANDA_DIR:-${1:-$REPO_ROOT/../redpanda-src}}"
IMAGE_TAG="redpandadata/redpanda-dev:latest"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

# ---------- 1) fetch / update the Redpanda source ----------

# shellcheck source=scripts/lib-redpanda-src.sh
source "$REPO_ROOT/scripts/lib-redpanda-src.sh"
ensure_redpanda_src "$REDPANDA_DIR"
cd "$REDPANDA_DIR"

# ---------- 2) bazel build + docker-load ----------

if ! command -v bazel >/dev/null 2>&1; then
    err "bazel not on PATH. Install bazelisk and retry."
    err "  wget -O ~/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64"
    err "  chmod +x ~/bin/bazel && export PATH=\$HOME/bin:\$PATH"
    exit 1
fi

log "bazel build + load (cold cache: 30-90 min; warm: a few min)"
info "running: bazel run //bazel/packaging:image_load"
bazel run //bazel/packaging:image_load

# ---------- 3) verify ----------

if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    log "image loaded:"
    docker image inspect "$IMAGE_TAG" \
        --format '    {{.RepoTags}}  ({{.Id}}, {{.Size}}B)'
    cat <<EOF

==> broker image ready.
    next:
      cd $REPO_ROOT
      make rebuild-wasm     # if you haven't built the WASM transform yet
      make up MODE=sync     # start the stack
      open http://localhost:8090/
EOF
else
    err "image $IMAGE_TAG did not load — check bazel output above."
    exit 1
fi
