# Rust Ecosystem Impact Study with libnix

This project explores the impact of integrating libnix with the Rust package manager, Cargo. It demonstrates how libnix could streamline crate management and improve build efficiency. 

This README.md provides instructions on how to reproduce the results and describes the project structure.

## Prerequisites

- [NixOS](https://nixos.org/) or a compatible Nix environment

## Project Structure

- `filter-rust.nix`: Nix script to filter Rust packages from nixpkgs.
- `download-src.nix`: Nix script to extract cargo lock files.
- `unit-graph2stats.sh`: Shell script to convert dependency data into stats.
- `aggregate-stats.py`: Python script to aggregate statistics from multiple files.
- `treemap_stats.py`: Python script to visualize data as a treemap.
- `results.tar.xz`: Compressed file containing pre-generated nix-build results for convenience.
- `stats/`: Directory containing generated stats.
- `download-src/`: Directory with final datasets including `combined.stats` and `combined_none-unique.stats`.

## Steps to Reproduce

1. **Identify Rust Packages using buildRustPackage**:
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

2. **Extract Cargo.lock and Cargo.toml and generate unit-graph**:
   Use `download-src.nix` to obtain Cargo.lock files.
   ```bash
   head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash nix-build download-src.nix {}
   ```
   Internally this calls `cargo build --unit-graph -Z unstable-options > $out/unit-graph`

   **Note: You can extract the pre-generated results from `results.tar.xz` to avoid regenerating them.**

3. **Convert the unit-graph to Stats**:
   Run the script to extract dependency statistics.
   ```bash
   head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash ./unit-graph2stats.sh results/result-{}/unit-graph stats_with_deps/{}.stats
   ```

4. **Aggregate the Statistics**:
   Use the Python script to aggregate statistics for visualization.
   ```bash
   ./aggregate-stats.py stats/ combined.stats
   ```

5. **Results & theoretical speedup**:
   The final aggregated stats are available in `docs/combined.stats`.

   One can see the graph here, 40 seconds loading time:

         ./compute_speedup.sh ../docs/combined.stats 
         Computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607

   Average crate.io dependencies:

         360909/2312 = 158

   The result states that the 2312 out of the 2569 packages were downloaded successfully and these create none uniq 360909 dependency builds 
   (ignoring internal crate builds). If we would have used cargo+libnix we would have had to compile 44248 only making a speedup of
   about ~ 8.1 and these intermediate build artifacts could also be used on the client side later on, so a new developer would not have
   to compile the **average 156 crate.io dependencies** but only 158/8 = ~20 instead.

   [GH pages stats page](https://qknight.github.io/nixpkgs-datamining/)