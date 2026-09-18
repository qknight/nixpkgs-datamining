#!/usr/bin/env python3
import json
import sys
from pathlib import Path

def parse_pkg_id(pkg_id: str):
    # Handles common Cargo pkg_id formats:
    # 1) "name version (source)"
    # 2) "registry+url#name@version"
    # 3) "path+url/.../name#version" (e.g., path sources)
    #
    # Returns (name, version) or (None, None) if not parseable.
    try:
        s = pkg_id.strip()

        # Case 1: "name version (source)"
        parts = s.split()
        if len(parts) >= 2 and "(" in s and ")" in s:
            return parts[0], parts[1]

        # Case 2/3: "...#tail"
        if "#" in s:
            left, tail = s.rsplit("#", 1)
            # "...#name@version"
            if "@" in tail:
                name, version = tail.split("@", 1)
                return name, version
            # ".../name#version"
            version = tail
            # Try to derive name from URL/path left side
            candidate = left
            # If scheme is like "path+file://", take the URL part after '+'
            if "+" in candidate:
                candidate = candidate.split("+", 1)[1]
            # Extract last path segment
            try:
                from urllib.parse import urlparse, unquote
                p = urlparse(candidate)
                segs = [seg for seg in p.path.split("/") if seg]
                if segs:
                    name = unquote(segs[-1])
                else:
                    name = candidate.rsplit("/", 1)[-1]
            except Exception:
                name = candidate.rsplit("/", 1)[-1]
            if name.endswith(".git"):
                name = name[:-4]
            return name, version

        # Fallback: if it still looks like "name version"
        if len(parts) >= 2:
            return parts[0], parts[1]
    except Exception:
        pass
    return None, None


def kind_of(unit):
    return list(unit.get("target", {}).get("kind", []) or [])

def mode_of(unit):
    m = unit.get("mode", "build")
    if isinstance(m, dict):
        m = m.get("kind", m.get("name", "build"))
    return str(m).lower()

# Mirror filters used in unit-graph2stats.sh
SKIP_MODES = {"test", "doctest", "doc", "docscrape", "check", "run"}
SKIP_KINDS = {"test", "bench", "example", "example-lib"}

def is_accepted(unit, idx, root_index):
    if mode_of(unit) in SKIP_MODES:
        return False
    kinds = kind_of(unit)
    if set(kinds) & SKIP_KINDS:
        return False
    # Skip non-root bins (avoid counting all binaries in a workspace)
    if "bin" in kinds and idx != root_index:
        return False
    return True

def is_crates_io(pkg_id: str) -> bool:
    """
    Returns True iff the pkg_id points to crates.io (registry+...crates.io-index).
    Handles both "name version (registry+...)" and "registry+...#name@version" formats.
    """
    try:
        s = (pkg_id or "").strip()
        # Common indicator for crates.io across Cargo pkg_id shapes
        return ("registry+" in s) and ("crates.io-index" in s)
    except Exception:
        return False


def is_project_crate(name: str, pkg_id: str, software_name: str) -> bool:
    """
    Treat as a project crate if:
    - It is NOT from crates.io (e.g., path, git, alt registry), or
    - It is from crates.io but appears to be a project fork, heuristically detected
      by name == software_name or name starts with f"{software_name}-".
    """
    try:
        if not is_crates_io(pkg_id):
            return True
        n = (name or "").lower().replace("_", "-")
        s = (software_name or "").lower().replace("_", "-")
        return n == s or n.startswith(s + "-")
    except Exception:
        return False

