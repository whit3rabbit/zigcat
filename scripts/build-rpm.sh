#!/usr/bin/env bash
# Build the zigcat RPM package
# Supports both native RHEL/Fedora builds and Docker-based builds (other platforms)
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# Extract version from build.zig
VERSION="$(sed -n 's/^\s*options.addOption(\[\]const u8, \"version\", \"\([0-9.]*\)\");/\1/p' build.zig)"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: Unable to determine version from build.zig" >&2
  exit 1
fi

# Detect if we're on RHEL/Fedora with native tools
if command -v rpmbuild >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
  echo "Building RPM package natively on Fedora/RHEL..."
  echo "Version: ${VERSION}"

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

  # Native RPM build
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${WORKDIR}"' EXIT

  TARBALL="zigcat-${VERSION}.tar.gz"

  # Create source tarball
  mkdir -p "${WORKDIR}/SOURCES"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git archive --format=tar.gz --output="${WORKDIR}/SOURCES/${TARBALL}" --prefix="zigcat-${VERSION}/" HEAD
  else
    tar -czf "${WORKDIR}/SOURCES/${TARBALL}" \
      --exclude='./rpm-dist' \
      --exclude='./debian-dist' \
      --exclude='./zig-cache' \
      --exclude='./zig-out' \
      --exclude='./zigcat-*.tar.gz' \
      --exclude='./*.rpm' \
      --transform "s,^,zigcat-${VERSION}/," .
  fi

  mkdir -p "${WORKDIR}/SPECS"
  cp packaging/rpm/zigcat.spec "${WORKDIR}/SPECS/"

  # Build the RPM
  rpmbuild --define "_topdir ${WORKDIR}" -ba "${WORKDIR}/SPECS/zigcat.spec"

  # Collect artifacts
  mkdir -p rpm-dist
  shopt -s nullglob
  for dir in "${WORKDIR}"/RPMS/*; do
    for file in "${dir}"/*.rpm; do
      cp "${file}" rpm-dist/
    done
  done

  for file in "${WORKDIR}"/SRPMS/*.src.rpm; do
    cp "${file}" rpm-dist/
  done

  if [[ ! -d rpm-dist || -z "$(ls -A rpm-dist 2>/dev/null)" ]]; then
    echo "ERROR: No RPM artifacts produced" >&2
    exit 1
  fi

  echo ""
  echo "✓ RPM package built successfully!"
  echo ""
  echo "RPM packages written to rpm-dist/"
  ls -lh rpm-dist/
  exit 0
fi

# Fall back to Docker-based build for non-RHEL/Fedora systems
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is required to build RPM packages on this platform." >&2
  echo "" >&2
  echo "Please install Docker:" >&2
  echo "  - macOS: https://docs.docker.com/desktop/install/mac-install/" >&2
  echo "  - Linux: https://docs.docker.com/engine/install/" >&2
  echo "" >&2
  echo "Alternatively, on Fedora/RHEL, install:" >&2
  echo "  sudo dnf install rpm-build rpmdevtools" >&2
  exit 1
fi

# Check if Docker daemon is running
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running." >&2
  echo "" >&2
  echo "Please start Docker and try again." >&2
  exit 1
fi

echo "Building RPM package in Docker container..."

echo "Version: ${VERSION}"

# Build using Fedora container with proper dependencies
docker run --rm \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  fedora:latest \
  bash -c '
    set -euo pipefail

    # Install build dependencies
    dnf install -y -q \
      rpm-build \
      rpmdevtools \
      wget \
      xz \
      tar \
      gzip \
      git

    # Install Zig 0.15.1
    echo "Installing Zig 0.15.1..."
    wget -q https://ziglang.org/download/0.15.1/zig-linux-x86_64-0.15.1.tar.xz
    tar -xf zig-linux-x86_64-0.15.1.tar.xz -C /usr/local
    ln -sf /usr/local/zig-linux-x86_64-0.15.1/zig /usr/local/bin/zig
    rm zig-linux-x86_64-0.15.1.tar.xz

    # Verify Zig installation
    zig version

    # Create RPM build environment
    WORKDIR="$(mktemp -d)"
    trap "rm -rf ${WORKDIR}" EXIT

    TARBALL="zigcat-'"${VERSION}"'.tar.gz"

    # Create source tarball
    mkdir -p "${WORKDIR}/SOURCES"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git archive --format=tar.gz --output="${WORKDIR}/SOURCES/${TARBALL}" --prefix="zigcat-'"${VERSION}"'/" HEAD
    else
      tar -czf "${WORKDIR}/SOURCES/${TARBALL}" \
        --exclude="./rpm-dist" \
        --exclude="./debian-dist" \
        --exclude="./zig-cache" \
        --exclude="./zig-out" \
        --exclude="./zigcat-*.tar.gz" \
        --exclude="./*.rpm" \
        --transform "s,^,zigcat-'"${VERSION}"'/," .
    fi

    mkdir -p "${WORKDIR}/SPECS"
    cp packaging/rpm/zigcat.spec "${WORKDIR}/SPECS/"

    # Build the RPM
    echo "Building RPM package..."
    rpmbuild --define "_topdir ${WORKDIR}" -ba "${WORKDIR}/SPECS/zigcat.spec"

    # Collect artifacts
    mkdir -p rpm-dist
    shopt -s nullglob
    for dir in "${WORKDIR}"/RPMS/*; do
      for file in "${dir}"/*.rpm; do
        cp "${file}" rpm-dist/
      done
    done

    for file in "${WORKDIR}"/SRPMS/*.src.rpm; do
      cp "${file}" rpm-dist/
    done

    # Fix permissions
    chown -R '"$(id -u):$(id -g)"' /workspace/rpm-dist
  '

if [[ ! -d rpm-dist || -z "$(ls -A rpm-dist 2>/dev/null)" ]]; then
  echo "ERROR: No RPM artifacts produced" >&2
  exit 1
fi

echo ""
echo "✓ RPM package built successfully!"
echo ""
echo "RPM packages written to rpm-dist/"
ls -lh rpm-dist/
