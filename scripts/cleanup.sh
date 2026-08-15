#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r line; do
  pid="${line%% *}"
  command="${line#* }"

  if [[ "$command" == "$ROOT_DIR/"* ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
done < <(ps -axo pid=,command= | awk '/GHMenuBar/ {print}')

rm -rf "$ROOT_DIR/.build" "$ROOT_DIR/outputs/GHMenuBar.app"

echo "GHMenuBar cleanup complete."
