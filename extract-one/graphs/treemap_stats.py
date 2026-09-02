#!/usr/bin/env python3
import sys
import matplotlib.pyplot as plt
import squarify
import matplotlib.colors as mcolors
from collections import defaultdict

def load_data(filename=None):
    """
    Expects lines:  <count> <name> [<hash>]
    Returns list of (count, label)
    """
    data = []
    source = open(filename) if filename else sys.stdin
    for line in source:
        line = line.strip()
        if not line:
            continue
        parts = line.split(maxsplit=2)
        if len(parts) >= 2:
            try:
                count = int(parts[0])
                name  = parts[1]
                data.append((count, name))
            except ValueError:
                continue
    if filename:
        source.close()
    # keep only positive counts and sort descending (nice for colouring)
    data = [(c, n) for c, n in data if c > 0]
    data.sort(key=lambda x: x[0], reverse=True)
    return data

def make_treemap(data, outfile="treemap.svg", title="Identical rlib configurations",
                 max_labels=40, min_size_for_label=5):
    if not data:
        print("No data")
        return

    sizes  = [d[0] for d in data]
    labels = [d[1] for d in data]

    # Colour by size (bigger = more intense)
    norm = mcolors.Normalize(vmin=min(sizes), vmax=max(sizes))
    cmap = plt.cm.Blues
    colors = [cmap(norm(s)) for s in sizes]

    # Only put text on the larger rectangles so the image stays readable
    display_labels = []
    for s, lab in zip(sizes, labels):
        if s >= min_size_for_label and len(display_labels) < max_labels:
            display_labels.append(f"{lab}\n{s}")
        else:
            display_labels.append("")

    fig = plt.figure(figsize=(16, 10))
    ax = fig.add_subplot(111)

    squarify.plot(sizes=sizes,
                  label=display_labels,
                  color=colors,
                  alpha=0.85,
                  text_kwargs={"fontsize": 7, "color": "black"},
                  ax=ax,
                  pad=True)

    ax.set_title(title, fontsize=14, pad=12)
    ax.axis("off")
    plt.tight_layout()
    plt.savefig(outfile, dpi=160, bbox_inches="tight")
    print(f"Saved → {outfile}")
    print(f"Total items: {len(data)}   |   Top size: {sizes[0]}")

if __name__ == "__main__":
    filename = sys.argv[1] if len(sys.argv) > 1 else None
    data = load_data(filename)
    make_treemap(data)
