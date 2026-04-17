#!/usr/bin/env bash
# End-to-end smoke: produce one input record, consume one frame,
# check the frame size is one of the two allowed values.
#
# Expects docker-compose up and healthy.

set -euo pipefail

cd "$(dirname "$0")"

# Topic names come from the Makefile (which exports them per MODE)
# or the environment. Defaults match sync mode.
INPUT_TOPIC="${DOOM_INPUT_TOPIC:-doom}"
FRAMES_TOPIC="${DOOM_FRAMES_TOPIC:-doom}"

# `-i` is required so stdin (the sample_input.bin bytes) is piped into
# the container's rpk process. Without `-i` docker silently detaches
# stdin and rpk reads EOF immediately, producing zero records.
RPK_IN="docker exec -i doom-redpanda /opt/redpanda/bin/rpk"
RPK="docker exec doom-redpanda /opt/redpanda/bin/rpk"

echo "[smoke] pushing one input record to $INPUT_TOPIC..."
$RPK_IN topic produce "$INPUT_TOPIC" --format '%v' < sample_input.bin

echo "[smoke] consuming one frame record from $FRAMES_TOPIC..."
FRAMEFILE="$(mktemp)"
trap 'rm -f "$FRAMEFILE"' EXIT

$RPK topic consume "$FRAMES_TOPIC" -n 1 --format '%v' > "$FRAMEFILE"

bytes=$(stat -c %s "$FRAMEFILE")
echo "[smoke] frame size: $bytes bytes"

# First frame has palette dirty -> expect 64773 bytes.
# Subsequent no-palette frames -> 64005 bytes.
# rpk may append a trailing newline to '%v' output, so tolerate +1.
if [[ "$bytes" != "64773" && "$bytes" != "64005" \
    && "$bytes" != "64774" && "$bytes" != "64006" ]]; then
    echo "[smoke] FAIL: unexpected frame size"
    exit 1
fi

echo "[smoke] ok"
