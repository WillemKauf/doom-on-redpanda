#!/usr/bin/env bash
# Build the produce-path Redpanda broker image via Docker.
#
# The bazel build runs inside a container, so this works on macOS too
# — no host-side Linux toolchain required. The resulting OCI image is
# loaded into the *host* docker daemon as redpandadata/redpanda-dev:latest.
#
# Usage:
#   scripts/build-broker-docker.sh                       # clone into ../redpanda-src
#   scripts/build-broker-docker.sh /path/to/checkout     # or use this checkout
#   REDPANDA_DIR=... scripts/build-broker-docker.sh
#   REDPANDA_FETCH=1 ... (force fetch+reset of the produce-path branch
#                         on an existing checkout; otherwise left alone)
#
# Requirements:
#   - Docker daemon reachable via a unix socket. Defaults to
#     /var/run/docker.sock; override with DOCKER_SOCK=/path/to/sock
#     for rootless Docker or non-default setups.
#     (Docker Desktop on Mac exposes the default; Linux users: same.)
#   - ~30 GB of docker storage for the bazel cache volume
#   - On macOS, give Docker Desktop >= 16 GB RAM and >= 60 GB disk
#
# Memory-limited hosts: cap bazel parallelism to avoid OOM. Redpanda
# compile actions can peak at 2-4 GB each; default `--jobs` scales with
# container cores, which OOMs Docker Desktop allocations below ~24 GB.
#   BAZEL_JOBS=N       → passes `--jobs=N` to bazel.
#                        ~2 for 8 GB, ~4 for 16 GB, default for 24 GB+.
#   BAZEL_RAM_MB=MiB   → passes `--local_ram_resources=MiB`, letting
#                        bazel pick jobs itself from a RAM budget.
#
# Recovering from tangled bazel state: if a previous run was OOM-killed
# or aborted mid-compile, the action cache on the volume can end up
# inconsistent and reject correct source with strict-deps errors that
# don't match the actual BUILDs. Two escape hatches:
#   BAZEL_CLEAN=all      `bazel clean`. Forces a full rebuild but keeps
#                        external/ — no re-download of deps.
#   BAZEL_CLEAN=expunge  `bazel clean --expunge`. Nukes everything
#                        including external deps (full re-download).
#
# One-off bazel flags: for anything else the above knobs don't cover,
# BAZEL_EXTRA_FLAGS is passed verbatim as extra args to `bazel run`.
# Values are whitespace-split; no support for quoted values with spaces.
# Common uses:
#   BAZEL_EXTRA_FLAGS='--features=-layering_check'
#                   Disable clang-modules strict-deps enforcement for
#                   branches whose BUILDs don't pass layering on your
#                   build platform (typical of DNM branches that were
#                   only CI-tested on x86_64).
#
# Security note: this build mounts the host docker socket into the
# builder container (that's how the final image lands in the host
# daemon via `docker load`). The build container therefore has full
# control of the host daemon. Fine for local builds from upstream
# Redpanda source; reconsider before running on any Redpanda source
# you haven't audited.
#
# Build time: 30-90 minutes cold; a few minutes warm (bazel cache
# persists in a named docker volume called rp-bazel-cache).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REDPANDA_DIR="${REDPANDA_DIR:-${1:-$REPO_ROOT/../redpanda-src}}"
BUILDER_IMG="${BUILDER_IMG:-doom-on-redpanda-broker-build:latest}"
CACHE_VOLUME="${CACHE_VOLUME:-rp-bazel-cache}"
IMAGE_TAG="redpandadata/redpanda-dev:latest"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

# ---------- 1) materialise the Redpanda source ----------

# shellcheck source=scripts/lib-redpanda-src.sh
source "$REPO_ROOT/scripts/lib-redpanda-src.sh"
ensure_redpanda_src "$REDPANDA_DIR"

# Make the path absolute — docker -v wants absolutes, and $REDPANDA_DIR
# often starts as a relative path like ../redpanda-src.
REDPANDA_DIR="$(cd "$REDPANDA_DIR" && pwd)"

# ---------- 1.5) pre-flight: docker socket reachable? ----------

# Fail fast (<1s) instead of after the 30-90 min bazel run if the
# socket isn't where we think it is. Override path via DOCKER_SOCK=...
if [ ! -S "$DOCKER_SOCK" ]; then
    err "No docker socket at $DOCKER_SOCK."
    err "Rootless Docker typically lives at /run/user/\$UID/docker.sock;"
    err "set DOCKER_SOCK to override, or switch to rootful Docker."
    exit 1
fi

# ---------- 2) build the builder image ----------

