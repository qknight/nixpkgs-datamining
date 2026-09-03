# Rust Ecosystem Impact Study with libnix

This project explores the impact of integrating libnix with the Rust package manager, Cargo. It demonstrates how libnix could streamline crate management and improve build efficiency. 

This README.md provides instructions on how to reproduce the results and describes the project structure.

## Prerequisites

- [NixOS](https://nixos.org/) or a compatible Nix environment
- Python 3.x
- [jq](https://stedolan.github.io/jq/)
- Required Python packages: `squarify` and `matplotlib`

## Project Structure

- `filter-rust.nix`: Nix script to filter Rust packages from nixpkgs.
- `extract-one.nix`: Nix script to extract cargo lock files.
- `deps2stats.sh`: Shell script to convert dependency data into stats.
- `aggregate-stats.py`: Python script to aggregate statistics from multiple files.
- `treemap_stats.py`: Python script to visualize data as a treemap.
- `results.tar.xz`: Compressed file containing pre-generated results for convenience.
- `stats/`: Directory containing generated stats.
- `extract-one/`: Directory with final datasets including `combined.stats` and `combined_none-unique.stats`.

## Steps to Reproduce

1. **Filter Rust Packages**:
   Run the filter script to identify Rust packages compiled with `buildRustPackage`.
   ```bash
   nix run nixpkgs#nix-eval-jobs -- \
     --workers 4 \
     --max-memory-size 8192 \
     --force-recurse \
     --gc-roots-dir /tmp/gcroots \
     -E 'import ./filter-rust.nix {...};' > rust-eval.jsonl
   
   jq -r 'select(.error == null and .drvPath != null) | .attr' rust-eval.jsonl \
     | sort -u > rust-packages.txt
   ```

2. **Extract Cargo Lock Files**:
   Use `extract-one.nix` to obtain Cargo.lock files.
   ```bash
   nix-build extract-one.nix --argstr attr aba -o aba
   ```

3. **Convert Dependencies to Stats**:
   Run the script to extract dependency statistics.
   ```bash
   head -n 2600 ../rust-packages.txt | xargs -n 1 -I {} bash ./deps2stats.sh result-{} {}.stats
   ```

4. **Aggregate the Statistics**:
   Use the Python script to aggregate statistics for visualization.
   ```bash
   ./aggregate-stats.py stats/ combined.stats
   ```
   You can extract the pre-generated results from `results.tar.xz` to avoid regenerating them.

5. **Generate Treemap Visualization**:
   Create a treemap to visualize dependency usage.
   ```bash
   python treemap_stats.py combined.stats
   ```

6. **View Results**:
   The final aggregated stats are available in `docs/combined.stats`.

   One can see the graph here, 40 seconds loading time:

         ./compute_speedup.sh ../docs/combined.stats 
         Computed totals from ../docs/combined.stats: total_builds=360909, shared_builds=44248, speedup=8.156504248779607

   [GH pages stats page](https://qknight.github.io/nixpkgs-datamining/)