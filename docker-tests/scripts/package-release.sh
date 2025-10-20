#!/bin/bash

# ZigCat Release Packaging Orchestrator
# Creates tarballs (.tar.gz), Debian (.deb), and RPM (.rpm) packages
# with maximum compression and descriptive filenames

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
VERBOSE=false
VERSION=""
COMPRESSION_LEVEL=9
CREATE_DEB=false
CREATE_RPM=false
OUTPUT_DIR=""

# Files to include in tarballs
INCLUDE_FILES=(
    "$PROJECT_ROOT/LICENSE"
    "$PROJECT_ROOT/README.md"
    "$PROJECT_ROOT/RELEASE_NOTES_v0.0.1.md"
)

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

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1" >&2
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

ZigCat Release Packaging Orchestrator
Package build artifacts into tarballs, .deb, and .rpm packages

OPTIONS:
    --version VERSION          Release version (e.g., v0.0.1, auto-detected from build.zig if not specified)
    --compression LEVEL        Gzip compression level 1-9 (default: 9)
    --create-deb               Create Debian (.deb) packages
    --create-rpm               Create RPM (.rpm) packages
    --output-dir DIR           Output directory (default: artifacts/releases/{version})
    --verbose                  Enable verbose logging
    -h, --help                 Show this help message

EXAMPLES:
    # Create tarballs only with max compression
    $0 --version v0.0.1 --compression 9

    # Create tarballs and packages
    $0 --version v0.0.1 --create-deb --create-rpm

    # Specify custom output directory
    $0 --version v0.0.1 --output-dir /tmp/releases

OUTPUTS:
    {output-dir}/
    ├── tarballs/
    │   ├── zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz
    │   ├── zigcat-v0.0.1-linux-arm64-glibc-openssl-dynamic.tar.gz
    │   ├── zigcat-v0.0.1-linux-x64-musl-static.tar.gz
    │   ├── zigcat-v0.0.1-alpine-x64-musl-wolfssl-static.tar.gz
    │   └── zigcat-v0.0.1-freebsd-x64.tar.gz
    ├── deb/ (if --create-deb)
    │   ├── zigcat_0.0.1-1_amd64.deb
    │   └── zigcat-static_0.0.1-1_amd64.deb
    └── rpm/ (if --create-rpm)
        ├── zigcat-0.0.1-1.x86_64.rpm
        └── zigcat-static-0.0.1-1.x86_64.rpm

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
            --compression)
                COMPRESSION_LEVEL="$2"
                shift 2
                ;;
            --create-deb)
                CREATE_DEB=true
                shift
                ;;
            --create-rpm)
                CREATE_RPM=true
                shift
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

    # Auto-detect version if not specified
    if [[ -z "$VERSION" ]]; then
        log_info "Auto-detecting version from build.zig..."

        # Extract version from build.zig
        local detected_version
        detected_version=$(grep -E 'options\.addOption.*"version"' "$PROJECT_ROOT/build.zig" | sed -E 's/.*"version",[[:space:]]*"([^"]+)".*/\1/')

        if [[ -z "$detected_version" ]]; then
            log_error "Could not auto-detect version from build.zig"
            log_error "Please specify version with --version flag"
            usage
            exit 1
        fi

        VERSION="$detected_version"
        log_success "Detected version: $VERSION"
    fi

    # Ensure version starts with 'v'
    if [[ "$VERSION" != v* ]]; then
        VERSION="v$VERSION"
    fi

    # Set default output dir if not specified
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$ARTIFACTS_DIR/releases/$VERSION"
    fi

    # Validate compression level
    if [[ ! "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]]; then
        log_error "Compression level must be 1-9"
        exit 1
    fi
}

# Validate environment
validate_environment() {
    log_step "Validating environment..."

    # Check if artifacts exist
    if [[ ! -d "$ARTIFACTS_DIR" ]]; then
        log_error "Artifacts directory not found: $ARTIFACTS_DIR"
        log_error "Run build-release-v2.sh first"
        return 1
    fi

    # Check for at least one build artifact
    local artifact_count
    artifact_count=$(find "$ARTIFACTS_DIR" -maxdepth 2 -name "zigcat" -type f 2>/dev/null | wc -l)

    if [[ $artifact_count -eq 0 ]]; then
        log_error "No build artifacts found in $ARTIFACTS_DIR"
        log_error "Run build-release-v2.sh first"
        return 1
    fi

    # Create output directories
    mkdir -p "$OUTPUT_DIR/tarballs"

    if [[ "$CREATE_DEB" == "true" ]]; then
        mkdir -p "$OUTPUT_DIR/deb"
    fi

    if [[ "$CREATE_RPM" == "true" ]]; then
        mkdir -p "$OUTPUT_DIR/rpm"
    fi

    log_success "Environment validation completed"
    return 0
}

# Get descriptive artifact name
get_artifact_name() {
    local platform="$1"
    local arch="$2"
    local suffix="$3"

    # Normalize arch names
    case "$arch" in
        amd64) arch="x64" ;;
        arm64) arch="arm64" ;;
        386|x86) arch="x86" ;;
        arm/v7|armv7|arm) arch="arm" ;;
    esac

    # Construct filename: zigcat-{version}-{platform}-{arch}-{suffix}
    echo "zigcat-${VERSION}-${platform}-${arch}-${suffix}"
}

