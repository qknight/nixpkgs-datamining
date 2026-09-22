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

- `filter-rust.nix`: evaluates nixpkgs and selects derivations with Cargo vendoring or lock-file attributes
- `rust-eval.jsonl`: saved output from the nixpkgs evaluation
- `rust-packages.txt`: package attribute names selected from `rust-eval.jsonl`
- `architectures.nix`: counts the selected packages supported by each target architecture
- `extract-one/`: source extraction and dependency-analysis tools and data
  - `download-src.nix`: overrides one package build to save its `Cargo.toml`, `Cargo.lock`, and Cargo unit graph
  - `download-src.sh`: builds one package extraction
  - `.download_success` and `.download_failed`: package attributes grouped by extraction outcome
  - `unit-graph2stats.sh`: converts a Cargo unit graph into crate fingerprints for aggregation
  - `aggregate-stats.py`: combines per-package crate fingerprints into occurrence counts
  - `unit-graph2dep-counts.py`: counts internal, direct, and transitive dependencies in a unit graph
  - `unit-graph2dep-counts.stats`: saved dependency-count output for the analyzed packages
  - `compute_speedup.sh`: calculates total and unique crate builds from aggregated statistics
  - `results.tar.xz`: archived pre-generated extraction results; unpacking it avoids rebuilding every package
  - `stats/`: checked-in per-package crate fingerprint files
  - `results/` and `stats_with_deps/`: generated extraction and intermediate statistics directories
- `scan-nixpkgs-for-buildRustPackage-changes.py`: scans nixpkgs history for changes to the `buildRustPackage` probe derivation
- `rustPlatform.buildRustPackage-probe.nix`: minimal derivation used by the history scan
- `rustPlatform.buildRustPackage-probe-results-*.txt`: saved yearly probe results
- `docs/`: aggregated datasets, generated Plotly/D3 visualizations, and vendored browser libraries
- `flake.nix` and `flake.lock`: optional Nix development environment used to run OpenCode

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

* [📊 plotly graph of 2025 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages25.html) 
* [📊 Plotly graph of 2026 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages26.html)

highlights (2025):
- 62 `buildRustPackage` releases with 3 reverts, so: 62-3 ≈ 59  `buildRustPackage` releases
- analyzed 2312 of 2569 rust projects (~90%)
- average crates.io dependencies per project: 360909/2312 ≈ 156
- assume remaining projects have a similar average
- rust builds across architectures: 9087 = 2555 + 2517 + 2008 + 2007

assuming each relevant nixpkgs change affects `buildRustPackage`:
- crates.io compiles = rust projects × avg crates.io deps × releases
- crates.io compiles = 9087 × 156 × 59 ≈ 83,636,748

**during 2025, hydra.nixos.org supposedly compiled roughly 84 million crates.io dependencies and on top, the 9087 rust projects using them.**

for internal crates (we use the 2312 `buildRustPackage` results to estimate):
- architectures × internal crates from x86_64 × releases = internal crate compiles
- 4 × 8759 × 59 ≈ 2,067,124

**during 2025, hydra.nixos.org supposedly compiled roughly 2 million internal crates**

## **direct and indirect dependencies of the 2312 `buildRustPackage` rust projects**

```bash
python unit-graph2dep-counts.py atuin ./results/result-atuin/unit-graph
atuin 18.10.0 12 34 393

head -n 2600 .download_success | xargs -n 1 -I {} python unit-graph2dep-counts.py {} results/result-{}/unit-graph > transitive-deps.stats
```

finally copy the contents of ./transitive-deps.stats to docs/transitive-deps.html and open it in a webpage

