# rust in nixpkgs ecosystem impact study

this repository holds the scripts and data used to explore the impact of integrating nix into cargo, i.e. cargo+libnix.

**this readme.md provides instructions to reproduce the study, based on nixpkgs 1c3d5a53f03f2eb5677f6f3b34f0ef31261ba485 from sat dec 13 13:17:29 2025**

see https://lastlog.de/libnix_cargo-libnix_release.html for details.

## rust projects

this study analyzed 2312 of 2569 rust projects (~90%), see the results.tar.xz contained. the remaining 10% did not produce a Cargo.lock|Cargo.toml|unit-graph which could be analyzed.

* [rust packages included](https://github.com/qknight/nixpkgs-datamining/blob/master/extract-one/.download_success)
* [rust packages excluded](https://github.com/qknight/nixpkgs-datamining/blob/master/extract-one/.download_failed)

## prerequisites

- nixos or a compatible nix environment
- `git clone https://github.com/NixOS/nixpkgs.git`
- `cd nixpkgs; git checkout 1c3d5a53f03f2eb5677f6f3b34f0ef31261ba485`

optionally i used [opencode](https://opencode.ai/) from the flake.nix for some queries, run:

- `nix develop`

## project structure

- filter-rust.nix: nix script to filter rust packages from nixpkgs
- download-src.nix: nix script to extract cargo lock files
- unit-graph2stats.sh: shell script to convert dependency data into stats
- aggregate-stats.py: python script to aggregate statistics
- results.tar.xz: pre-generated nix-build results (optional shortcut)
- stats/: directory containing generated stats

this project turnt from easy to complex and i'm sorry for the scripts all over the place.

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
cat combined.stats | grep -v '^1 .*' | sort -k2,2 -k1,1nr > combined_shared-only.stats
```

## architectures

evaluate supported systems (example output shown):
```bash
nix eval --json --file ./architectures.nix

"x86_64-linux" - 2555
"aarch64-linux" - 2517
"x86_64-darwin" - 2008
"aarch64-darwin" - 2007
```

## `buildRustPackage` frequency of updates

we count changes that force re-evaluation/rebuilds, including stdenv, rustc/cargo updates, or nix changes in buildRustPackage.
```bash
python scan-nixpkgs-for-buildRustPackage-changes.py
```

* [plotly graph of 2025 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages25.html) 
* [Plotly graph of 2026 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages26.html)

highlights (2025):
- 62 releases with 3 being reverted: 62-3 ≈ 59 releases
- analyzed 2312 of 2569 rust projects (~90%)
- average crates.io dependencies per project: 360909/2312 ≈ 158
- assume remaining projects have a similar average
- rust builds across architectures: 9087 = 2555 + 2517 + 2008 + 2007

assuming each relevant nixpkgs change affects `buildRustPackage`:
- crates.io compiles = rust projects × avg crates.io deps × releases
- crates.io compiles = 9087 × 158 × 59 ≈ 84,709,014

so during 2025, hydra.nixos.org compiled roughly 85 million crates.io dependencies.

## crates.io dependencies of the 2312 `buildRustPackage` rust projects

using the script `unit-graph2stats.sh` we list all crates.io dependencies by name and hash where the hash consists of:

```python
fingerprint = f\"{name}|{version}|{features}\".encode()
new_hash = hashlib.sha256(fingerprint).hexdigest()[:16]
```

then these two files were created:

* [combined.stats](https://qknight.github.io/nixpkgs-datamining/combined.stats)
* [combined_shared-only.stats](https://qknight.github.io/nixpkgs-datamining/combined_shared-only.stats)

    the `combined_shared-only.stats` combines all the dependencies of 2312 analyzed rust projects but is filtered to contain only crates.io references which were used by more than one project (44248 shared dependencies)! 

    note: similar in npm, rust project nowadays often use more than one version of `bitflags` in one project.

a visualization of `combined_shared-only.stats` using d3 is here, **warning: long load time ~40s**:
* [d3 graph of combined_shared-only.stats](https://qknight.github.io/nixpkgs-datamining/index.html)

compute speedup:
```bash
./compute_speedup.sh ../docs/combined.stats
# output:
# computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607
```

averages and facts:
- average crates.io dependencies per project: 360909/2312 ≈ 158
- successful stats for 2312 of 2569 packages (257 missing)
- total crates.io builds estimated
- with cargo+libnix reduced to ~44,248 crates, likely ~8.1× less

additional implication:
- cargo+libnix can reuse intermediate crate builds (e.g., bitflags, syn, serde), so when compiling for the first time a rust project like `atuin` would then often only need to build the 'actual' changes while substituting crates.io dependencies from cache.
- on average one can expect that only about 1/8 of crates.io dependencies would have to be built locally due to uniqueness (versions/features), i.e., ~20 of 158:
```text
158/8 ≈ 20
```

## summary

using cargo+libnix could significantly reduce build times via fine-grained caching: 

* on average ~12% of crate dependencies would need to be compiled locally 
* the remaining ~88% crates.io dependencies would be binary substitutes 

**this would accelerate local development! for example, from the ~158 average dependencies, roughly only ~20 would be built locally and the rest ~138 are downloaded substitutes from cache.**

### caveats

* in nixpkgs `buildRustPackage` is always called with the same version of `cargo` and `rustc` which would be the minimal requirement to reuse crates between rust projects later using cargo+libnix
* the claimed ~8.1× speedup, i.e. less crates need compilation, needs to be verified in practice because not all crates are equal
* since cargo+libnix compiles each crate in a sandbox, compilation is slower with 0.5× panelty