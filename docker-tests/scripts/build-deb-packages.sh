#!/bin/bash

# ZigCat Debian Package Builder
# Creates .deb packages for all Linux artifact variants

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

Create Debian (.deb) packages from ZigCat build artifacts

OPTIONS:
    --version VERSION          Release version (e.g., v0.0.1 or 0.0.1) [REQUIRED]
    --artifacts-dir DIR        Build artifacts directory [REQUIRED]
    --output-dir DIR           Output directory for .deb files [REQUIRED]
    --verbose                  Enable verbose logging
    -h, --help                 Show this help message

EXAMPLES:
    $0 --version v0.0.1 \\
       --artifacts-dir docker-tests/artifacts \\
       --output-dir docker-tests/artifacts/releases/v0.0.1/deb

OUTPUTS:
    - zigcat_0.0.1-1_amd64.deb          # Default OpenSSL variant
    - zigcat-static_0.0.1-1_amd64.deb   # Static variant (no TLS)
    - zigcat-wolfssl_0.0.1-1_amd64.deb  # wolfSSL variant (GPLv2)

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

# Build a single .deb package
build_deb_package() {
    local binary_path="$1"
    local package_name="$2"
    local arch="$3"
    local description="$4"

    log_info "Building package: ${package_name}_${VERSION}-1_${arch}.deb"

    # Create temporary directory structure
    local temp_dir
    temp_dir=$(mktemp -d)
    local pkg_dir="$temp_dir/${package_name}_${VERSION}-1_${arch}"

    # Create Debian package structure
    mkdir -p "$pkg_dir/DEBIAN"
    mkdir -p "$pkg_dir/usr/bin"
    mkdir -p "$pkg_dir/usr/share/doc/$package_name"

    # Copy binary
    cp "$binary_path" "$pkg_dir/usr/bin/zigcat"
    chmod 755 "$pkg_dir/usr/bin/zigcat"

    # Copy documentation
    if [[ -f "$PROJECT_ROOT/README.md" ]]; then
        cp "$PROJECT_ROOT/README.md" "$pkg_dir/usr/share/doc/$package_name/"
    fi

    if [[ -f "$PROJECT_ROOT/LICENSE" ]]; then
        cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/usr/share/doc/$package_name/copyright"
    fi

    # Create control file
    cat > "$pkg_dir/DEBIAN/control" <<EOF
Package: $package_name
Version: ${VERSION}-1
Section: net
Priority: optional
Architecture: $arch
Maintainer: Whit3Rabbit <whiterabbit@protonmail.com>
Homepage: https://github.com/whit3rabbit/zigcat
Description: $description
 Zigcat provides TCP and UDP client/server helpers, TLS support, proxy
 awareness, and timeout-aware I/O in a compact standalone binary. It aims
 to be a drop-in replacement for traditional netcat utilities while adding
 cross-platform features and stricter error handling.
EOF

    # Determine dependencies based on package variant
    case "$package_name" in
        zigcat-static)
            # Static binary has no runtime dependencies
            echo "Depends: " >> "$pkg_dir/DEBIAN/control"
            ;;
        zigcat-wolfssl)
            # wolfSSL variant (statically linked)
            echo "Depends: " >> "$pkg_dir/DEBIAN/control"
            ;;
        *)
            # Default OpenSSL variant (dynamic)
            echo "Depends: libc6 (>= 2.34), libssl3 (>= 3.0.0)" >> "$pkg_dir/DEBIAN/control"
            ;;
    esac

    # Create postinst script (empty for now)
    cat > "$pkg_dir/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
exit 0
EOF
    chmod 755 "$pkg_dir/DEBIAN/postinst"

    # Create postrm script (empty for now)
    cat > "$pkg_dir/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
exit 0
EOF
    chmod 755 "$pkg_dir/DEBIAN/postrm"

    # Build the package
    local deb_file="${package_name}_${VERSION}-1_${arch}.deb"

    if dpkg-deb --build "$pkg_dir" "$OUTPUT_DIR/$deb_file" > /dev/null 2>&1; then
        local size
        size=$(du -h "$OUTPUT_DIR/$deb_file" | cut -f1)
        log_success "  Created: $deb_file ($size)"
        rm -rf "$temp_dir"
        return 0
    else
        log_error "  Failed to create $deb_file"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Build all .deb packages
build_all_packages() {
    log_info "Building Debian packages for version $VERSION..."

    local total_created=0
    local total_failed=0

    # Look for Linux x64 glibc (OpenSSL) binary
    if [[ -f "$ARTIFACTS_DIR/linux-amd64/zigcat" ]]; then
        if build_deb_package \
            "$ARTIFACTS_DIR/linux-amd64/zigcat" \
            "zigcat" \
            "amd64" \
            "Modern netcat clone with TLS support (OpenSSL)"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    else
        log_warn "Linux x64 OpenSSL binary not found, skipping zigcat package"
    fi

    # Look for Linux x64 musl static binary
    if [[ -f "$ARTIFACTS_DIR/linux-amd64/zigcat" ]]; then
        # Check if it's static
        if file "$ARTIFACTS_DIR/linux-amd64/zigcat" | grep -q "statically linked"; then
            if build_deb_package \
                "$ARTIFACTS_DIR/linux-amd64/zigcat" \
                "zigcat-static" \
                "amd64" \
                "Modern netcat clone (static build, no TLS)"; then
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
        if build_deb_package \
            "$ARTIFACTS_DIR/alpine-amd64/zigcat" \
            "zigcat-wolfssl" \
            "amd64" \
            "Modern netcat clone with TLS support (wolfSSL, GPLv2)"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    else
        log_warn "Alpine x64 wolfSSL binary not found, skipping zigcat-wolfssl package"
    fi

    # Look for ARM64 binaries (if available)
    if [[ -f "$ARTIFACTS_DIR/linux-arm64/zigcat" ]]; then
        if build_deb_package \
            "$ARTIFACTS_DIR/linux-arm64/zigcat" \
            "zigcat" \
            "arm64" \
            "Modern netcat clone with TLS support (OpenSSL)"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    fi

    log_info "Debian packages created: $total_created, failed: $total_failed"

    if [[ $total_created -eq 0 ]]; then
        log_error "No Debian packages were created"
        return 1
    fi

    return 0
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    log_info "ZigCat Debian Package Builder"
    log_info "Version: $VERSION"
    log_info "Artifacts: $ARTIFACTS_DIR"
    log_info "Output: $OUTPUT_DIR"
    echo ""

    # Build packages
    if build_all_packages; then
        log_success "Debian package build completed!"
        exit 0
    else
        log_error "Debian package build failed"
        exit 1
    fi
}

# Run main
main "$@"
