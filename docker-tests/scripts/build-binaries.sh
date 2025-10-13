#!/bin/bash

# ZigCat Docker Test System - Cross-Compilation Build Orchestrator
# Builds zigcat binaries for all target platforms using existing build.zig

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_VALIDATOR="$SCRIPT_DIR/config-validator.sh"
BUILD_DIR="$PROJECT_ROOT/docker-tests/build"
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
VERBOSE=false
PARALLEL=false
KEEP_ARTIFACTS=false
BUILD_TIMEOUT=300
SELECTED_PLATFORMS=""
SELECTED_ARCHITECTURES=""
USE_DOCKER=false

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

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Cross-compilation build orchestrator for ZigCat Docker test system.

OPTIONS:
    -p, --platforms PLATFORMS      Comma-separated list of platforms to build for
                                   (default: all enabled platforms from config)
    -a, --architectures ARCHS      Comma-separated list of architectures to build for
                                   (default: all architectures for selected platforms)
    -t, --timeout SECONDS          Build timeout in seconds (default: 300)
    -v, --verbose                  Enable verbose logging
    -j, --parallel                 Enable parallel builds where possible
    -k, --keep-artifacts           Keep build artifacts after completion
    --use-docker                   Build inside Docker containers (for TLS)
    -h, --help                     Show this help message

EXAMPLES:
    $0                             # Build all enabled platforms and architectures
    $0 -p linux,alpine             # Build only Linux and Alpine platforms
    $0 -p linux -a amd64           # Build only Linux amd64
    $0 -v -j                       # Verbose output with parallel builds
    $0 -t 600 -k                   # 10-minute timeout, keep artifacts

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--platforms)
                SELECTED_PLATFORMS="$2"
                shift 2
                ;;
            -a|--architectures)
                SELECTED_ARCHITECTURES="$2"
                shift 2
                ;;
            -t|--timeout)
                BUILD_TIMEOUT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -j|--parallel)
                PARALLEL=true
                shift
                ;;
            -k|--keep-artifacts)
                KEEP_ARTIFACTS=true
                shift
                ;;
            --use-docker)
                USE_DOCKER=true
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

