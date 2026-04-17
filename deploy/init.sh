#!/usr/bin/env bash
# Creates topics and deploys the Doom transform in the mode requested
# by $DOOM_MODE (default: sync).
#
# sync  — produce-path transform, input-topic == output-topic == 'doom'.
#         Transform rewrites each record in-place during the produce
#         request. Only the rewritten frame lands in the log.
# async — post-write transform, two topics (doom.input -> doom.frames).
#         Producer's ack is for the input write; transform fires
#         asynchronously and appends frames to the output topic.
#
# Both modes deploy the same .wasm binary — only cluster config and
# topic plumbing differ.

set -euo pipefail

MODE="${DOOM_MODE:-sync}"
case "$MODE" in
    sync)  INPUT=doom       OUTPUT=doom      PRODUCE_PATH=true  ;;
    async) INPUT=doom.input OUTPUT=doom.frames PRODUCE_PATH=false ;;
    *)     echo "unknown DOOM_MODE=$MODE (want sync|async)" >&2; exit 1 ;;
esac

echo "mode=$MODE input=$INPUT output=$OUTPUT produce_path=$PRODUCE_PATH"

echo "waiting for broker..."
until rpk cluster health --exit-when-healthy 2>/dev/null; do
    sleep 1
done

echo "setting cluster property: data_transforms_produce_path_enabled=$PRODUCE_PATH"
rpk cluster config set data_transforms_produce_path_enabled "$PRODUCE_PATH"

# Remove any existing 'doom' transform — topics may be changing beneath it.
if rpk transform list 2>/dev/null | grep -q '^doom\b'; then
    echo "removing existing 'doom' transform..."
    rpk transform delete doom --no-confirm
fi

# Drop any topics that don't belong in the current mode. (Idempotent
# when they don't exist.)
for t in doom doom.input doom.frames; do
    keep=0
    [ "$t" = "$INPUT" ] && keep=1
    [ "$t" = "$OUTPUT" ] && keep=1
    if [ "$keep" = 0 ] && rpk topic list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$t"; then
        echo "cleanup: deleting topic '$t' (not in use for mode=$MODE)"
        rpk topic delete "$t" --no-confirm || true
    fi
done

echo "creating topics..."
rpk topic create "$INPUT"  -p 1 -r 1 --if-not-exists
rpk topic create "$OUTPUT" -p 1 -r 1 --if-not-exists
rpk topic alter-config "$INPUT"  --set retention.ms=60000 --set segment.ms=60000 --no-confirm
[ "$INPUT" != "$OUTPUT" ] && \
    rpk topic alter-config "$OUTPUT" --set retention.ms=60000 --set segment.ms=60000 --no-confirm

echo "deploying transform..."
rpk transform deploy \
    --file /transform/doom_transform.wasm \
    --name doom \
    --input-topic="$INPUT" \
    --output-topic="$OUTPUT"

echo "ready."
rpk transform list
