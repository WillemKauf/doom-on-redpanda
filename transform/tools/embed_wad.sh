#!/usr/bin/env bash
# Usage: embed_wad.sh <path/to/doom1.wad> <output/wad_embedded.h>
# Produces a C header with:
#   extern const unsigned char doom_wad[];
#   extern const unsigned long  doom_wad_len;

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <path/to/doom1.wad> <output/wad_embedded.h>" >&2
    exit 1
fi

WAD="$1"
OUT="$2"

if [[ ! -f "$WAD" ]]; then
    echo "error: WAD file not found: $WAD" >&2
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# xxd -i emits   unsigned char <name>[] = { 0x00, ... };
#                unsigned int  <name>_len = ...;
# We rename it to a stable symbol.
cp "$WAD" "$TMP"
(cd "$(dirname "$TMP")" && xxd -i "$(basename "$TMP")") \
    | sed "s/$(basename "$TMP")/doom_wad/g" \
    | sed 's/unsigned int doom_wad_len/unsigned long doom_wad_len/' \
    > "$OUT"

echo "wrote $OUT ($(stat -c %s "$WAD" 2>/dev/null || stat -f %z "$WAD") bytes of WAD)"
