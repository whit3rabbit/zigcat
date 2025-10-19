#!/bin/bash

# ZigCat Enhanced Release Build Orchestrator v2
# Builds complete release artifacts for all platforms with continue-on-error support
# Creates descriptive filenames and handles failures gracefully

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"
DOCKERFILES_DIR="$PROJECT_ROOT/docker-tests/dockerfiles"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
VERBOSE=false
VERSION=""
CONTINUE_ON_ERROR=true
BUILD_TIMEOUT=600
SUCCESSFUL_BUILDS=()
FAILED_BUILDS=()
SKIPPED_BUILDS=()

# Build matrix - explicit platform definitions
declare -A BUILD_MATRIX=(
    # Linux glibc x64 with OpenSSL
    ["linux-x64-openssl"]="linux:amd64:x86_64-linux-gnu:-Dtls=true -Dtls-backend=openssl:glibc-openssl-dynamic"

    # Linux glibc ARM64 with OpenSSL
    ["linux-arm64-openssl"]="linux:arm64:aarch64-linux-gnu:-Dtls=true -Dtls-backend=openssl:glibc-openssl-dynamic"

    # Linux musl x64 static (no TLS)
    ["linux-x64-static"]="linux:amd64:x86_64-linux-musl:-Dstatic=true -Dtls=false:musl-static"

    # Linux musl ARM64 static (no TLS)
    ["linux-arm64-static"]="linux:arm64:aarch64-linux-musl:-Dstatic=true -Dtls=false:musl-static"

    # Alpine x64 with wolfSSL
    ["alpine-x64-wolfssl"]="alpine:amd64:x86_64-linux-musl:-Dstatic=true -Dtls=true -Dtls-backend=wolfssl:musl-wolfssl-static"

    # Alpine ARM64 with wolfSSL
    ["alpine-arm64-wolfssl"]="alpine:arm64:aarch64-linux-musl:-Dstatic=true -Dtls=true -Dtls-backend=wolfssl:musl-wolfssl-static"

    # FreeBSD x64 (cross-compiled, no TLS)
    ["freebsd-x64"]="freebsd:amd64:x86_64-freebsd:-Dtls=false:freebsd"
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

ZigCat Enhanced Release Build Orchestrator v2
Build complete release artifacts with descriptive names and continue-on-error

OPTIONS:
    -v, --version VERSION      Release version (e.g., v0.0.1) [REQUIRED]
    --continue-on-error        Continue building if individual platforms fail (default: true)
    --stop-on-error            Stop if any platform fails
    --verbose                  Enable verbose logging
    --timeout SECONDS          Build timeout per platform (default: 600)
    -h, --help                 Show this help message

EXAMPLES:
    # Build all platforms for v0.0.1
    $0 --version v0.0.1

    # Build with verbose output
    $0 --version v0.0.1 --verbose

    # Stop on first failure
    $0 --version v0.0.1 --stop-on-error

PLATFORMS:
    - Linux x64 glibc+OpenSSL (dynamic, ~6MB)
    - Linux ARM64 glibc+OpenSSL (dynamic, ~6MB)
    - Linux x64 musl static (no TLS, ~2MB)
    - Linux ARM64 musl static (no TLS, ~2MB)
    - Alpine x64 musl+wolfSSL static (~835KB, GPLv2)
    - Alpine ARM64 musl+wolfSSL static (~865KB, GPLv2)
    - FreeBSD x64 (~300KB)

OUTPUT:
    docker-tests/artifacts/{platform}-{arch}/
    ├── zigcat (or zigcat-wolfssl)
    └── build.log

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            --continue-on-error)
                CONTINUE_ON_ERROR=true
                shift
                ;;
            --stop-on-error)
                CONTINUE_ON_ERROR=false
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --timeout)
                BUILD_TIMEOUT="$2"
                shift 2
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

    # Ensure version starts with 'v'
    if [[ "$VERSION" != v* ]]; then
        VERSION="v$VERSION"
    fi
}

# Validate environment
validate_environment() {
    log_step "Validating environment..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi

    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_error "Start Docker: systemctl start docker (Linux) or open Docker Desktop (macOS)"
        return 1
    fi

    # Create directories
    mkdir -p "$ARTIFACTS_DIR"
    mkdir -p "$LOGS_DIR"

    log_success "Environment validation completed"
    return 0
}

