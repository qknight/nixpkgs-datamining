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

grand_total = 0
record_count = 0

for raw in inp.read_text().splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split()
    try:
        grand_total += int(parts[0])
        record_count += 1
    except (ValueError, IndexError):
        # Ignore lines that don't start with an integer
        continue

print(
    f\"Computed totals from {inp}: total_builds={grand_total}, shared_builds={record_count}, speedup={grand_total/record_count}\",
    file=sys.stderr
)
EOF"