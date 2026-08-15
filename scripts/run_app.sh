#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/package_app.sh" >/dev/null
open "$ROOT_DIR/outputs/GHMenuBar.app"
