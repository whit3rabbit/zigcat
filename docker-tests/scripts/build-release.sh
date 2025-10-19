#!/bin/bash

# ZigCat Release Build Orchestrator
# Builds complete release artifacts for multiple platforms, architectures, and configurations
# Creates properly named tarballs, checksums, and organizes for GitHub releases

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_VALIDATOR="$SCRIPT_DIR/config-validator.sh"
BUILD_SCRIPT="$SCRIPT_DIR/build-binaries.sh"
PACKAGE_SCRIPT="$SCRIPT_DIR/package-artifacts.sh"
CHECKSUM_SCRIPT="$SCRIPT_DIR/generate-checksums.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-releases.sh"

# Default paths
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
RELEASES_DIR="$ARTIFACTS_DIR/releases"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
VERBOSE=false
PARALLEL=false
KEEP_ARTIFACTS=true  # Always keep release artifacts
CONFIG_FILE="$PROJECT_ROOT/docker-tests/configs/releases/release-all.yml"
VERSION=""  # Will be auto-detected from build.zig or specified via --version
NATIVE_BUILD=false  # For macOS builds
CREATE_CHECKSUMS=true
VALIDATE_BINARIES=true
SKIP_BUILD=false
SKIP_PACKAGE=false

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

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

ZigCat Release Build Orchestrator - Build production-ready release artifacts

OPTIONS:
    -c, --config FILE              Release configuration YAML file
                                   (default: configs/releases/release-all.yml)
    -v, --version VERSION          Release version (e.g., v0.1.0)
                                   (default: auto-detect from build.zig)
    --verbose                      Enable verbose logging
    -j, --parallel                 Enable parallel builds
    --native                       Native build mode (required for macOS)
    --skip-build                   Skip build phase (use existing artifacts)
    --skip-package                 Skip packaging phase (build only)
    --no-checksums                 Don't generate checksums
    --no-validation                Skip binary validation
    -h, --help                     Show this help message

EXAMPLES:
    # Build all release artifacts (Linux, Alpine, FreeBSD)
    $0

    # Build specific platform variant
    $0 --config docker-tests/configs/releases/release-linux.yml

    # Build Alpine wolfSSL variant (smallest with TLS)
    $0 --config docker-tests/configs/releases/release-alpine.yml

    # Build with specific version
    $0 --version v0.2.0

    # Build macOS variants (requires native macOS)
    $0 --config docker-tests/configs/releases/release-macos.yml --native

    # Parallel build with verbose output
    $0 --parallel --verbose

    # Build only (skip packaging)
    $0 --skip-package

RELEASE ARTIFACT STRUCTURE:
    docker-tests/artifacts/releases/
    └── v0.1.0/
        ├── zigcat-v0.1.0-linux-x64-glibc-openssl.tar.gz
        ├── zigcat-v0.1.0-linux-x64-musl-static.tar.gz
        ├── zigcat-v0.1.0-alpine-x64-musl-wolfssl-static.tar.gz
        ├── zigcat-v0.1.0-freebsd-x64.tar.gz
        ├── SHA256SUMS
        └── RELEASE_NOTES.md

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -j|--parallel)
                PARALLEL=true
                shift
                ;;
            --native)
                NATIVE_BUILD=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-package)
                SKIP_PACKAGE=true
                shift
                ;;
            --no-checksums)
                CREATE_CHECKSUMS=false
                shift
                ;;
            --no-validation)
                VALIDATE_BINARIES=false
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
}

