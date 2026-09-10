# rust in nixpkgs ecosystem impact study

this project explores the impact of integrating libnix with the rust package manager, cargo, in nixpkgs and proposes potential build savings by using libnix.

see https://lastlog.de/libnix_cargo-libnix_release.html for details.

**this readme.md provides instructions to reproduce the study, based on nixpkgs 1c3d5a53f03f2eb5677f6f3b34f0ef31261ba485 from sat dec 13 13:17:29 2025**

## prerequisites

- nixos or a compatible nix environment

## project structure

- filter-rust.nix: nix script to filter rust packages from nixpkgs
- download-src.nix: nix script to extract cargo lock files
- unit-graph2stats.sh: shell script to convert dependency data into stats
- aggregate-stats.py: python script to aggregate statistics
- results.tar.xz: pre-generated nix-build results (optional shortcut)
- stats/: directory containing generated stats

## steps to reproduce

### identify rust packages using buildRustPackage
run the filter to find packages built with buildRustPackage.
```bash
nix run nixpkgs#nix-eval-jobs -- \
  --workers 4 \
  --max-memory-size 8192 \
  --force-recurse \
  --gc-roots-dir /tmp/gcroots \
  -E 'import ./filter-rust.nix {...};' > rust-eval.jsonl

jq -r 'select(.error == null and .drvPath != null) | .attr' rust-eval.jsonl | sort -u > rust-packages.txt
```

### extract cargo.lock and cargo.toml and generate unit-graph
use download-src.nix to obtain sources and emit the cargo unit-graph.
```bash
head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash nix-build download-src.nix {}
```
internally this calls:
```bash
cargo build --unit-graph -Z unstable-options > $out/unit-graph
```
note: you can extract pre-generated results from results.tar.xz to skip regeneration.

### convert the unit-graph to stats
generate dependency statistics per package.
```bash
head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash ./unit-graph2stats.sh results/result-{}/unit-graph stats_with_deps/{}.stats
```

### aggregate the statistics
combine per-package stats for visualization.
```bash
./aggregate-stats.py stats/ combined.stats
```
note: final aggregated stats are available in docs/combined.stats.

### generate non-unique statistics
```bash
cat combined.stats | grep -v '^1 .*' | sort -k2,2 -k1,1nr > combined_non-unique.stats
```

## architectures

evaluate supported systems (example output shown):
```bash
nix eval --json --file ./architectures.nix
```
{"allFour":2003,"evaluationFailures":0,"stats":[{"count":2555,"system":"x86_64-linux"},{"count":2517,"system":"aarch64-linux"},{"count":2008,"system":"x86_64-darwin"},{"count":2007,"system":"aarch64-darwin"}],"total":2569}

## frequency of buildRustPackage-related changes

we count changes that force re-evaluation/rebuilds, including stdenv, rustc/cargo updates, or nix changes in buildRustPackage.
```bash
python scan-nixpkgs-for-buildRustPackage-changes.py
```

* [plotly graph of 2025 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages25.html) 
* [Plotly graph of 2026 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages26.html)

highlights (2025):
- 62 releases, 3 reverts
- analyzed 2312 of 2569 rust projects (~90%)
- average crates.io dependencies per project: 360909/2312 ≈ 158
- assume remaining projects have a similar average
- rust builds across architectures: 9087 = 2555 + 2517 + 2008 + 2007

assuming each relevant nixpkgs change affects buildRustPackage:
- crates.io compiles = rust projects × avg crates.io deps × releases
- crates.io compiles = 9087 × 158 × 59 ≈ 84,709,014

so during 2025, hydra.nixos.org compiled roughly ~85 million crates.io dependencies.

## results and theoretical speedup

see the interactive stats (loads in ~40s):
- gh pages: https://qknight.github.io/nixpkgs-datamining/

compute speedup:
```bash
./compute_speedup.sh ../docs/combined.stats
# output:
# computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607
```

averages and facts:
- average crates.io dependencies per project: 360909/2312 ≈ 158
- successful stats for 2312 of 2569 packages (257 missing)
- total crates.io builds observed: ~360,909 targets (per project includes itself; we ignore -1)
- with cargo+libnix, only ~44,248 targets would build, yielding ~8.1× speedup

additional implication:
- cargo+libnix can reuse intermediate crate builds (e.g., bitflags, syn, serde), so editing a package like atuin would often only rebuild local changes while substituting dependencies from cache.
- on average, only about 1/8 of crates.io dependencies would build locally due to uniqueness (versions/features), i.e., ~20 of 158:
```text
158/8 ≈ 20
```

## summary

using cargo+libnix can significantly reduce build times via fine-grained caching: on average, only ~12% of crate dependencies need compilation. this also accelerates local development, where roughly ~20 of the ~158 average dependencies would build, with the rest substituted from cache.