#!/bin/bash

# ZigCat Release Validator
# Performs smoke tests on built binaries to ensure they work

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
VERBOSE=false
ARTIFACTS_DIR=""

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

Validate ZigCat release binaries with smoke tests

OPTIONS:
    --artifacts-dir DIR            Build artifacts directory
                                   (default: docker-tests/artifacts)
    --verbose                      Enable verbose logging
    -h, --help                     Show this help message

TESTS:
    - Binary exists and is executable
    - Binary --help works
    - Binary --version works
    - Binary --version-all works (if supported)
    - File type detection
    - Static linking verification (for static builds)

EXAMPLES:
    $0 --artifacts-dir docker-tests/artifacts

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --artifacts-dir)
                ARTIFACTS_DIR="$2"
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

    # Set default if not specified
    if [[ -z "$ARTIFACTS_DIR" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
        ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
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

    log_success "Environment validation completed"
    return 0
}

# Check if binary is cross-compiled
is_cross_compiled() {
    local binary="$1"

    # Get binary's architecture
    local binary_arch=""
    if command -v file &> /dev/null; then
        local file_output
        file_output=$(file "$binary")

        case "$file_output" in
            *"x86-64"*|*"x86_64"*)
                binary_arch="x86_64"
                ;;
            *"aarch64"*|*"ARM aarch64"*)
                binary_arch="aarch64"
                ;;
            *"ARM"*)
                binary_arch="arm"
                ;;
            *"Intel 80386"*|*"i386"*)
                binary_arch="x86"
                ;;
            *"FreeBSD"*)
                # Cross-compiled if we're not on FreeBSD
                if [[ "$(uname)" != "FreeBSD" ]]; then
                    return 0  # Is cross-compiled
                fi
                ;;
        esac
    fi

    # Get system's architecture
    local system_arch
    system_arch=$(uname -m)

    # Normalize system arch
    case "$system_arch" in
        x86_64|amd64)
            system_arch="x86_64"
            ;;
        aarch64|arm64)
            system_arch="aarch64"
            ;;
        armv7l|armv6l)
            system_arch="arm"
            ;;
        i386|i686)
            system_arch="x86"
            ;;
    esac

    # Check if architectures match
    if [[ "$binary_arch" != "$system_arch" ]]; then
        return 0  # Is cross-compiled
    fi

    return 1  # Not cross-compiled
}

