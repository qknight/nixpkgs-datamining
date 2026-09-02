#!/usr/bin/env sh
set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <unit-graph-file> <output-stats-file>" >&2
  exit 1
fi

UNIT_GRAPH="$1"
OUTPUT_FILE="$2"

if [ ! -f "$UNIT_GRAPH" ]; then
  echo "Error: unit graph not found: $UNIT_GRAPH" >&2
  exit 1
fi

nix-shell -p python3 --run "python3 - <<EOF
import json, hashlib, sys
from pathlib import Path

graph_path = Path(\"$UNIT_GRAPH\")
out_path   = Path(\"$OUTPUT_FILE\")

data = json.loads(graph_path.read_text())
units = data.get(\"units\", [])
if not units:
    print(\"Error: no units in graph\", file=sys.stderr)
    sys.exit(1)

def parse_pkg_id(pkg_id):
    if \"#\" in pkg_id and \"@\" in pkg_id.rsplit(\"#\", 1)[-1]:
        try:
            package = pkg_id.rsplit(\"#\", 1)[1]
            return package.rsplit(\"@\", 1)
        except ValueError:
            pass
    parts = pkg_id.split()
    if len(parts) >= 2:
        return parts[0], parts[1]
    return None, None

def kind_of(unit):
    return list(unit.get(\"target\", {}).get(\"kind\", []) or [])

def mode_of(unit):
    m = unit.get(\"mode\", \"build\")
    if isinstance(m, dict):
        m = m.get(\"kind\", m.get(\"name\", \"build\"))
    return str(m).lower()

SKIP_MODES = {\"test\", \"doctest\", \"doc\", \"docscrape\", \"check\", \"run\"}
SKIP_KINDS = {\"test\", \"bench\", \"example\", \"example-lib\"}

unit_by_index = {i: u for i, u in enumerate(units)}
roots = data.get(\"roots\", [])
if roots and isinstance(roots[0], dict):
    roots = [r.get(\"index\", r.get(\"id\")) for r in roots]

bin_roots = [
    i for i in roots
    if i in unit_by_index and \"bin\" in kind_of(unit_by_index[i])
]
root_index = (bin_roots or roots or [0])[0]

visited = set()
stack = [root_index]
while stack:
    idx = stack.pop()
    if idx in visited or idx not in unit_by_index:
        continue
    visited.add(idx)
    for dep in unit_by_index[idx].get(\"dependencies\", []):
        d = dep.get(\"index\")
        if d is not None:
            stack.append(d)

# name@version -> best unit (prefer target lib over host / build-script)
best = {}
for index in visited:
    unit = unit_by_index[index]
    if mode_of(unit) in SKIP_MODES:
        continue
    kinds = kind_of(unit)
    if set(kinds) & SKIP_KINDS:
        continue
    if \"bin\" in kinds and index != root_index:
        continue

    name, version = parse_pkg_id(unit.get(\"pkg_id\", \"\"))
    if not name:
        continue

    for_host = bool(unit.get(\"for_host\", False))
    is_build_script = \"custom-build\" in kinds
    # lower score is better
    score = (for_host, is_build_script, index)
    key = (name, version)
    prev = best.get(key)
    if prev is None or score < prev[0]:
        best[key] = (score, unit)

lines = []
for (name, version), (_, unit) in sorted(best.items()):
    features = sorted(unit.get(\"features\", []))
    fingerprint = f\"{name}|{version}|{features}\".encode()
    new_hash = hashlib.sha256(fingerprint).hexdigest()[:16]
    lines.append(f\"{name} {new_hash}\")

out_path.write_text(\"\\n\".join(lines) + (\"\\n\" if lines else \"\"))
print(f\"Unique crates: {len(lines)}\", file=sys.stderr)
EOF"    