# Build a single platform
build_platform() {
    local build_id="$1"
    local build_spec="${BUILD_MATRIX[$build_id]}"

    IFS=':' read -r platform arch zig_target build_opts suffix <<< "$build_spec"

    log_step "Building: $build_id"
    log_debug "  Platform: $platform, Arch: $arch"
    log_debug "  Zig Target: $zig_target"
    log_debug "  Build Options: $build_opts"
    log_debug "  Suffix: $suffix"

    # Determine Docker platform
    local docker_platform="linux/$arch"

    # Determine Dockerfile
    local dockerfile=""
    case "$platform" in
        linux)
            dockerfile="$DOCKERFILES_DIR/Dockerfile.linux"
            ;;
        alpine)
            dockerfile="$DOCKERFILES_DIR/Dockerfile.alpine"
            ;;
        freebsd)
            dockerfile="$DOCKERFILES_DIR/Dockerfile.freebsd"
            ;;
        *)
            log_error "Unknown platform: $platform"
            return 1
            ;;
    esac

    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi

    # Prepare artifact directory
    local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
    mkdir -p "$artifact_dir"

    # Prepare log file
    local log_file="$LOGS_DIR/build-${build_id}.log"

    # Build command
    log_info "  Building with Docker (platform: $docker_platform)..."

    # Build arguments
    local build_args=(
        "--platform" "$docker_platform"
        "--build-arg" "ZIG_TARGET=$zig_target"
        "--build-arg" "BUILD_OPTIONS=$build_opts"
        "-f" "$dockerfile"
        "-t" "zigcat-builder-${build_id}:latest"
        "$PROJECT_ROOT"
    )

    log_debug "  Docker build command: docker build ${build_args[*]}"

    # Execute build
    if ! timeout "$BUILD_TIMEOUT" docker build "${build_args[@]}" > "$log_file" 2>&1; then
        log_error "  Build failed (see $log_file for details)"
        FAILED_BUILDS+=("$build_id")
        return 1
    fi

    # Extract binary from container
    log_info "  Extracting binary..."

    local container_id
    container_id=$(docker create "zigcat-builder-${build_id}:latest")

    # Determine binary name in container
    local binary_name="zigcat"
    if [[ "$suffix" == *"wolfssl"* ]]; then
        binary_name="zigcat-wolfssl"
    fi

    if ! docker cp "$container_id:/app/zig-out/bin/$binary_name" "$artifact_dir/zigcat" 2>> "$log_file"; then
        log_error "  Failed to extract binary"
        docker rm "$container_id" > /dev/null 2>&1
        FAILED_BUILDS+=("$build_id")
        return 1
    fi

    docker rm "$container_id" > /dev/null 2>&1

    # Get binary size
    local binary_size
    binary_size=$(du -h "$artifact_dir/zigcat" | cut -f1)

    log_success "  Build successful: $build_id ($binary_size)"
    SUCCESSFUL_BUILDS+=("$build_id:$platform:$arch:$suffix")

    return 0
}

