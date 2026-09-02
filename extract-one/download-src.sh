#!/usr/bin/env bash

mkdir -p results

if [ $# -ne 1 ]; then
  echo "Usage: $0 <nix package>" >&2
  exit 1
fi

echo "------------ downloading $1 -------------------"

attr="$1"
success_file=".download_success"
failed_file=".download_failed"
touch "$success_file" "$failed_file"

# Run build and decide success based on nix-build output/exit status
if nix-build download-src.nix \
  --quiet \
  --argstr attr "$attr" \
  -o "results/result-$attr"; then
  # Success: ensure present in .download_success and absent in .download_failed
  if ! grep -Fxq "$attr" "$success_file"; then
    echo "$attr" >> "$success_file"
  fi
  if grep -Fxq "$attr" "$failed_file"; then
    # Safely remove exact line from failed file
    sed -i.bak "/^$(printf '%s' "$attr" | sed 's:[][\\/.*^$]:\\&:g')\$/d" "$failed_file" && rm -f "$failed_file.bak"
  fi
  echo "Download SUCCESS for $attr"
else
  # Failure: ensure present in .download_failed and absent in .download_success
  if ! grep -Fxq "$attr" "$failed_file"; then
    echo "$attr" >> "$failed_file"
  fi
  if grep -Fxq "$attr" "$success_file"; then
    # Safely remove exact line from success file
    sed -i.bak "/^$(printf '%s' "$attr" | sed 's:[][\\/.*^$]:\\&:g')\$/d" "$success_file" && rm -f "$success_file.bak"
  fi
  echo "Download FAILED for $attr" >&2
fi
