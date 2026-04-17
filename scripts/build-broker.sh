#!/usr/bin/env bash
# Fetch the Redpanda source at the produce-path branch, build its OCI
# image, and load it into docker as redpandadata/redpanda-dev:latest.
#
# Usage:
#   scripts/build-broker.sh                       # clone into ../redpanda-src
#   scripts/build-broker.sh /path/to/checkout     # or use this checkout
#   REDPANDA_DIR=... scripts/build-broker.sh
#
# The script will:
#   1. Clone or update a shallow checkout at $REDPANDA_DIR,
#   2. Check it's on the right branch with the feature present,
#   3. Run `bazel run //bazel/packaging:image_load` to build + docker-load
#      the image.
#
# Requirements (all prerequisite-level, see Redpanda's own docs):
#   - Bazel (via `bazelisk`)
#   - `./bazel/install-deps.sh` run once (system C++ deps)
#   - Docker, with enough disk for Bazel's cache (~30 GB)
#
# Build time: 30-90 minutes on a cold cache, a few minutes warm.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Configuration
REQUIRED_BRANCH="${REDPANDA_BRANCH:-ai-jam/produce-path-wasm}"
REDPANDA_REMOTE="${REDPANDA_REMOTE:-https://github.com/redpanda-data/redpanda.git}"
REDPANDA_DIR="${REDPANDA_DIR:-${1:-$REPO_ROOT/../redpanda-src}}"
IMAGE_TAG="redpandadata/redpanda-dev:latest"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

# ---------- 1) fetch / update the Redpanda source ----------

log "Redpanda source location: $REDPANDA_DIR"
log "Target branch:            $REQUIRED_BRANCH"

if [ -d "$REDPANDA_DIR/.git" ]; then
    info "existing checkout — updating..."
    cd "$REDPANDA_DIR"

    # Make sure our remote matches (don't clobber user remotes if they differ).
    if ! git remote -v | grep -q "$REDPANDA_REMOTE"; then
        if ! git remote | grep -q '^doom-demo-upstream$'; then
            info "adding 'doom-demo-upstream' remote -> $REDPANDA_REMOTE"
            git remote add doom-demo-upstream "$REDPANDA_REMOTE"
        fi
        FETCH_REMOTE=doom-demo-upstream
    else
        FETCH_REMOTE=$(git remote -v | awk -v url="$REDPANDA_REMOTE" '$2==url {print $1; exit}')
    fi

    info "fetching $REQUIRED_BRANCH from $FETCH_REMOTE..."
    git fetch --depth=1 "$FETCH_REMOTE" "$REQUIRED_BRANCH"
    git checkout -B "$REQUIRED_BRANCH" "FETCH_HEAD"
else
    info "fresh clone (shallow)..."
    mkdir -p "$(dirname "$REDPANDA_DIR")"
    git clone --depth=1 --branch "$REQUIRED_BRANCH" \
        "$REDPANDA_REMOTE" "$REDPANDA_DIR"
    cd "$REDPANDA_DIR"
fi

info "HEAD: $(git log --oneline -1)"

# ---------- 2) sanity check the feature is there ----------

if ! grep -rq 'data_transforms_produce_path_enabled' src/v 2>/dev/null; then
    err "This checkout lacks 'data_transforms_produce_path_enabled' under src/v/."
    err "The produce-path branch may have been renamed or removed."
    err "Try setting REDPANDA_BRANCH to a different branch."
    exit 1
fi
info "feature present: data_transforms_produce_path_enabled ✓"

# ---------- 3) bazel build + docker-load ----------

if ! command -v bazel >/dev/null 2>&1; then
    err "bazel not on PATH. Install bazelisk and retry."
    err "  wget -O ~/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64"
    err "  chmod +x ~/bin/bazel && export PATH=\$HOME/bin:\$PATH"
    exit 1
fi

log "bazel build + load (cold cache: 30-90 min; warm: a few min)"
info "running: bazel run //bazel/packaging:image_load"
bazel run //bazel/packaging:image_load

# ---------- 4) verify ----------

if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    log "image loaded:"
    docker image inspect "$IMAGE_TAG" \
        --format '    {{.RepoTags}}  ({{.Id}}, {{.Size}}B)'
    cat <<EOF

==> broker image ready.
    next:
      cd $REPO_ROOT
      make switch MODE=sync
      open http://localhost:8090/
EOF
else
    err "image $IMAGE_TAG did not load — check bazel output above."
    exit 1
fi
