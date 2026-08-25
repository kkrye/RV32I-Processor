#!/usr/bin/env bash
set -euo pipefail

S_FILE="$1"
DIR="$(dirname "$S_FILE")"
FILE="$(basename "$S_FILE")"
BASE="${FILE%.*}"

echo "==> make assemble TEST=$S_FILE"
make assemble TEST="$S_FILE"

echo "==> Running riscv-ref-sim on $S_FILE"
printf "go\nrdump %s/%s.reg\nmdump 0x10000000 0x10000100 memdump.txt" "$DIR" "$BASE" \
 | riscv-ref-sim "$S_FILE"
echo "==> make verify TEST=$S_FILE"
make verify TEST="$S_FILE"

#bash compare_mem.sh