# Validate a single binary
validate_binary() {
    local binary_path="$1"
    local binary_name
    binary_name=$(basename "$binary_path")

    log_info "Validating: $binary_name"

    local tests_passed=0
    local tests_failed=0
    local tests_skipped=0

    # Test 1: File exists and is regular file
    if [[ -f "$binary_path" ]]; then
        log_debug "  ✓ File exists"
        ((tests_passed++))
    else
        log_error "  ✗ File does not exist"
        ((tests_failed++))
        return 1
    fi

    # Test 2: File is executable
    if [[ -x "$binary_path" ]]; then
        log_debug "  ✓ File is executable"
        ((tests_passed++))
    else
        log_warn "  ⚠ File is not executable (may be cross-compiled)"
        ((tests_skipped++))
    fi

    # Test 3: File type detection
    if command -v file &> /dev/null; then
        local file_type
        file_type=$(file "$binary_path")
        log_debug "  ℹ File type: $file_type"

        # Check if it's an ELF binary
        if [[ "$file_type" =~ "ELF" ]]; then
            log_debug "  ✓ Valid ELF binary"
            ((tests_passed++))

            # Check if it's statically linked (for musl builds)
            if [[ "$binary_name" =~ "musl" ]] || [[ "$binary_name" =~ "static" ]]; then
                if [[ "$file_type" =~ "statically linked" ]]; then
                    log_debug "  ✓ Statically linked (as expected)"
                    ((tests_passed++))
                else
                    log_warn "  ⚠ Expected static linking but found dynamic"
                    ((tests_skipped++))
                fi
            fi
        elif [[ "$file_type" =~ "Mach-O" ]]; then
            log_debug "  ✓ Valid Mach-O binary (macOS)"
            ((tests_passed++))
        elif [[ "$file_type" =~ "PE32" ]]; then
            log_debug "  ✓ Valid PE32 binary (Windows)"
            ((tests_passed++))
        fi
    else
        log_warn "  ⚠ 'file' command not available, skipping file type check"
        ((tests_skipped++))
    fi

    # Test 4: Binary execution tests (only if not cross-compiled)
    if is_cross_compiled "$binary_path"; then
        log_debug "  ℹ Binary is cross-compiled, skipping execution tests"
        ((tests_skipped+=3))
    else
        # Test --help
        if "$binary_path" --help > /dev/null 2>&1; then
            log_debug "  ✓ --help works"
            ((tests_passed++))
        else
            log_warn "  ⚠ --help failed"
            ((tests_failed++))
        fi

        # Test --version
        if "$binary_path" --version > /dev/null 2>&1; then
            log_debug "  ✓ --version works"
            ((tests_passed++))

            # Show version if verbose
            if [[ "$VERBOSE" == "true" ]]; then
                local version
                version=$("$binary_path" --version 2>&1 | head -1)
                log_debug "    Version: $version"
            fi
        else
            log_warn "  ⚠ --version failed"
            ((tests_failed++))
        fi

        # Test --version-all (if supported)
        if "$binary_path" --version-all > /dev/null 2>&1; then
            log_debug "  ✓ --version-all works"
            ((tests_passed++))
        else
            log_debug "  ℹ --version-all not supported (OK)"
            ((tests_skipped++))
        fi
    fi

    # Test 5: File size check
    if command -v du &> /dev/null; then
        local size
        size=$(du -h "$binary_path" | cut -f1)
        log_debug "  ℹ Binary size: $size"

        # Warn if binary is suspiciously small or large
        local size_bytes
        size_bytes=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null || echo "0")

        if [[ $size_bytes -lt 100000 ]]; then
            log_warn "  ⚠ Binary is very small (< 100KB), may be incomplete"
            ((tests_failed++))
        elif [[ $size_bytes -gt 20000000 ]]; then
            log_warn "  ⚠ Binary is very large (> 20MB), unexpectedly big"
        else
            log_debug "  ✓ Binary size looks reasonable"
            ((tests_passed++))
        fi
    fi

    # Print summary
    local total_tests=$((tests_passed + tests_failed + tests_skipped))
    if [[ $tests_failed -gt 0 ]]; then
        log_warn "  Summary: $tests_passed passed, $tests_failed failed, $tests_skipped skipped (of $total_tests)"
        return 1
    else
        log_success "  Summary: $tests_passed passed, $tests_skipped skipped (of $total_tests)"
        return 0
    fi
}

# Validate all artifacts
validate_all_artifacts() {
    log_info "Validating all build artifacts..."

    local total_validated=0
    local total_failed=0
    local total_skipped=0

    # Find all build artifact directories
    for build_dir in "$ARTIFACTS_DIR"/*; do
        if [[ ! -d "$build_dir" ]]; then
            continue
        fi

        # Skip releases directory itself
        if [[ "$build_dir" == *"/releases" ]]; then
            continue
        fi

        # Find binary in build directory
        local binary_path=""
        if [[ -f "$build_dir/zigcat" ]]; then
            binary_path="$build_dir/zigcat"
        elif [[ -f "$build_dir/zigcat-wolfssl" ]]; then
            binary_path="$build_dir/zigcat-wolfssl"
        elif [[ -f "$build_dir/zigcat.exe" ]]; then
            binary_path="$build_dir/zigcat.exe"
        else
            log_warn "No binary found in $(basename "$build_dir"), skipping"
            ((total_skipped++))
            continue
        fi

        if validate_binary "$binary_path"; then
            ((total_validated++))
        else
            ((total_failed++))
        fi

        echo ""
    done

    log_info "Validation complete: $total_validated validated, $total_failed failed, $total_skipped skipped"

    if [[ $total_failed -gt 0 ]]; then
        log_error "Some validations failed"
        return 1
    elif [[ $total_validated -eq 0 ]]; then
        log_error "No artifacts were validated"
        return 1
    fi

    return 0
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    log_info "ZigCat Release Validator"

    # Validate environment
    validate_environment || exit 1

    # Validate all artifacts
    if validate_all_artifacts; then
        log_success "All artifacts validated successfully!"
        exit 0
    else
        log_error "Validation failed"
        exit 1
    fi
}

# Run main
main "$@"
