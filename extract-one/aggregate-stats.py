#!/usr/bin/env python3
"""
Aggregate dependency statistics from multiple *.stats files.

Usage:
    ./aggregate-stats.py <directory-with-stats-files> [output-file]

If output-file is omitted the result is written to stdout.
"""

import sys
from pathlib import Path
from collections import Counter

def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print(f"Usage: {sys.argv[0]} <stats-directory> [output-file]", file=sys.stderr)
        sys.exit(1)

    stats_dir = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) == 3 else None

    if not stats_dir.is_dir():
        print(f"Error: {stats_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    counter = Counter()

    stats_files = sorted(stats_dir.glob("*.stats"))
    if not stats_files:
        print(f"Error: no *.stats files found in {stats_dir}", file=sys.stderr)
        sys.exit(1)

    for stats_file in stats_files:
        with stats_file.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                # expected format: "name hash"
                parts = line.split()
                if len(parts) >= 2:
                    key = f"{parts[0]} {parts[1]}"
                    counter[key] += 1

    # sort by count descending, then by name
    lines = [
        f"{count} {key}"
        for key, count in sorted(counter.items(), key=lambda x: (-x[1], x[0]))
    ]

    result = "\n".join(lines) + "\n"

    if output_path:
        output_path.write_text(result)
    else:
        print(result, end="")

if __name__ == "__main__":
    main()