# Create tarball for a single artifact
create_tarball() {
    local artifact_dir="$1"
    local platform arch suffix

    # Check if build metadata exists (from build-release.sh)
    if [[ -f "$artifact_dir/.build-meta" ]]; then
        # Normalize metadata for shell sourcing (handle legacy unquoted values)
        local meta_normalized
        meta_normalized=$(mktemp)
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == BUILD_OPTIONS=* ]] && [[ "$line" != BUILD_OPTIONS=\"*\" ]]; then
                local value="${line#BUILD_OPTIONS=}"
                printf 'BUILD_OPTIONS="%s"\n' "$value" >> "$meta_normalized"
            else
                printf '%s\n' "$line" >> "$meta_normalized"
            fi
        done < "$artifact_dir/.build-meta"

        # shellcheck disable=SC1090
        source "$meta_normalized"
        rm -f "$meta_normalized"
        log_debug "  Loaded metadata from .build-meta: platform=$PLATFORM arch=$ARCH suffix=$SUFFIX"

        platform="$PLATFORM"
        arch="$ARCH"
        suffix="$SUFFIX"
    else
        # Fallback: Extract from directory name (old behavior)
        log_debug "  No .build-meta found, using directory name heuristics"

        local dir_name
        dir_name=$(basename "$artifact_dir")

        # Expected format: {platform}-{arch}
        platform=$(echo "$dir_name" | cut -d'-' -f1)
        arch=$(echo "$dir_name" | cut -d'-' -f2)

        # Determine suffix based on directory structure
        local suffix="unknown"

        # Map directory names to suffixes
        case "$dir_name" in
            *alpine*wolfssl*) suffix="musl-wolfssl-static" ;;
            *alpine*) suffix="musl-wolfssl-static" ;;
            *musl*) suffix="musl-static" ;;
            *glibc*) suffix="glibc-openssl-dynamic" ;;
            *freebsd*) suffix="freebsd" ;;
            linux-*)
                # Check if binary is static
                if file "$artifact_dir/zigcat" | grep -q "statically linked"; then
                    suffix="musl-static"
                else
                    suffix="glibc-openssl-dynamic"
                fi
                ;;
            *)
                log_warn "Could not determine suffix for $dir_name, using platform name"
                suffix="$platform"
                ;;
        esac
    fi

    local artifact_name
    artifact_name=$(get_artifact_name "$platform" "$arch" "$suffix")

    log_info "Creating tarball: $artifact_name"

    # Check if binary exists
    if [[ ! -f "$artifact_dir/zigcat" ]]; then
        log_warn "Binary not found in $artifact_dir, skipping"
        return 1
    fi

    # Create temporary directory for packaging
    local temp_dir
    temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/$artifact_name"
    mkdir -p "$package_dir"

    # Copy binary
    cp "$artifact_dir/zigcat" "$package_dir/"
    log_debug "  Copied binary"

    # Copy include files
    for file in "${INCLUDE_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$package_dir/"
            log_debug "  Copied: $(basename "$file")"
        else
            log_warn "  Include file not found: $file"
        fi
    done

    # Create tarball with maximum compression
    local tarball_name="${artifact_name}.tar.gz"
    local tarball_path="$OUTPUT_DIR/tarballs/$tarball_name"

    # Check if tarball already exists
    if [[ -f "$tarball_path" ]]; then
        local existing_size
        existing_size=$(du -h "$tarball_path" | cut -f1)
        log_warn "  Tarball already exists: $tarball_name ($existing_size)"
        log_info "  Skipping (use --force to overwrite, or delete manually)"

        # Cleanup temp directory
        rm -rf "$temp_dir"
        echo "$tarball_path"
        return 0
    fi

    log_debug "  Creating tarball with compression level $COMPRESSION_LEVEL..."

    cd "$temp_dir"
    if command -v pigz &> /dev/null; then
        # Use pigz for parallel gzip if available
        tar -cf - "$artifact_name" | pigz "-$COMPRESSION_LEVEL" > "$tarball_path"
    else
        # Fallback to standard gzip
        GZIP="-$COMPRESSION_LEVEL" tar -czf "$tarball_path" "$artifact_name"
    fi
    cd - > /dev/null

    # Cleanup temp directory
    rm -rf "$temp_dir"

    # Get tarball size
    local size
    size=$(du -h "$tarball_path" | cut -f1)

    log_success "  Created: $tarball_name ($size)"
    echo "$tarball_path"
    return 0
}