* [📊 plotly graph of direct and indirect dependencies](https://qknight.github.io/nixpkgs-datamining/transitive-deps.html)

```
Project Analysis
Total Projects Analyzed: 2300

Average Internal Crates per Project: 3.8
Average Direct Dependencies per Project: 15.7
Average Transitive Dependencies per Project: 138.8

Overall Dependency Count

Total Internal Crates: 8759
Total Direct Dependencies: 36080
Total Transitive Dependencies: 319137

Total & Percentage Breakdown

Total Crates Count: 363976
Internal Crates: 2.4% of Total
Direct Dependencies: 9.9% of Total
Transitive Dependencies: 87.7% of Total
Combined Direct and Transitive Dependencies: 97.59% of Total
```

## crates.io dependencies of the 2312 `buildRustPackage` rust projects

using the script `unit-graph2stats.sh` we list all crates.io dependencies by name and hash where the hash consists of:

```python
fingerprint = f\"{name}|{version}|{features}\".encode()
new_hash = hashlib.sha256(fingerprint).hexdigest()[:16]
```

then these two files were created:

* [combined.stats](https://qknight.github.io/nixpkgs-datamining/combined.stats)
* [combined_shared-only.stats](https://qknight.github.io/nixpkgs-datamining/combined_shared-only.stats)

    the `combined_shared-only.stats` contains all the dependencies of 2312 analyzed rust projects but is filtered to contain only crates.io references which were used by more than one project (44248 shared dependencies)! 

    note: similarly, Rust projects often use multiple versions of a crate such as bitflags

a visualization of `combined_shared-only.stats` using d3 is here, **warning: long load time ~40s**:
* [📊 d3 graph of combined_shared-only.stats](https://qknight.github.io/nixpkgs-datamining/index.html)

compute speedup:
```bash
./compute_speedup.sh ../docs/combined.stats
computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607
```

averages and facts:
- average crates.io dependencies per project: 360909/2312 ≈ 156
- successful stats for 2312 of 2569 packages (257 missing)
- total crates.io builds estimated
- with cargo+libnix, instead of 360,909 we build only ~44,248 crates, likely ~8.1× fewer

additional implication:
- cargo+libnix can reuse intermediate crate builds (e.g., bitflags, syn, serde), so when compiling for the first time a rust project like `atuin` would then often only need to build the 'actual' changes while substituting crates.io dependencies from cache.
- on average one can expect that only about 1/8 of crates.io dependencies would have to be built locally due to uniqueness (versions/features), i.e., ~20 of 156:
```text
156/8 ≈ 20
```

## summary

using cargo+libnix could significantly reduce build times for crates.io dependencies via fine-grained build caching: 

* on average only ~12% of crates.io dependencies would need to be built locally 
* the remaining ~88% crates.io dependencies would be binary substitutes 

note: `cargo` by default will create rlib(s) from crates.io libraries and builds them into one binary statically (no as dynamic shared objects like .dll or .so). cargo+libnix does not change this behaviour but shares the build artifacts between rust projects in a global scale.

there are other interesting resources as [lib.rs](https://lib.rs/stats)

### caveats

* in nixpkgs `buildRustPackage` is always called with the same version of `cargo` and `rustc` which would be the minimal requirement to reuse crates between rust projects later using cargo+libnix
* the projected ~8.1× reduction, i.e. fewer crates need compilation, needs to be verified in practice because not all crates are equal and it requires that users are using the same cargo+rustc version as nixpkgs does.
* note: cargo+libnix compiles each crate in a sandbox, compilation is somewhat slower (~0.5× to ~0.7×)

## license

this project is provided as public domain work. All scripts, data, and additional content authored as part of this project are released under the [Creative Commons Zero v1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/) license, allowing for unrestricted copying, modification, and sharing.

### dependencies

- this project includes `d3.v7.min.js` and `plotly-4.0.0.min.js`, each of which may be subject to their own respective licenses:
  - **d3.js** by Mike Bostock is licensed under the [BSD-2-Clause license](https://github.com/d3/d3/blob/main/LICENSE).
  - **plotly.js** is licensed under the [MIT License](https://github.com/plotly/plotly.js/blob/main/LICENSE).

### note

a significant portion of this was generated with the assistance of AI models, including GPT 5 and GPT 5.6 Sol.
