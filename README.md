# Rust in nixpkgs ecosystem impact study

this project explores the impact of integrating libnix with the rust package manager, cargo in nixpkgs and proposes potential savings with using libnix instead. 

see https://lastlog.de/libnix_cargo-libnix_release.html for details.

**this README.md provides instructions on how to reproduce the results of the study and is based on nixpkgs 1c3d5a53f03f2eb5677f6f3b34f0ef31261ba485 from Sat Dec 13 13:17:29 2025**

## prerequisites

- [NixOS](https://nixos.org/) or a compatible Nix environment

## Project Structure

- `filter-rust.nix`: Nix script to filter Rust packages from nixpkgs.
- `download-src.nix`: Nix script to extract cargo lock files.
- `unit-graph2stats.sh`: Shell script to convert dependency data into stats.
- `aggregate-stats.py`: Python script to aggregate statistics from multiple files.
- `results.tar.xz`: Compressed file containing pre-generated nix-build results for convenience.
- `stats/`: Directory containing generated stats.

# Steps to Reproduce

## **Identify Rust Packages using buildRustPackage**:
   Run the filter script to identify Rust packages compiled with `buildRustPackage`.
   ```bash
   nix run nixpkgs#nix-eval-jobs -- \
     --workers 4 \
     --max-memory-size 8192 \
     --force-recurse \
     --gc-roots-dir /tmp/gcroots \
     -E 'import ./filter-rust.nix {...};' > rust-eval.jsonl
   
   jq -r 'select(.error == null and .drvPath != null) | .attr' rust-eval.jsonl | sort -u > rust-packages.txt
   ```

## **Extract Cargo.lock and Cargo.toml and generate unit-graph**:
   Use `download-src.nix` to obtain Cargo.lock files.
   ```bash
   head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash nix-build download-src.nix {}
   ```
   Internally this calls `cargo build --unit-graph -Z unstable-options > $out/unit-graph`

   **Note: You can extract the pre-generated results from `results.tar.xz` to avoid regenerating them.**

## **Convert the unit-graph to Stats**:
   Run the script to extract dependency statistics.
   ```bash
   head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash ./unit-graph2stats.sh results/result-{}/unit-graph stats_with_deps/{}.stats
   ```

## **Aggregate the Statistics**:
   Use the Python script to aggregate statistics for visualization.
   ```bash
   ./aggregate-stats.py stats/ combined.stats
   ```
   Note: The final aggregated stats are available in `docs/combined.stats`.

## **generate non-unique statistics**
   ```bash
   cat combined.stats | grep -v '^1 .*' | sort -k2,2 -k1,1nr > combined_non-unique.stats
   ```

## **architectures**

   nix eval --json --file ./architectures.nix
   {"allFour":2003,"evaluationFailures":0,"stats":[{"count":2555,"system":"x86_64-linux"},{"count":2517,"system":"aarch64-linux"},{"count":2008,"system":"x86_64-darwin"},{"count":2007,"system":"aarch64-darwin"}],"total":2569}

## **identify `buildRustPackage` changes leading to forced new evaluation**

   Next we need to find out how often `buildRustPackage` changes. Changes include:
   * stdenv
   * rustc, cargo updates
   * changes to the `buildRustPackage` nix implementation

         python scan-nixpkgs-for-buildRustPackage-changes.py 
   
   with a checkout of nixpkgs will just do that.

   The results show how often dependencies of `buildRustPackage` have to be rebuilt, i've created a [Plotly graph of 2025 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages25.html) and a [Plotly graph of 2026 for buildRustPackage](https://qknight.github.io/nixpkgs-datamining/buildRustPackages26.html)

   * using the numbers from year 2025
   * 62 releases
   * 3 reverts 
   * analyzed 2312 projects of 2569 (~90%)
   * 158 = 360909/2312 = Average crate.io dependencies per project
   * assuming 2569 rust projects also shares ~ 158 crates.io dependencies
   * rust projects (built for different architectures): 9087 = 2555 + 2517 + 2008 + 2007

   now, assuming each change in nixpkgs affecting a `buildRustPackages` change, then:

   * creates.io compiles = rust projects * average crates.io dependencies * architectures * releases
   * creates.io compiles = 9087 * 158 * 59 = 84709014 

   so during **2025 hydra.nixos.org compiled roughtly ~85 million crates.io dependencies**

## **results & theoretical speedup**:

   One can see the graph here, 40 seconds loading time:

   [GH pages stats page](https://qknight.github.io/nixpkgs-datamining/)

         ./compute_speedup.sh ../docs/combined.stats 
         Computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607

   Average crate.io dependencies:

         360909/2312 = 158

   Facts:

   * The ./results/ folder contained successful downloads & stats builds of **2312 out of the 2569 packages** (257 rust projects unaccounted for)
   * **All crate.io builds around 360909 targets** (think results per rust project also contains itself, so -1 but we ignore that for now)
   * **if we would use cargo+libnix we would have to compile only 44248 targets**, instead of all the 360909, **granting a speedup of about ~ 8.1**
   
   In addition to this:

   When using cargo+libnix we could reuse the intermediate build artifacts, i.e. the single dependency crate builds (bitflags, syn, serde, ...)! 
   That said, when one wants to patch a software like `atuin` the build then would only compile your change and binary-subtitude all the crate.io dependencies!
   
   On average this would mean you would only compile 1/8 of the crates.io dependencies because of unique constrains like exotic new or old versions or feature configurations which are seldom:
   
         158/8 = ~20

# Summary

using cargo+libnix could hugely speed up the build times due to fine grained caching. using cargo+libnix, in other words, one only needs to compile 12% of all the crate dependencies on average. it is important to note that a typical rust project consists of one or several additional crates which are compiled into a rlib and a binary.

Additionally cargo+libnix will speed up development because on average only 20 of the 158 average dependencies need to be build locally - statistically and the others can be downloaded.