# Build all platforms
build_all_platforms() {
    log_step "Building all platforms..."

    local total_builds=${#BUILD_MATRIX[@]}
    local current_build=0

    for build_id in "${!BUILD_MATRIX[@]}"; do
        ((current_build++))

        echo ""
        log_info "[$current_build/$total_builds] Processing: $build_id"

        if build_platform "$build_id"; then
            log_success "  ✅ $build_id"
        else
            log_error "  ❌ $build_id"

            if [[ "$CONTINUE_ON_ERROR" == "false" ]]; then
                log_error "Stopping due to build failure (--stop-on-error)"
                return 1
            fi

            log_warn "  Continuing to next build..."
        fi
    done

    log_success "Build phase completed"
    return 0
}

# Generate build report
generate_build_report() {
    log_step "Generating build report..."

    local report_file="$ARTIFACTS_DIR/BUILD_REPORT.md"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    {
        echo "# ZigCat Build Report - $VERSION"
        echo ""
        echo "**Build Date:** $timestamp"
        echo "**Continue on Error:** $CONTINUE_ON_ERROR"
        echo "**Build Timeout:** ${BUILD_TIMEOUT}s"
        echo ""
        echo "## Summary"
        echo ""
        echo "- **Total Builds:** ${#BUILD_MATRIX[@]}"
        echo "- **Successful:** ${#SUCCESSFUL_BUILDS[@]}"
        echo "- **Failed:** ${#FAILED_BUILDS[@]}"
        echo "- **Skipped:** ${#SKIPPED_BUILDS[@]}"
        echo ""

        if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
            echo "## Successful Builds"
            echo ""
            echo "| Build ID | Platform | Arch | Suffix | Binary Size |"
            echo "|----------|----------|------|--------|-------------|"

            for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
                IFS=':' read -r build_id platform arch suffix <<< "$build_info"
                local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
                local binary_size
                binary_size=$(du -h "$artifact_dir/zigcat" 2>/dev/null | cut -f1 || echo "N/A")
                echo "| $build_id | $platform | $arch | $suffix | $binary_size |"
            done
            echo ""
        fi

        if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
            echo "## Failed Builds"
            echo ""
            for build_id in "${FAILED_BUILDS[@]}"; do
                echo "- ❌ **$build_id** (see logs/$LOGS_DIR/build-${build_id}.log)"
            done
            echo ""
        fi

        if [[ ${#SKIPPED_BUILDS[@]} -gt 0 ]]; then
            echo "## Skipped Builds"
            echo ""
            for build_id in "${SKIPPED_BUILDS[@]}"; do
                echo "- ⚠️ **$build_id**"
            done
            echo ""
        fi

        echo "## Build Artifacts"
        echo ""
        echo "Artifacts are located in: \`$ARTIFACTS_DIR\`"
        echo ""

        for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
            IFS=':' read -r build_id platform arch suffix <<< "$build_info"
            local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
            echo "- \`${platform}-${arch}/zigcat\`"
        done

        echo ""
        echo "## Next Steps"
        echo ""
        echo "1. Package artifacts:"
        echo "   \`\`\`bash"
        echo "   ./docker-tests/scripts/package-release.sh --version $VERSION --compression 9 --create-deb --create-rpm"
        echo "   \`\`\`"
        echo ""
        echo "2. Generate checksums:"
        echo "   \`\`\`bash"
        echo "   ./docker-tests/scripts/generate-checksums.sh --release-dir docker-tests/artifacts/releases/$VERSION"
        echo "   \`\`\`"
        echo ""
        echo "---"
        echo "*Generated by ZigCat Enhanced Release Build System v2*"

    } > "$report_file"

    log_success "Build report generated: $report_file"
}

# Print summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Build Summary - $VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Total Platforms:    ${#BUILD_MATRIX[@]}"
    echo "  Successful:         ${#SUCCESSFUL_BUILDS[@]}"
    echo "  Failed:             ${#FAILED_BUILDS[@]}"
    echo "  Skipped:            ${#SKIPPED_BUILDS[@]}"
    echo ""

    if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
        echo "  ✅ Successful builds:"
        for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
            IFS=':' read -r build_id platform arch suffix <<< "$build_info"
            local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
            local binary_size
            binary_size=$(du -h "$artifact_dir/zigcat" 2>/dev/null | cut -f1 || echo "N/A")
            printf "     %-30s %8s\n" "$build_id" "$binary_size"
        done
    fi

    echo ""

    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        echo "  ❌ Failed builds:"
        for build_id in "${FAILED_BUILDS[@]}"; do
            echo "     - $build_id"
        done
        echo ""
    fi

    echo "  Artifacts: $ARTIFACTS_DIR"
    echo "  Logs:      $LOGS_DIR"
    echo ""
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
    echo "  ZigCat Enhanced Release Build Orchestrator v2"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Version: $VERSION"
    log_info "Continue on Error: $CONTINUE_ON_ERROR"
    echo ""

    # Validate environment
    validate_environment || exit 1

    # Build all platforms
    if build_all_platforms; then
        log_success "All builds completed"
    else
        if [[ "$CONTINUE_ON_ERROR" == "false" ]]; then
            log_error "Build failed"
            exit 1
        fi
    fi

    # Generate build report
    generate_build_report

    # Print summary
    print_summary

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "Total build time: ${duration}s"
    echo ""

    # Exit with appropriate code
    if [[ ${#SUCCESSFUL_BUILDS[@]} -eq 0 ]]; then
        log_error "No successful builds"
        exit 1
    fi

    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        log_warn "Some builds failed, but continuing..."
        exit 0  # Exit 0 if at least one build succeeded
    fi

    log_success "All builds successful!"
    exit 0
}

# Run main
main "$@"
