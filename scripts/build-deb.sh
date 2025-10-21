#!/usr/bin/env bash
# Build the zigcat Debian package
# Supports both native Linux builds and Docker-based builds (macOS/other platforms)
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# Detect if we're on Linux with native tools
if [[ "$(uname -s)" == "Linux" ]] && command -v dpkg-buildpackage >/dev/null 2>&1; then
  echo "Building Debian package natively on Linux..."

  # Check for Zig
  if ! command -v zig >/dev/null 2>&1; then
    echo "ERROR: Zig is required to build the package." >&2
    echo "" >&2
    echo "Please install Zig 0.15.1 or later:" >&2
    echo "  wget https://ziglang.org/download/0.15.1/zig-linux-$(uname -m)-0.15.1.tar.xz" >&2
    echo "  sudo tar -xf zig-linux-$(uname -m)-0.15.1.tar.xz -C /usr/local" >&2
    echo "  sudo ln -sf /usr/local/zig-linux-$(uname -m)-0.15.1/zig /usr/local/bin/zig" >&2
    exit 1
  fi

  # Check Zig version
  ZIG_VERSION="$(zig version)"
  echo "Found Zig ${ZIG_VERSION}"

  # Check for debhelper (using dpkg-query which is more reliable)
  if ! dpkg-query -W -f='${Status}' debhelper 2>/dev/null | grep -q "install ok installed"; then
    echo "ERROR: debhelper is required to build the package." >&2
    echo "" >&2
    echo "Install with:" >&2
    echo "  sudo apt-get install debhelper" >&2
    exit 1
  fi

  # Check for libssl-dev (using dpkg-query which is more reliable)
  if ! dpkg-query -W -f='${Status}' libssl-dev 2>/dev/null | grep -q "install ok installed"; then
    echo "WARNING: libssl-dev not found. Install with:" >&2
    echo "  sudo apt-get install libssl-dev" >&2
  fi

  # Build package (no dependency check needed since Zig isn't in APT)
  dpkg-buildpackage -us -uc "$@"

  echo ""
  echo "✓ Debian package built successfully!"
  echo ""
  echo "Package files:"
  ls -lh ../*.deb 2>/dev/null || true
  exit 0
fi

# Fall back to Docker-based build for macOS or systems without dpkg-buildpackage
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is required to build Debian packages on this platform." >&2
  echo "" >&2
  echo "Please install Docker:" >&2
  echo "  - macOS: https://docs.docker.com/desktop/install/mac-install/" >&2
  echo "  - Linux: https://docs.docker.com/engine/install/" >&2
  exit 1
fi

# Check if Docker daemon is running
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running." >&2
  echo "" >&2
  echo "Please start Docker Desktop and try again." >&2
  exit 1
fi

echo "Building Debian package in Docker container..."

# Build using Debian container with proper dependencies
docker run --rm \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  debian:bookworm \
  bash -c '
    set -euo pipefail

    # Update package lists
    apt-get update -qq

    # Install build dependencies
    apt-get install -y -qq \
      debhelper \
      wget \
      xz-utils \
      ca-certificates

    # Install Zig 0.15.1
    echo "Installing Zig 0.15.1..."
    wget -q https://ziglang.org/download/0.15.1/zig-linux-x86_64-0.15.1.tar.xz
    tar -xf zig-linux-x86_64-0.15.1.tar.xz -C /usr/local
    ln -sf /usr/local/zig-linux-x86_64-0.15.1/zig /usr/local/bin/zig
    rm zig-linux-x86_64-0.15.1.tar.xz

    # Verify Zig installation
    zig version

    # Build the Debian package
    echo "Building package..."
    dpkg-buildpackage -us -uc '"$@"'

    # Fix permissions (Docker creates files as root)
    chown -R '"$(id -u):$(id -g)"' /workspace
  '

echo ""
echo "✓ Debian package built successfully!"
echo ""
echo "Package files:"
ls -lh "${REPO_ROOT}/../"*.deb 2>/dev/null || echo "  (check parent directory for .deb files)"
