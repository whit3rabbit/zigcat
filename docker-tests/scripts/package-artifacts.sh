#!/bin/bash

# ZigCat Release Artifact Packager
# Creates properly named release tarballs from build artifacts

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
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
OUTPUT_DIR=""

# Files to include in release packages
INCLUDE_FILES=(
    "$PROJECT_ROOT/LICENSE"
    "$PROJECT_ROOT/README.md"
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

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Package ZigCat build artifacts into release tarballs

OPTIONS:
    --version VERSION              Release version (e.g., v0.1.0)
    --artifacts-dir DIR            Build artifacts directory
                                   (default: docker-tests/artifacts)
    --output-dir DIR               Output directory for release tarballs
                                   (default: docker-tests/artifacts/releases/{version})
    --verbose                      Enable verbose logging
    -h, --help                     Show this help message

EXAMPLES:
    $0 --version v0.1.0
    $0 --version v0.1.0 --output-dir /path/to/releases

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
        usage
        exit 1
    fi

    # Set default output dir if not specified
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$ARTIFACTS_DIR/releases/$VERSION"
    fi
}

# Validate environment
validate_environment() {
    log_info "Validating environment..."

    # Check if artifacts directory exists
    if [[ ! -d "$ARTIFACTS_DIR" ]]; then
        log_error "Artifacts directory not found: $ARTIFACTS_DIR"
        return 1
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    log_success "Environment validation completed"
    return 0
}

# Determine artifact naming based on platform and build options
get_artifact_name() {
    local platform="$1"
    local arch="$2"
    local suffix=""

    # Map Docker arch to common names
    case "$arch" in
        amd64|x86_64)
            arch="x64"
            ;;
        arm64|aarch64)
            arch="arm64"
            ;;
        386|x86)
            arch="x86"
            ;;
        arm|armv7)
            arch="arm"
            ;;
    esac

    # Platform-specific suffixes (from config)
    # These should match the artifact_suffix from release config YAMLs
    case "$platform" in
        linux-glibc*)
            suffix="glibc-openssl"
            platform="linux"
            ;;
        linux-musl-static*)
            suffix="musl-static"
            platform="linux"
            ;;
        alpine-wolfssl*)
            suffix="musl-wolfssl-static"
            platform="alpine"
            ;;
        freebsd*)
            suffix="freebsd"
            platform="freebsd"
            ;;
        macos*)
            suffix="macos-openssl"
            platform="macos"
            ;;
    esac

    # Construct final name: zigcat-{version}-{platform}-{arch}-{suffix}
    if [[ -n "$suffix" ]]; then
        echo "zigcat-${VERSION}-${platform}-${arch}-${suffix}"
    else
        echo "zigcat-${VERSION}-${platform}-${arch}"
    fi
}

# Package a single artifact
package_artifact() {
    local build_dir="$1"
    local build_id
    build_id=$(basename "$build_dir")

    log_info "Packaging artifact: $build_id"

    # Extract platform and arch from build_id
    local platform arch
    platform=$(echo "$build_id" | cut -d'-' -f1)
    arch=$(echo "$build_id" | cut -d'-' -f2)

    # Find binary in build directory
    local binary_path=""
    if [[ -f "$build_dir/zigcat" ]]; then
        binary_path="$build_dir/zigcat"
    elif [[ -f "$build_dir/zigcat-wolfssl" ]]; then
        binary_path="$build_dir/zigcat-wolfssl"
    elif [[ -f "$build_dir/zigcat.exe" ]]; then
        binary_path="$build_dir/zigcat.exe"
    else
        log_warn "No binary found in $build_dir, skipping"
        return 1
    fi

    # Get proper artifact name
    local artifact_name
    artifact_name=$(get_artifact_name "$platform" "$arch")

    # Create temporary directory for packaging
    local temp_dir
    temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/$artifact_name"
    mkdir -p "$package_dir"

    # Copy binary
    local binary_name
    binary_name=$(basename "$binary_path")
    cp "$binary_path" "$package_dir/"
    log_debug "  Copied binary: $binary_name"

    # Copy include files (LICENSE, README, etc.)
    for file in "${INCLUDE_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$package_dir/"
            log_debug "  Copied: $(basename "$file")"
        else
            log_warn "  Include file not found: $file"
        fi
    done

    # Create tarball
    local tarball_name="${artifact_name}.tar.gz"
    local tarball_path="$OUTPUT_DIR/$tarball_name"

    cd "$temp_dir"
    tar -czf "$tarball_path" "$artifact_name"
    cd - > /dev/null

    # Get tarball size
    local size
    size=$(du -h "$tarball_path" | cut -f1)

    # Cleanup temp directory
    rm -rf "$temp_dir"

    log_success "  Created: $tarball_name ($size)"
    return 0
}

# Package all artifacts
package_all_artifacts() {
    log_info "Packaging all build artifacts..."

    local total_packaged=0
    local total_failed=0

    # Find all build artifact directories
    for build_dir in "$ARTIFACTS_DIR"/*; do
        if [[ ! -d "$build_dir" ]]; then
            continue
        fi

        # Skip releases directory itself
        if [[ "$build_dir" == *"/releases" ]]; then
            continue
        fi

        if package_artifact "$build_dir"; then
            ((total_packaged++))
        else
            ((total_failed++))
        fi
    done

    log_info "Packaging complete: $total_packaged packaged, $total_failed failed/skipped"

    if [[ $total_packaged -eq 0 ]]; then
        log_error "No artifacts were packaged"
        return 1
    fi

    return 0
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    log_info "ZigCat Release Artifact Packager"
    log_info "Version: $VERSION"
    log_info "Output: $OUTPUT_DIR"

    # Validate environment
    validate_environment || exit 1

    # Package all artifacts
    if package_all_artifacts; then
        log_success "All artifacts packaged successfully!"
        exit 0
    else
        log_error "Packaging failed"
        exit 1
    fi
}

# Run main
main "$@"