# Auto-detect version from build.zig
detect_version() {
    if [[ -n "$VERSION" ]]; then
        log_debug "Using specified version: $VERSION"
        return 0
    fi

    log_info "Auto-detecting version from build.zig..."

    # Extract version from build.zig (line with: options.addOption([]const u8, "version", "x.y.z");)
    local detected_version
    detected_version=$(grep -E 'options\.addOption.*"version"' "$PROJECT_ROOT/build.zig" | sed -E 's/.*"version",[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$detected_version" ]]; then
        log_error "Could not auto-detect version from build.zig"
        log_error "Please specify version with --version flag"
        return 1
    fi

    # Ensure version starts with 'v'
    if [[ "$detected_version" != v* ]]; then
        detected_version="v$detected_version"
    fi

    VERSION="$detected_version"
    log_success "Detected version: $VERSION"
    return 0
}

# Validate environment
validate_environment() {
    log_step "Validating environment..."

    # Check required tools
    local missing_tools=()

    if [[ "$NATIVE_BUILD" == "false" ]]; then
        if ! command -v docker &> /dev/null; then
            missing_tools+=("docker")
        fi
    fi

    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi

    if [[ "$NATIVE_BUILD" == "true" ]] && ! command -v zig &> /dev/null; then
        missing_tools+=("zig (required for native builds)")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        return 1
    fi

    # Validate configuration file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    # Check if Docker daemon is running (if not native build)
    if [[ "$NATIVE_BUILD" == "false" ]] && ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Check if Docker is running: systemctl status docker"
        log_error "  2. Check if you're in the docker group: groups | grep docker"
        log_error "  3. If not in docker group, add yourself: sudo usermod -aG docker \$USER"
        log_error "  4. Log out and log back in, or run: newgrp docker"
        log_error "  5. Verify access: docker info"
        return 1
    fi

    log_success "Environment validation completed"
    return 0
}

# Setup release environment
setup_release_env() {
    log_step "Setting up release environment..."

    # Create version-specific release directory
    local version_dir="$RELEASES_DIR/$VERSION"
    mkdir -p "$version_dir"
    mkdir -p "$LOGS_DIR"

    log_info "Release directory: $version_dir"
    log_success "Release environment setup completed"

    # Export for use by other scripts
    export RELEASE_VERSION="$VERSION"
    export RELEASE_DIR="$version_dir"
}

# Build phase - cross-compile binaries
build_phase() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_info "Skipping build phase as requested"
        return 0
    fi

    log_step "Starting release build phase..."

    local build_args=()

    # Build timeout
    build_args+=("-t" "600")

    if [[ "$VERBOSE" == "true" ]]; then
        build_args+=("-v")
    fi

    if [[ "$PARALLEL" == "true" ]]; then
        build_args+=("-j")
    fi

    # Always keep artifacts for releases
    build_args+=("-k")

    # Use Docker unless native build
    if [[ "$NATIVE_BUILD" == "false" ]]; then
        build_args+=("--use-docker")
    fi

    log_debug "Executing: $BUILD_SCRIPT ${build_args[*]}"

    if "$BUILD_SCRIPT" "${build_args[@]}"; then
        log_success "Build phase completed successfully"
        return 0
    else
        log_error "Build phase failed"
        return 1
    fi
}

# Package phase - create release tarballs
package_phase() {
    if [[ "$SKIP_PACKAGE" == "true" ]]; then
        log_info "Skipping packaging phase as requested"
        return 0
    fi

    log_step "Starting packaging phase..."

    # Check if package script exists
    if [[ ! -f "$PACKAGE_SCRIPT" ]]; then
        log_warn "Package script not found: $PACKAGE_SCRIPT"
        log_warn "Skipping packaging phase"
        return 0
    fi

    local package_args=()
    package_args+=("--version" "$VERSION")
    package_args+=("--artifacts-dir" "$ARTIFACTS_DIR")
    package_args+=("--output-dir" "$RELEASE_DIR")

    if [[ "$VERBOSE" == "true" ]]; then
        package_args+=("--verbose")
    fi

    log_debug "Executing: $PACKAGE_SCRIPT ${package_args[*]}"

    if "$PACKAGE_SCRIPT" "${package_args[@]}"; then
        log_success "Packaging phase completed successfully"
        return 0
    else
        log_error "Packaging phase failed"
        return 1
    fi
}

# Validation phase - smoke test binaries
validation_phase() {
    if [[ "$VALIDATE_BINARIES" == "false" ]]; then
        log_info "Skipping validation phase as requested"
        return 0
    fi

    log_step "Starting validation phase..."

    # Check if validate script exists
    if [[ ! -f "$VALIDATE_SCRIPT" ]]; then
        log_warn "Validate script not found: $VALIDATE_SCRIPT"
        log_warn "Skipping validation phase"
        return 0
    fi

    local validate_args=()
    validate_args+=("--artifacts-dir" "$ARTIFACTS_DIR")

    if [[ "$VERBOSE" == "true" ]]; then
        validate_args+=("--verbose")
    fi

    log_debug "Executing: $VALIDATE_SCRIPT ${validate_args[*]}"

    if "$VALIDATE_SCRIPT" "${validate_args[@]}"; then
        log_success "Validation phase completed successfully"
        return 0
    else
        log_warn "Validation phase completed with warnings"
        return 0  # Don't fail on validation warnings
    fi
}

# Checksum phase - generate SHA256SUMS
checksum_phase() {
    if [[ "$CREATE_CHECKSUMS" == "false" ]]; then
        log_info "Skipping checksum generation as requested"
        return 0
    fi

    log_step "Generating checksums..."

    # Check if checksum script exists
    if [[ ! -f "$CHECKSUM_SCRIPT" ]]; then
        log_warn "Checksum script not found: $CHECKSUM_SCRIPT"
        log_warn "Skipping checksum generation"
        return 0
    fi

    local checksum_args=()
    checksum_args+=("--release-dir" "$RELEASE_DIR")

    if [[ "$VERBOSE" == "true" ]]; then
        checksum_args+=("--verbose")
    fi

    log_debug "Executing: $CHECKSUM_SCRIPT ${checksum_args[*]}"

    if "$CHECKSUM_SCRIPT" "${checksum_args[@]}"; then
        log_success "Checksum generation completed successfully"
        return 0
    else
        log_error "Checksum generation failed"
        return 1
    fi
}

