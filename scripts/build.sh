#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/swift_env.sh"

swift build "${SWIFTPM_CACHE_ARGS[@]}"
