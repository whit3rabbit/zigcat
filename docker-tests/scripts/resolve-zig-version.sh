#!/bin/sh

# Resolve the Zig version to download.
# Usage: resolve-zig-version.sh [requested-version]
# If requested version is empty or "latest", fetch the current stable version
# from ziglang.org/download/index.json. Falls back to DEFAULT_ZIG_VERSION on failure.

set -eu

REQUESTED="${1:-}"
DEFAULT_ZIG_VERSION="${DEFAULT_ZIG_VERSION:-0.15.1}"

# Helper: download the Zig index JSON using wget or curl
download_index() {
    if command -v wget >/dev/null 2>&1; then
        wget -qO- https://ziglang.org/download/index.json || return 1
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL https://ziglang.org/download/index.json || return 1
    else
        return 1
    fi
}

if [ -n "$REQUESTED" ] && [ "$REQUESTED" != "latest" ]; then
    printf '%s\n' "$REQUESTED"
    exit 0
fi

if INDEX_JSON=$(download_index); then
    STABLE_VERSION=$(printf '%s' "$INDEX_JSON" | sed -n 's/.*"stable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -n "$STABLE_VERSION" ]; then
        printf '%s\n' "$STABLE_VERSION"
        exit 0
    fi
fi

printf 'Warning: unable to resolve latest Zig version, using default %s\n' "$DEFAULT_ZIG_VERSION" >&2
printf '%s\n' "$DEFAULT_ZIG_VERSION"
