#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helper for doom-on-redpanda broker builds. Both the Docker
# path (scripts/build-broker-docker.sh) and the native path
# (scripts/build-broker.sh) source this to materialise the Redpanda
# source at $REDPANDA_DIR.
#
# Defines:
#   ensure_redpanda_src <dir>
#       Prepares the source at <dir>. If <dir> doesn't exist, shallow-
#       clones the produce-path branch. If it exists, by default
#       leaves the working tree untouched (just sanity-checks that
#       the feature is present). Set REDPANDA_FETCH=1 to force a
#       fetch+reset to the produce-path branch on an existing
#       checkout.
#
# Environment:
#   REDPANDA_BRANCH  branch to clone/fetch (default ai-jam/produce-path-wasm)
#   REDPANDA_REMOTE  upstream URL (default github.com/redpanda-data/redpanda)
#   REDPANDA_FETCH   1 to force fetch+reset on existing checkouts

_rp_log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
_rp_info() { printf '    %s\n' "$*"; }
_rp_err()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

ensure_redpanda_src() {
    local dir="$1"
    if [ -z "$dir" ]; then
        _rp_err "ensure_redpanda_src: target dir required"
        return 2
    fi

    local branch="${REDPANDA_BRANCH:-ai-jam/produce-path-wasm}"
    local remote="${REDPANDA_REMOTE:-https://github.com/redpanda-data/redpanda.git}"

    _rp_log "Redpanda source location: $dir"
    _rp_log "Target branch:            $branch"

    if [ -d "$dir/.git" ]; then
        if [ "${REDPANDA_FETCH:-0}" = "1" ]; then
            _rp_info "existing checkout — REDPANDA_FETCH=1, fetching + resetting..."
            _rp_fetch_and_checkout "$dir" "$branch" "$remote"
        else
            _rp_info "existing checkout — using whatever's there"
            _rp_info "(set REDPANDA_FETCH=1 to fetch $branch and reset)"
        fi
    else
        _rp_info "fresh clone (shallow)..."
        mkdir -p "$(dirname "$dir")"
        git clone --depth=1 --branch "$branch" "$remote" "$dir"
    fi

    ( cd "$dir" && _rp_info "HEAD: $(git log --oneline -1)" )

    if ! grep -rq 'data_transforms_produce_path_enabled' "$dir/src/v" 2>/dev/null; then
        _rp_err "This checkout lacks 'data_transforms_produce_path_enabled' under src/v/."
        _rp_err "The produce-path branch may have been renamed or removed."
        _rp_err "Try: REDPANDA_FETCH=1 ... (or point REDPANDA_DIR at a different checkout)"
        return 1
    fi
    _rp_info "feature present: data_transforms_produce_path_enabled ✓"
}

_rp_fetch_and_checkout() {
    local dir="$1"
    local branch="$2"
    local remote="$3"
    local fetch_remote
    (
        cd "$dir" || return
        if ! git remote -v | grep -q "$remote"; then
            if ! git remote | grep -q '^doom-demo-upstream$'; then
                _rp_info "adding 'doom-demo-upstream' remote -> $remote"
                git remote add doom-demo-upstream "$remote"
            fi
            fetch_remote=doom-demo-upstream
        else
            fetch_remote=$(git remote -v | awk -v url="$remote" '$2==url {print $1; exit}')
        fi
        _rp_info "fetching $branch from $fetch_remote..."
        git fetch --depth=1 "$fetch_remote" "$branch"
        git checkout -B "$branch" FETCH_HEAD
    )
}