BUILDER_DOCKERFILE="$REDPANDA_DIR/tools/docker/bazel.dockerfile"
if [ ! -f "$BUILDER_DOCKERFILE" ]; then
    err "Missing $BUILDER_DOCKERFILE."
    err "Your Redpanda checkout predates the upstream bazel.dockerfile."
    err "Try: REDPANDA_FETCH=1 $0   (or fresh-clone into a new REDPANDA_DIR)"
    exit 1
fi

log "building builder image: $BUILDER_IMG"
info "from: $BUILDER_DOCKERFILE"
docker build -f "$BUILDER_DOCKERFILE" -t "$BUILDER_IMG" "$REDPANDA_DIR"

# ---------- 2.5) optional cleanup of tangled bazel state ----------

# Run inside the builder with the workspace mounted so `bazel shutdown`
# finds the persistent server. All rm paths are inside the cache volume.
_bazel_in_builder() {
    docker run --rm \
        -v "$REDPANDA_DIR:/workspace" -w /workspace \
        -v "$CACHE_VOLUME:/root/.cache/bazel" \
        "$BUILDER_IMG" \
        bash -c "$1"
}

case "${BAZEL_CLEAN:-}" in
    "")
        ;;
    all)
        log "BAZEL_CLEAN=all — bazel clean (keeps external deps)"
        _bazel_in_builder 'bazel clean'
        ;;
    expunge)
        log "BAZEL_CLEAN=expunge — bazel clean --expunge (re-downloads deps)"
        _bazel_in_builder 'bazel clean --expunge'
        ;;
    *)
        err "BAZEL_CLEAN='$BAZEL_CLEAN' — invalid. Use 'all' or 'expunge'."
        exit 1
        ;;
esac

# ---------- 3) run bazel inside the builder ----------

log "bazel build + docker load via mounted socket"
info "(cold cache: 30-90 min; warm: a few min)"
info "bazel cache volume: $CACHE_VOLUME"

# Optional caps for memory-limited containers. The `+` expansion below
# is the bash-3.2-safe way to pass an array that may be empty — matters
# on macOS where /bin/bash defaults to 3.2.
bazel_flags=()
[ -n "${BAZEL_JOBS:-}" ]   && bazel_flags+=("--jobs=${BAZEL_JOBS}")
[ -n "${BAZEL_RAM_MB:-}" ] && bazel_flags+=("--local_ram_resources=${BAZEL_RAM_MB}")
if [ "${#bazel_flags[@]}" -gt 0 ]; then
    info "bazel flags: ${bazel_flags[*]}"
fi

# Generic escape hatch for one-off bazel flags.
bazel_extra=()
if [ -n "${BAZEL_EXTRA_FLAGS:-}" ]; then
    # shellcheck disable=SC2206
    read -ra bazel_extra <<< "$BAZEL_EXTRA_FLAGS"
    info "bazel extra flags: ${bazel_extra[*]}"
fi

docker run --rm \
    -v "$REDPANDA_DIR:/workspace" \
    -w /workspace \
    -v "$CACHE_VOLUME:/root/.cache/bazel" \
    -v "$DOCKER_SOCK:/var/run/docker.sock" \
    "$BUILDER_IMG" \
    bazel run \
        ${bazel_flags[@]+"${bazel_flags[@]}"} \
        ${bazel_extra[@]+"${bazel_extra[@]}"} \
        //bazel/packaging:image_load

# ---------- 4) chown the bazel-* convenience symlinks back ----------

# bazel drops bazel-bin / bazel-out / bazel-testlogs / bazel-<repo>
# symlinks into the workspace root. They'll be root-owned on Linux
# because the container ran as root. Fix that so a host `ls` doesn't
# surface root-owned files in the user's tree. (No-op on macOS, where
# Docker Desktop handles uid mapping.)
if [ "$(uname)" = "Linux" ] && [ "$(id -u)" != "0" ]; then
    info "restoring ownership of bazel-* symlinks to $(id -u):$(id -g)"
    docker run --rm \
        -v "$REDPANDA_DIR:/workspace" \
        -w /workspace \
        "$BUILDER_IMG" \
        bash -c 'chown -h '"$(id -u):$(id -g)"' bazel-* 2>/dev/null || true'
fi

# ---------- 5) verify ----------

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
    err "image $IMAGE_TAG did not load — check the bazel output above."
    err "Common cause: the docker socket mount didn't reach the host daemon."
    err "Verify with: docker run --rm -v $DOCKER_SOCK:/var/run/docker.sock $BUILDER_IMG docker info"
    exit 1
fi