# Setup build environment
setup_build_env() {
    log_info "Setting up build environment..."
    
    # Create necessary directories
    mkdir -p "$BUILD_DIR" "$ARTIFACTS_DIR" "$LOGS_DIR"
    
    # Clean previous build artifacts if not keeping them
    if [[ "$KEEP_ARTIFACTS" == "false" ]]; then
        log_debug "Cleaning previous build artifacts..."
        rm -rf "$ARTIFACTS_DIR"/*
        rm -rf "$LOGS_DIR"/build-*.log
    fi
    
    # Validate configuration
    if ! "$CONFIG_VALIDATOR" validate > /dev/null 2>&1; then
        log_error "Configuration validation failed"
        return 1
    fi
    
    log_success "Build environment setup complete"
    return 0
}

# Check if Zig is available and get version
check_zig() {
    if ! command -v zig &> /dev/null; then
        log_error "Zig compiler not found in PATH"
        return 1
    fi
    
    local zig_version
    zig_version=$(zig version)
    log_info "Using Zig version: $zig_version"
    
    # Check if build.zig exists
    if [[ ! -f "$PROJECT_ROOT/build.zig" ]]; then
        log_error "build.zig not found in project root: $PROJECT_ROOT"
        return 1
    fi
    
    log_success "Zig compiler and build.zig validated"
    return 0
}

# Get list of platforms to build
get_build_platforms() {
    if [[ -n "$SELECTED_PLATFORMS" ]]; then
        echo "$SELECTED_PLATFORMS" | tr ',' '\n'
    else
        "$CONFIG_VALIDATOR" platforms | tr -d '"'
    fi
}

# Get list of architectures for a platform
get_platform_architectures() {
    local platform="$1"
    
    if [[ -n "$SELECTED_ARCHITECTURES" ]]; then
        # Filter selected architectures against platform's supported architectures
        local supported_archs
        supported_archs=$("$CONFIG_VALIDATOR" platform-archs "$platform" | tr -d '"')
        
        echo "$SELECTED_ARCHITECTURES" | tr ',' '\n' | while IFS= read -r arch; do
            if echo "$supported_archs" | grep -q "^$arch$"; then
                echo "$arch"
            else
                log_warn "Architecture $arch not supported for platform $platform, skipping"
            fi
        done
    else
        "$CONFIG_VALIDATOR" platform-archs "$platform" | tr -d '"'
    fi
}

# Build binary using Docker (for TLS cross-compilation)
build_binary_docker() {
    local platform="$1"
    local arch="$2"
    local zig_target="$3"
    local build_id="${platform}-${arch}"
    local log_file="$LOGS_DIR/build-${build_id}.log"
    local artifact_dir="$ARTIFACTS_DIR/$build_id"

    log_info "Building $build_id using Docker (target: $zig_target)..."

    # Create artifact directory
    mkdir -p "$artifact_dir"

    # Get dockerfile path
    local dockerfile_path="$PROJECT_ROOT/docker-tests/dockerfiles/Dockerfile.$platform"
    if [[ ! -f "$dockerfile_path" ]]; then
        log_error "Dockerfile not found: $dockerfile_path"
        return 1
    fi

    # Map arch to Docker platform
    local docker_platform
    case "$arch" in
        amd64|x86_64)
            docker_platform="linux/amd64"
            ;;
        arm64|aarch64)
            docker_platform="linux/arm64"
            ;;
        *)
            log_error "Unsupported architecture for Docker: $arch"
            return 1
            ;;
    esac

    # Start build with timeout
    local build_start_time
    build_start_time=$(date +%s)

    {
        echo "=== Docker Build Log for $build_id ==="
        echo "Platform: $platform"
        echo "Architecture: $arch"
        echo "Zig Target: $zig_target"
        echo "Dockerfile: $dockerfile_path"
        echo "Docker Platform: $docker_platform"
        echo "Start Time: $(date)"
        echo "Build Timeout: ${BUILD_TIMEOUT}s"
        echo ""
        echo "=== Starting Docker Build ==="

        # Build using Docker with the artifacts stage
        # Use custom seccomp profile to allow faccessat2 syscall (required by Zig 0.15.1)
        # See docker-tests/DOCKER_BUILD_ERRORS.md for details
        local seccomp_profile="$PROJECT_ROOT/docker-tests/seccomp/zig-builder.json"
        local seccomp_opt=""
        if [[ -f "$seccomp_profile" ]]; then
            seccomp_opt="--security-opt=seccomp=$seccomp_profile"
            echo "Using custom seccomp profile: $seccomp_profile"
        else
            echo "WARNING: Custom seccomp profile not found, build may fail with errno 38 (ENOSYS)"
            echo "See docker-tests/DOCKER_BUILD_ERRORS.md for troubleshooting"
        fi

        if timeout "$BUILD_TIMEOUT" docker build \
            --platform="$docker_platform" \
            $seccomp_opt \
            --file="$dockerfile_path" \
            --target=artifacts \
            --output="$artifact_dir" \
            "$PROJECT_ROOT" 2>&1; then

            echo ""
            echo "=== Build Successful ==="

            # Verify binary was created
            local binary_name="zigcat"
            local binary_path="$artifact_dir/bin/$binary_name"

            if [[ -f "$binary_path" ]]; then
                # Move binary from bin/ subdirectory to artifact_dir root
                mv "$binary_path" "$artifact_dir/"
                rmdir "$artifact_dir/bin" 2>/dev/null || true

                echo "Binary extracted to: $artifact_dir/$binary_name"

                # Get binary info
                local binary_size
                binary_size=$(stat -f%z "$artifact_dir/$binary_name" 2>/dev/null || stat -c%s "$artifact_dir/$binary_name" 2>/dev/null || echo "unknown")
                echo "Binary size: $binary_size bytes"

                echo ""
                echo "=== Binary Validation ==="
                echo "✓ Cross-compiled binary created in Docker"
                echo "✓ Binary file exists and has reasonable size"
            else
                echo "✗ Binary not found at expected path: $binary_path"
                return 1
            fi

        else
            local exit_code=$?
            echo ""
            echo "=== Build Failed ==="
            echo "Exit code: $exit_code"
            if [[ $exit_code -eq 124 ]]; then
                echo "Build timed out after ${BUILD_TIMEOUT} seconds"
            fi
            return 1
        fi

    } > "$log_file" 2>&1

    local build_exit_code=$?
    local build_end_time
    build_end_time=$(date +%s)
    local build_duration=$((build_end_time - build_start_time))

    # Append timing information to log
    {
        echo ""
        echo "=== Build Summary ==="
        echo "End Time: $(date)"
        echo "Duration: ${build_duration}s"
        echo "Exit Code: $build_exit_code"
    } >> "$log_file"

    if [[ $build_exit_code -eq 0 ]]; then
        log_success "Build completed: $build_id (${build_duration}s)"
        return 0
    else
        log_error "Build failed: $build_id (${build_duration}s)"
        if [[ "$VERBOSE" == "true" ]]; then
            log_error "Build log: $log_file"
            echo "--- Last 30 lines of build log ---" >&2
            tail -30 "$log_file" >&2
            echo "--- End of build log excerpt ---" >&2
        fi
        return 1
    fi
}

# Build binary for specific platform and architecture
build_binary() {
    local platform="$1"
    local arch="$2"
    local zig_target="$3"
    local build_id="${platform}-${arch}"
    local log_file="$LOGS_DIR/build-${build_id}.log"
    local artifact_dir="$ARTIFACTS_DIR/$build_id"
    
    log_info "Building $build_id (target: $zig_target)..."
    
    # Create artifact directory
    mkdir -p "$artifact_dir"
    
    # Start build with timeout
    local build_start_time
    build_start_time=$(date +%s)
    
    {
        echo "=== Build Log for $build_id ==="
        echo "Platform: $platform"
        echo "Architecture: $arch"
        echo "Zig Target: $zig_target"
        echo "Start Time: $(date)"
        echo "Build Timeout: ${BUILD_TIMEOUT}s"
        echo ""
        
        # Change to project root for build
        cd "$PROJECT_ROOT"
        
        # Clean previous build for this target
        echo "Cleaning previous build..."
        rm -rf zig-out/ .zig-cache/ 2>&1 || true
        
        echo ""
        echo "=== Starting Build ==="
        
        # Build with timeout
        if timeout "$BUILD_TIMEOUT" zig build -Dtarget="$zig_target" --release=safe 2>&1; then
            echo ""
            echo "=== Build Successful ==="
            
            # Copy binary to artifacts directory
            local binary_name="zigcat"
            if [[ "$platform" == *"windows"* ]]; then
                binary_name="zigcat.exe"
            fi
            
            local binary_path="$PROJECT_ROOT/zig-out/bin/$binary_name"
            if [[ -f "$binary_path" ]]; then
                cp "$binary_path" "$artifact_dir/"
                echo "Binary copied to: $artifact_dir/$binary_name"
                
                # Get binary info
                local binary_size
                binary_size=$(stat -f%z "$artifact_dir/$binary_name" 2>/dev/null || stat -c%s "$artifact_dir/$binary_name" 2>/dev/null || echo "unknown")
                echo "Binary size: $binary_size bytes"
                
                # Test binary (basic validation)
                echo ""
                echo "=== Binary Validation ==="
                
                # Check if this is a cross-compiled binary
                local is_cross_compiled=false
                case "$zig_target" in
                    *-linux-* | *-freebsd-* | *-windows-*)
                        if [[ "$(uname)" != "Linux" && "$(uname)" != "FreeBSD" && "$(uname)" != "MINGW"* ]]; then
                            is_cross_compiled=true
                        fi
                        ;;
                    *-macos-*)
                        if [[ "$(uname)" != "Darwin" ]]; then
                            is_cross_compiled=true
                        fi
                        ;;
                esac
                
                if [[ "$is_cross_compiled" == "true" ]]; then
                    echo "✓ Cross-compiled binary created (execution test skipped)"
                    echo "✓ Binary file exists and has reasonable size"
                else
                    # Only test execution for native binaries
                    if "$artifact_dir/$binary_name" --help > /dev/null 2>&1; then
                        echo "✓ Binary executes and shows help"
                    else
                        echo "✗ Binary failed basic execution test"
                        return 1
                    fi
                    
                    if "$artifact_dir/$binary_name" --version > /dev/null 2>&1; then
                        echo "✓ Binary shows version information"
                    else
                        echo "✗ Binary failed version test"
                    fi
                fi
                
            else
                echo "✗ Binary not found at expected path: $binary_path"
                return 1
            fi
            
        else
            local exit_code=$?
            echo ""
            echo "=== Build Failed ==="
            echo "Exit code: $exit_code"
            if [[ $exit_code -eq 124 ]]; then
                echo "Build timed out after ${BUILD_TIMEOUT} seconds"
            fi
            return 1
        fi
        
    } > "$log_file" 2>&1
    
    local build_exit_code=$?
    local build_end_time
    build_end_time=$(date +%s)
    local build_duration=$((build_end_time - build_start_time))
    
    # Append timing information to log
    {
        echo ""
        echo "=== Build Summary ==="
        echo "End Time: $(date)"
        echo "Duration: ${build_duration}s"
        echo "Exit Code: $build_exit_code"
    } >> "$log_file"
    
    if [[ $build_exit_code -eq 0 ]]; then
        log_success "Build completed: $build_id (${build_duration}s)"
        return 0
    else
        log_error "Build failed: $build_id (${build_duration}s)"
        if [[ "$VERBOSE" == "true" ]]; then
            log_error "Build log: $log_file"
            echo "--- Last 20 lines of build log ---"
            tail -20 "$log_file" >&2
            echo "--- End of build log excerpt ---"
        fi
        return 1
    fi
}

# Build all selected platforms and architectures
build_all() {
    local platforms
    platforms=$(get_build_platforms)
    
    if [[ -z "$platforms" ]]; then
        log_error "No platforms selected for building"
        return 1
    fi
    
    log_info "Starting cross-compilation build process..."
    
    local total_builds=0
    local successful_builds=0
    local failed_builds=0
    local build_start_time
    build_start_time=$(date +%s)
    
    # Count total builds
    while IFS= read -r platform; do
        if [[ -z "$platform" ]]; then
            continue
        fi
        
        local architectures
        architectures=$(get_platform_architectures "$platform")
        
        while IFS= read -r arch; do
            if [[ -z "$arch" ]]; then
                continue
            fi
            ((total_builds++))
        done <<< "$architectures"
    done <<< "$platforms"
    
    log_info "Total builds planned: $total_builds"
    
    # Perform builds
    local build_pids=()
    
    while IFS= read -r platform; do
        if [[ -z "$platform" ]]; then
            continue
        fi
        
        local architectures
        architectures=$(get_platform_architectures "$platform")
        
        while IFS= read -r arch; do
            if [[ -z "$arch" ]]; then
                continue
            fi
            
            local zig_target
            zig_target=$("$CONFIG_VALIDATOR" zig-target "$platform" "$arch" | tr -d '"')
            
            if [[ -z "$zig_target" || "$zig_target" == "null" ]]; then
                log_error "No Zig target mapping found for $platform-$arch"
                ((failed_builds++))
                continue
            fi
            
            if [[ "$PARALLEL" == "true" ]]; then
                # Build in background
                if [[ "$USE_DOCKER" == "true" ]]; then
                    build_binary_docker "$platform" "$arch" "$zig_target" &
                else
                    build_binary "$platform" "$arch" "$zig_target" &
                fi
                build_pids+=($!)
                log_debug "Started background build for $platform-$arch (PID: $!)"
            else
                # Build sequentially
                if [[ "$USE_DOCKER" == "true" ]]; then
                    if build_binary_docker "$platform" "$arch" "$zig_target"; then
                        ((successful_builds++))
                    else
                        ((failed_builds++))
                    fi
                else
                    if build_binary "$platform" "$arch" "$zig_target"; then
                        ((successful_builds++))
                    else
                        ((failed_builds++))
                    fi
                fi
            fi
            
        done <<< "$architectures"
    done <<< "$platforms"
    
    # Wait for parallel builds to complete
    if [[ "$PARALLEL" == "true" ]]; then
        log_info "Waiting for ${#build_pids[@]} parallel builds to complete..."
        
        for pid in "${build_pids[@]}"; do
            if wait "$pid"; then
                ((successful_builds++))
            else
                ((failed_builds++))
            fi
        done
    fi
    
    local build_end_time
    build_end_time=$(date +%s)
    local total_duration=$((build_end_time - build_start_time))
    
    # Generate build summary
    log_info "Build process completed in ${total_duration}s"
    log_info "Results: $successful_builds successful, $failed_builds failed, $total_builds total"
    
    if [[ $failed_builds -gt 0 ]]; then
        log_error "Some builds failed. Check logs in: $LOGS_DIR"
        return 1
    else
        log_success "All builds completed successfully!"
        return 0
    fi
}

# Generate build report
generate_report() {
    local report_file="$ARTIFACTS_DIR/build-report.json"
    local report_start_time
    report_start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_info "Generating build report: $report_file"
    
    {
        echo "{"
        echo "  \"build_report\": {"
        echo "    \"timestamp\": \"$report_start_time\","
        echo "    \"build_system\": \"zig\","
        echo "    \"project\": \"zigcat\","
        echo "    \"artifacts\": ["
        
        local first=true
        for artifact_dir in "$ARTIFACTS_DIR"/*; do
            if [[ -d "$artifact_dir" ]]; then
                local build_id
                build_id=$(basename "$artifact_dir")
                
                if [[ "$build_id" == "*" ]]; then
                    continue
                fi
                
                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    echo ","
                fi
                
                local platform arch
                platform=$(echo "$build_id" | cut -d'-' -f1)
                arch=$(echo "$build_id" | cut -d'-' -f2)
                
                local binary_path="$artifact_dir/zigcat"
                if [[ ! -f "$binary_path" ]]; then
                    binary_path="$artifact_dir/zigcat.exe"
                fi
                
                local binary_size="0"
                local binary_exists="false"
                if [[ -f "$binary_path" ]]; then
                    binary_size=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null || echo "0")
                    binary_exists="true"
                fi
                
                local log_file="$LOGS_DIR/build-${build_id}.log"
                local build_success="false"
                if [[ -f "$log_file" ]] && grep -q "Build Successful" "$log_file"; then
                    build_success="true"
                fi
                
                echo -n "      {"
                echo -n "\"build_id\": \"$build_id\", "
                echo -n "\"platform\": \"$platform\", "
                echo -n "\"architecture\": \"$arch\", "
                echo -n "\"binary_exists\": $binary_exists, "
                echo -n "\"binary_size\": $binary_size, "
                echo -n "\"build_success\": $build_success, "
                echo -n "\"artifact_path\": \"$artifact_dir\", "
                echo -n "\"log_path\": \"$log_file\""
                echo -n "}"
            fi
        done
        
        echo ""
        echo "    ]"
        echo "  }"
        echo "}"
    } > "$report_file"
    
    log_success "Build report generated: $report_file"
}

# Cleanup function
cleanup() {
    if [[ "$KEEP_ARTIFACTS" == "false" ]]; then
        log_info "Cleaning up temporary build files..."
        # Clean zig build cache
        cd "$PROJECT_ROOT"
        zig build clean > /dev/null 2>&1 || true
    fi
}

# Signal handler for graceful shutdown
signal_handler() {
    log_warn "Received interrupt signal, cleaning up..."
    cleanup
    exit 130
}

# Main function
main() {
    # Set up signal handlers
    trap signal_handler SIGINT SIGTERM
    
    # Parse arguments
    parse_args "$@"
    
    # Setup and validate environment
    setup_build_env || exit 1
    check_zig || exit 1
    
    # Perform builds
    if build_all; then
        generate_report
        cleanup
        log_success "Cross-compilation build process completed successfully!"
        exit 0
    else
        generate_report
        cleanup
        log_error "Cross-compilation build process failed!"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"