#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

pkill -x GHMenuBar 2>/dev/null || true
sleep 1

"$ROOT_DIR/scripts/package_app.sh" >/dev/null
open -n "$ROOT_DIR/outputs/GHMenuBar.app"