def main(software_name: str, unit_graph_path: str):
    data = json.loads(Path(unit_graph_path).read_text())
    units = data.get("units", [])
    if not units:
        print("Error: no units in graph", file=sys.stderr)
        sys.exit(1)

    unit_by_index = {i: u for i, u in enumerate(units)}

    roots = data.get("roots", [])
    if roots and isinstance(roots[0], dict):
        roots = [r.get("index", r.get("id")) for r in roots]
    bin_roots = [i for i in roots if i in unit_by_index and "bin" in kind_of(unit_by_index[i])]
    root_index = (bin_roots or roots or [0])[0]
    root_unit = unit_by_index.get(root_index, {})

    root_pkg_id = root_unit.get("pkg_id", "") or ""
    proj_name, proj_version = parse_pkg_id(root_pkg_id)
    if not proj_name:
        # Last-ditch fallback to something readable
        proj_name = (root_pkg_id.split()[:1] or ["unknown"])[0]
    if not proj_version:
        # Try to salvage version from common "name version (source)" form
        parts = root_pkg_id.split()
        if len(parts) >= 2:
            proj_version = parts[1]

    # Traverse from root to collect all reachable units
    visited = set()
    stack = [root_index]
    while stack:
        idx = stack.pop()
        if idx in visited or idx not in unit_by_index:
            continue
        visited.add(idx)
        for dep in unit_by_index[idx].get("dependencies", []):
            d = dep.get("index")
            if d is not None:
                stack.append(d)

    # Choose a "best" unit per (name, version) for all accepted crates (used for project count)
    best_all = {}
    for index in visited:
        unit = unit_by_index[index]
        if not is_accepted(unit, index, root_index):
            continue
        name, version = parse_pkg_id(unit.get("pkg_id", "")) or (None, None)
        if not name:
            continue
        for_host = bool(unit.get("for_host", False))
        is_build_script = "custom-build" in kind_of(unit)
        score = (for_host, is_build_script, index)  # lower is better
        key = (name, version)
        prev = best_all.get(key)
        if prev is None or score < prev[0]:
            best_all[key] = (score, index)

    # Project crates = all accepted non-crates.io + crates.io forks by name heuristic
    project_keys = set()
    for (name, version), (_score, idx) in best_all.items():
        u = unit_by_index[idx]
        if is_project_crate(name, u.get("pkg_id", ""), software_name):
            project_keys.add((name, version))
    project_count = len(project_keys)

    # Existing logic: choose a "best" unit per (name, version), excluding the root itself,
    # but only for crates.io crates (used for direct/transitive counts)
    best = {}
    for index in visited:
        if index == root_index:
            continue  # exclude the project itself from dependency counts
        unit = unit_by_index[index]
        if not is_accepted(unit, index, root_index):
            continue

        # Only count crates from crates.io
        if not is_crates_io(unit.get("pkg_id", "")):
            continue

        name, version = parse_pkg_id(unit.get("pkg_id", "")) or (None, None)
        if not name:
            continue

        for_host = bool(unit.get("for_host", False))
        is_build_script = "custom-build" in kind_of(unit)
        score = (for_host, is_build_script, index)  # lower is better
        key = (name, version)
        prev = best.get(key)
        if prev is None or score < prev[0]:
            best[key] = (score, index)

    all_keys = set(best.keys())

    # Collect direct dependency keys (by immediate edges from root) after filtering
    direct_dep_indices = {dep.get("index") for dep in root_unit.get("dependencies", []) if dep.get("index") is not None}
    direct_keys = set()
    for di in direct_dep_indices:
        if di not in unit_by_index or di == root_index:
            continue
        du = unit_by_index[di]
        if not is_accepted(du, di, root_index):
            continue
        # Only consider direct crates.io crates
        if not is_crates_io(du.get("pkg_id", "")):
            continue
        name, version = parse_pkg_id(du.get("pkg_id", "")) or (None, None)
        if not name:
            continue
        direct_keys.add((name, version))

    # Only count direct dependencies that are part of the accepted (crates.io) set
    direct_keys &= all_keys
    direct_count = len(direct_keys)
    transitive_count = len(all_keys - direct_keys)

    # Output: name version project direct transitive
    print(f"{software_name} {proj_version} {project_count} {direct_count} {transitive_count}")# - {unit_graph_path}

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {Path(sys.argv[0]).name} <software-name> <unit-graph-file>", file=sys.stderr)
        sys.exit(1)
    software_name = sys.argv[1]
    unit_graph_path = sys.argv[2]
    main(software_name, unit_graph_path)