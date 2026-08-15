#!/usr/bin/env bash

if [[ -z "${ROOT_DIR:-}" ]]; then
  echo "ROOT_DIR must be set before sourcing scripts/swift_env.sh" >&2
  exit 1
fi

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT_DIR/.build/cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/cache/clang/ModuleCache}"
SWIFTPM_CACHE_ARGS=(--cache-path "$ROOT_DIR/.build/swiftpm-cache")

mkdir -p "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$ROOT_DIR/.build/swiftpm-cache"
