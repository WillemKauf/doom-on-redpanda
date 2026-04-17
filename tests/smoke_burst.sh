#!/usr/bin/env bash
# Extended smoke: push N idle ticks, consume N frames, verify the
# transform keeps the one-in-one-out invariant under a burst.
#
# Also hashes a few frames to confirm Doom is actually simulating
# (title-screen attract demo -> frame content changes over time).

set -euo pipefail

cd "$(dirname "$0")"

N=${N:-40}
INPUT_TOPIC="${DOOM_INPUT_TOPIC:-doom}"
FRAMES_TOPIC="${DOOM_FRAMES_TOPIC:-doom}"

RPK_IN="docker exec -i doom-redpanda /opt/redpanda/bin/rpk"
RPK="docker exec doom-redpanda /opt/redpanda/bin/rpk"

before=$($RPK topic describe "$FRAMES_TOPIC" -p | awk 'NR==2 {print $6}')
echo "[burst] $FRAMES_TOPIC HWM before: $before"

echo "[burst] pushing $N idle-tick input records to $INPUT_TOPIC..."
for i in $(seq 1 $N); do
    python3 -c "
import sys, struct
sys.stdout.buffer.write(struct.pack('<IB', 1000 + $i, 0))
" | $RPK_IN topic produce "$INPUT_TOPIC" --format '%v' > /dev/null
done

target=$(( before + N ))
echo "[burst] waiting for $N frames on $FRAMES_TOPIC (target HWM $target)..."
for i in {1..60}; do
    cur=$($RPK topic describe "$FRAMES_TOPIC" -p | awk 'NR==2 {print $6}')
    if [[ "$cur" -ge "$target" ]]; then
        echo "[burst] done: HWM is $cur after ${i}s"
        break
    fi
    sleep 1
done

cur=$($RPK topic describe "$FRAMES_TOPIC" -p | awk 'NR==2 {print $6}')
delta=$(( cur - before ))
echo "[burst] frames produced: $delta (expected $N)"
if [[ "$delta" -ne "$N" ]]; then
    echo "[burst] FAIL: wrong frame count"
    exit 1
fi

# Dump three frames and hash them.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for idx in 0 $(( N / 2 )) $(( N - 1 )); do
    off=$(( before + idx ))
    $RPK topic consume "$FRAMES_TOPIC" -o "$off" -n 1 --format '%v' > "$tmp/frame_$idx.bin"
    bytes=$(stat -c %s "$tmp/frame_$idx.bin")
    sha=$(sha256sum "$tmp/frame_$idx.bin" | cut -c1-16)
    pp=$(xxd -p -l 1 -s 4 "$tmp/frame_$idx.bin")
    tick=$(xxd -p -l 4 "$tmp/frame_$idx.bin")
    echo "[burst] frame offset=$off  bytes=$bytes  tick_seq=0x$tick  palette_present=0x$pp  sha=$sha"
done

# Sanity: first frame should differ from middle frame (attract demo moves).
if cmp -s "$tmp/frame_0.bin" "$tmp/frame_$(( N / 2 )).bin"; then
    echo "[burst] WARN: frame 0 and middle frame are identical"
else
    echo "[burst] ok: frames differ across the burst (Doom is simulating)"
fi

echo "[burst] ok"
