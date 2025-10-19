#!/bin/bash

# ZigCat RPM Package Builder
# Creates .rpm packages for all Linux artifact variants

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
VERBOSE=false
VERSION=""
ARTIFACTS_DIR=""
OUTPUT_DIR=""

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Create RPM (.rpm) packages from ZigCat build artifacts

OPTIONS:
    --version VERSION          Release version (e.g., v0.0.1 or 0.0.1) [REQUIRED]
    --artifacts-dir DIR        Build artifacts directory [REQUIRED]
    --output-dir DIR           Output directory for .rpm files [REQUIRED]
    --verbose                  Enable verbose logging
    -h, --help                 Show this help message

EXAMPLES:
    $0 --version v0.0.1 \\
       --artifacts-dir docker-tests/artifacts \\
       --output-dir docker-tests/artifacts/releases/v0.0.1/rpm

OUTPUTS:
    - zigcat-0.0.1-1.x86_64.rpm          # Default OpenSSL variant
    - zigcat-static-0.0.1-1.x86_64.rpm   # Static variant (no TLS)
    - zigcat-wolfssl-0.0.1-1.x86_64.rpm  # wolfSSL variant (GPLv2)

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --artifacts-dir)
                ARTIFACTS_DIR="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$VERSION" ]]; then
        log_error "Version is required (--version)"
        exit 1
    fi

    if [[ -z "$ARTIFACTS_DIR" ]]; then
        log_error "Artifacts directory is required (--artifacts-dir)"
        exit 1
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        log_error "Output directory is required (--output-dir)"
        exit 1
    fi

    # Strip 'v' prefix from version for package naming
    VERSION="${VERSION#v}"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
}

# Build a single .rpm package
build_rpm_package() {
    local binary_path="$1"
    local package_name="$2"
    local arch="$3"
    local description="$4"
    local license="$5"

    log_info "Building package: ${package_name}-${VERSION}-1.${arch}.rpm"

    # Create temporary RPM build directories
    local temp_dir
    temp_dir=$(mktemp -d)
    local rpmbuild_dir="$temp_dir/rpmbuild"

    mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Create spec file
    local spec_file="$rpmbuild_dir/SPECS/${package_name}.spec"

    # Determine requirements based on package variant
    local requires=""
    case "$package_name" in
        zigcat-static|zigcat-wolfssl)
            # Static binaries have no runtime dependencies
            requires=""
            ;;
        *)
            # Default OpenSSL variant (dynamic)
            requires="Requires: openssl-libs >= 3.0.0"
            ;;
    esac

    cat > "$spec_file" <<EOF
Name:           $package_name
Version:        $VERSION
Release:        1%{?dist}
Summary:        $description
License:        $license
URL:            https://github.com/whit3rabbit/zigcat
BuildArch:      $arch
$requires

%description
Zigcat provides TCP and UDP client/server helpers, TLS support, proxy
awareness, and timeout-aware I/O in a compact standalone binary. It aims
to be a drop-in replacement for traditional netcat utilities while adding
cross-platform features and stricter error handling.

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 $binary_path %{buildroot}%{_bindir}/zigcat

%files
%{_bindir}/zigcat

%changelog
* $(date +'%a %b %d %Y') Whit3Rabbit <whiterabbit@protonmail.com> - ${VERSION}-1
- Release ${VERSION}
EOF

    # Build the RPM
    local rpm_file="${package_name}-${VERSION}-1.${arch}.rpm"

    if rpmbuild --define "_topdir $rpmbuild_dir" -bb "$spec_file" > /dev/null 2>&1; then
        # Find the built RPM and copy it
        local built_rpm
        built_rpm=$(find "$rpmbuild_dir/RPMS" -name "*.rpm" -type f)

        if [[ -n "$built_rpm" ]]; then
            cp "$built_rpm" "$OUTPUT_DIR/$rpm_file"
            local size
            size=$(du -h "$OUTPUT_DIR/$rpm_file" | cut -f1)
            log_success "  Created: $rpm_file ($size)"
            rm -rf "$temp_dir"
            return 0
        else
            log_error "  Built RPM not found"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log_error "  Failed to create $rpm_file"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Build all .rpm packages
build_all_packages() {
    log_info "Building RPM packages for version $VERSION..."

    local total_created=0
    local total_failed=0

    # Look for Linux x64 glibc (OpenSSL) binary
    if [[ -f "$ARTIFACTS_DIR/linux-amd64/zigcat" ]]; then
        if ! file "$ARTIFACTS_DIR/linux-amd64/zigcat" | grep -q "statically linked"; then
            if build_rpm_package \
                "$ARTIFACTS_DIR/linux-amd64/zigcat" \
                "zigcat" \
                "x86_64" \
                "Modern netcat clone with TLS support (OpenSSL)" \
                "MIT"; then
                ((total_created++))
            else
                ((total_failed++))
            fi
        fi
    else
        log_warn "Linux x64 OpenSSL binary not found, skipping zigcat package"
    fi

    # Look for Linux x64 musl static binary
    if [[ -f "$ARTIFACTS_DIR/linux-amd64/zigcat" ]]; then
        # Check if it's static
        if file "$ARTIFACTS_DIR/linux-amd64/zigcat" | grep -q "statically linked"; then
            if build_rpm_package \
                "$ARTIFACTS_DIR/linux-amd64/zigcat" \
                "zigcat-static" \
                "x86_64" \
                "Modern netcat clone (static build, no TLS)" \
                "MIT"; then
                ((total_created++))
            else
                ((total_failed++))
            fi
        fi
    else
        log_warn "Linux x64 static binary not found, skipping zigcat-static package"
    fi

    # Look for Alpine x64 wolfSSL binary
    if [[ -f "$ARTIFACTS_DIR/alpine-amd64/zigcat" ]]; then
        if build_rpm_package \
            "$ARTIFACTS_DIR/alpine-amd64/zigcat" \
            "zigcat-wolfssl" \
            "x86_64" \
            "Modern netcat clone with TLS support (wolfSSL)" \
            "GPLv2"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    else
        log_warn "Alpine x64 wolfSSL binary not found, skipping zigcat-wolfssl package"
    fi

    # Look for ARM64 binaries (if available)
    if [[ -f "$ARTIFACTS_DIR/linux-arm64/zigcat" ]]; then
        if build_rpm_package \
            "$ARTIFACTS_DIR/linux-arm64/zigcat" \
            "zigcat" \
            "aarch64" \
            "Modern netcat clone with TLS support (OpenSSL)" \
            "MIT"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    fi

    log_info "RPM packages created: $total_created, failed: $total_failed"

    if [[ $total_created -eq 0 ]]; then
        log_error "No RPM packages were created"
        return 1
    fi

    return 0
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    log_info "ZigCat RPM Package Builder"
    log_info "Version: $VERSION"
    log_info "Artifacts: $ARTIFACTS_DIR"
    log_info "Output: $OUTPUT_DIR"
    echo ""

    # Build packages
    if build_all_packages; then
        log_success "RPM package build completed!"
        exit 0
    else
        log_error "RPM package build failed"
        exit 1
    fi
}

# Run main
main "$@"
