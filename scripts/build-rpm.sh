#!/usr/bin/env bash
# Build the zigcat RPM package using rpmbuild.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild is required to build the RPM package." >&2
  exit 1
fi

VERSION="$(sed -n 's/^\s*options.addOption(\[\]const u8, \"version\", \"\([0-9.]*\)\");/\1/p' build.zig)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to determine version from build.zig" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

TARBALL="zigcat-${VERSION}.tar.gz"

# Create source tarball
mkdir -p "${WORKDIR}/SOURCES"
# Using git archive if available, otherwise fallback to tar from current directory
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
  echo "No RPM artifacts produced" >&2
  exit 1
fi

echo "RPM packages written to rpm-dist/"
