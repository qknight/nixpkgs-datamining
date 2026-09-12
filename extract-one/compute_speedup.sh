#!/usr/bin/env sh
set -e

if [ $# -ne 1 ]; then
  echo "Usage: $0 <input-lines-file>" >&2
  exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: input file not found: $INPUT_FILE" >&2
  exit 1
fi

nix-shell -p python3 --run "python3 - <<EOF
import sys
from pathlib import Path

inp = Path(\"$INPUT_FILE\")

total_builds_count = 0
shared_builds_count = 0

for raw in inp.read_text().splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split()
    try:
        total_builds_count += int(parts[0])
        shared_builds_count += 1
    except (ValueError, IndexError):
        # Ignore lines that don't start with an integer
        continue

print(
    f\"Computed totals from {inp}: total_builds={total_builds_count}, shared_builds={shared_builds_count}, speedup={total_builds_count/shared_builds_count}\",
    file=sys.stderr
)
EOF"