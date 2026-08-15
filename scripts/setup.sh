#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/swift_env.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "GHMenuBar is a macOS app; setup must run on macOS." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Missing Swift toolchain. Install Xcode or Command Line Tools first." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Warning: GitHub CLI is not installed. Install gh before running the app." >&2
elif ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "Warning: GitHub CLI is installed but not authenticated. Run: gh auth login -h github.com" >&2
fi

swift package "${SWIFTPM_CACHE_ARGS[@]}" resolve
swift build "${SWIFTPM_CACHE_ARGS[@]}"
swift test "${SWIFTPM_CACHE_ARGS[@]}"

echo "GHMenuBar setup complete."