# Generate release report
generate_release_report() {
    log_step "Generating release report..."

    local report_file="$RELEASE_DIR/RELEASE_NOTES.md"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    {
        echo "# ZigCat Release $VERSION"
        echo ""
        echo "**Build Date:** $timestamp"
        echo ""
        echo "## Release Artifacts"
        echo ""

        # List all tarballs
        if compgen -G "$RELEASE_DIR/*.tar.gz" > /dev/null; then
            for tarball in "$RELEASE_DIR"/*.tar.gz; do
                local filename
                filename=$(basename "$tarball")
                local size
                size=$(du -h "$tarball" | cut -f1)
                echo "- **$filename** ($size)"
            done
        else
            echo "*(No packaged artifacts found)*"
        fi

        echo ""
        echo "## Checksums"
        echo ""

        if [[ -f "$RELEASE_DIR/SHA256SUMS" ]]; then
            echo "\`\`\`"
            cat "$RELEASE_DIR/SHA256SUMS"
            echo "\`\`\`"
        else
            echo "*(Checksums not generated)*"
        fi

        echo ""
        echo "## Build Configuration"
        echo ""
        echo "- **Config:** $(basename "$CONFIG_FILE")"
        echo "- **Parallel Build:** $PARALLEL"
        echo "- **Native Build:** $NATIVE_BUILD"
        echo ""
        echo "---"
        echo "*Generated by ZigCat Release Build System*"

    } > "$report_file"

    log_success "Release report generated: $report_file"
}

# Print release summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Release Build Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Version:        $VERSION"
    echo "  Configuration:  $(basename "$CONFIG_FILE")"
    echo "  Release Dir:    $RELEASE_DIR"
    echo ""
    echo "  Artifacts:"

    if compgen -G "$RELEASE_DIR/*.tar.gz" > /dev/null; then
        for tarball in "$RELEASE_DIR"/*.tar.gz; do
            local filename
            filename=$(basename "$tarball")
            local size
            size=$(du -h "$tarball" | cut -f1 | awk '{printf "%8s", $1}')
            echo "    $size  $filename"
        done
    else
        echo "    (No packaged artifacts)"
    fi

    echo ""

    if [[ -f "$RELEASE_DIR/SHA256SUMS" ]]; then
        echo "  ✓ Checksums: SHA256SUMS"
    fi

    if [[ -f "$RELEASE_DIR/RELEASE_NOTES.md" ]]; then
        echo "  ✓ Release Notes: RELEASE_NOTES.md"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_success "Release build completed! Artifacts ready at: $RELEASE_DIR"
    echo ""
}

# Cleanup function
cleanup() {
    log_debug "Cleanup function called"
    # For releases, we always keep artifacts, so minimal cleanup
}

# Signal handler
signal_handler() {
    local signal="${1:-UNKNOWN}"
    log_warn "Received signal: $signal, cleaning up..."
    cleanup
    exit 130
}

# Main function
main() {
    local main_start_time
    main_start_time=$(date +%s)

    # Set up signal handlers
    trap 'signal_handler SIGINT' SIGINT
    trap 'signal_handler SIGTERM' SIGTERM

    # Parse arguments
    parse_args "$@"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Release Build Orchestrator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Detect version
    detect_version || exit 1

    # Validate environment
    validate_environment || exit 1

    # Setup release environment
    setup_release_env || exit 1

    # Execute phases
    local exit_code=0

    if ! build_phase; then
        log_error "Build phase failed"
        exit_code=1
    elif ! package_phase; then
        log_error "Package phase failed"
        exit_code=1
    elif ! validation_phase; then
        log_warn "Validation phase completed with warnings"
        # Don't set exit_code, continue
    fi

    # Generate checksums (always run unless explicitly disabled)
    if ! checksum_phase; then
        log_error "Checksum generation failed"
        exit_code=1
    fi

    # Generate release report
    generate_release_report

    local main_end_time
    main_end_time=$(date +%s)
    local total_duration=$((main_end_time - main_start_time))

    if [[ $exit_code -eq 0 ]]; then
        print_summary
        echo "Total build time: ${total_duration}s"
        echo ""
    else
        log_error "Release build failed after ${total_duration}s"
        echo ""
        exit $exit_code
    fi

    exit $exit_code
}

# Run main function with all arguments
main "$@"
