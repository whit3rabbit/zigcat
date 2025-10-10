#!/usr/bin/env bash
# Build the zigcat Debian package using dpkg-buildpackage.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
  echo "dpkg-buildpackage is required to build the Debian package." >&2
  exit 1
fi

dpkg-buildpackage -us -uc "$@"