# Create all tarballs
create_all_tarballs() {
    log_step "Creating tarballs with compression level $COMPRESSION_LEVEL..."

    local total_created=0
    local total_failed=0

    # Find all artifact directories
    for artifact_dir in "$ARTIFACTS_DIR"/*; do
        if [[ ! -d "$artifact_dir" ]]; then
            continue
        fi

        # Skip special directories
        if [[ "$artifact_dir" == *"/releases" ]] || [[ "$artifact_dir" == *"/logs" ]]; then
            continue
        fi

        if create_tarball "$artifact_dir"; then
            ((total_created++))
        else
            ((total_failed++))
        fi
    done

    log_info "Tarballs created: $total_created, failed: $total_failed"

    if [[ $total_created -eq 0 ]]; then
        log_error "No tarballs were created"
        return 1
    fi

    return 0
}

# Create Debian packages
create_debian_packages() {
    if [[ "$CREATE_DEB" != "true" ]]; then
        return 0
    fi

    log_step "Creating Debian packages..."

    # Check if dpkg-deb is available
    if ! command -v dpkg-deb &> /dev/null; then
        log_warn "dpkg-deb not found, skipping Debian package creation"
        return 0
    fi

    # This is a placeholder - actual implementation would involve
    # calling build-deb-packages.sh script
    log_info "Calling build-deb-packages.sh..."

    if [[ -f "$SCRIPT_DIR/build-deb-packages.sh" ]]; then
        "$SCRIPT_DIR/build-deb-packages.sh" \
            --version "$VERSION" \
            --artifacts-dir "$ARTIFACTS_DIR" \
            --output-dir "$OUTPUT_DIR/deb" \
            $([ "$VERBOSE" == "true" ] && echo "--verbose")
    else
        log_warn "build-deb-packages.sh not found, skipping"
    fi

    return 0
}

# Create RPM packages
create_rpm_packages() {
    if [[ "$CREATE_RPM" != "true" ]]; then
        return 0
    fi

    log_step "Creating RPM packages..."

    # Check if rpmbuild is available
    if ! command -v rpmbuild &> /dev/null; then
        log_warn "rpmbuild not found, skipping RPM package creation"
        return 0
    fi

    # This is a placeholder - actual implementation would involve
    # calling build-rpm-packages.sh script
    log_info "Calling build-rpm-packages.sh..."

    if [[ -f "$SCRIPT_DIR/build-rpm-packages.sh" ]]; then
        "$SCRIPT_DIR/build-rpm-packages.sh" \
            --version "$VERSION" \
            --artifacts-dir "$ARTIFACTS_DIR" \
            --output-dir "$OUTPUT_DIR/rpm" \
            $([ "$VERBOSE" == "true" ] && echo "--verbose")
    else
        log_warn "build-rpm-packages.sh not found, skipping"
    fi

    return 0
}

# Print summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Packaging Summary - $VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Output Directory: $OUTPUT_DIR"
    echo ""

    # List tarballs
    if compgen -G "$OUTPUT_DIR/tarballs/*.tar.gz" > /dev/null; then
        echo "  📦 Tarballs (gzip -$COMPRESSION_LEVEL):"
        for tarball in "$OUTPUT_DIR/tarballs"/*.tar.gz; do
            local filename
            filename=$(basename "$tarball")
            local size
            size=$(du -h "$tarball" | cut -f1 | awk '{printf "%8s", $1}')
            echo "     $size  $filename"
        done
        echo ""
    fi

    # List .deb packages
    if [[ "$CREATE_DEB" == "true" ]] && compgen -G "$OUTPUT_DIR/deb/*.deb" > /dev/null; then
        echo "  📦 Debian Packages:"
        for deb in "$OUTPUT_DIR/deb"/*.deb; do
            local filename
            filename=$(basename "$deb")
            local size
            size=$(du -h "$deb" | cut -f1 | awk '{printf "%8s", $1}')
            echo "     $size  $filename"
        done
        echo ""
    fi

    # List .rpm packages
    if [[ "$CREATE_RPM" == "true" ]] && compgen -G "$OUTPUT_DIR/rpm/*.rpm" > /dev/null; then
        echo "  📦 RPM Packages:"
        for rpm in "$OUTPUT_DIR/rpm"/*.rpm; do
            local filename
            filename=$(basename "$rpm")
            local size
            size=$(du -h "$rpm" | cut -f1 | awk '{printf "%8s", $1}')
            echo "     $size  $filename"
        done
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Main function
main() {
    local start_time
    start_time=$(date +%s)

    # Parse arguments
    parse_args "$@"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Release Packaging Orchestrator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Version: $VERSION"
    log_info "Compression: gzip -$COMPRESSION_LEVEL"
    log_info "Create .deb: $CREATE_DEB"
    log_info "Create .rpm: $CREATE_RPM"
    echo ""

    # Validate environment
    validate_environment || exit 1

    # Create tarballs
    if ! create_all_tarballs; then
        log_error "Tarball creation failed"
        exit 1
    fi

    # Create packages
    create_debian_packages
    create_rpm_packages

    # Print summary
    print_summary

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Packaging completed in ${duration}s"
    echo ""

    exit 0
}

# Run main
main "$@"
