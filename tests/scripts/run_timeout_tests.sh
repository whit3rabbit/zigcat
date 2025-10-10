#!/bin/bash
#
# Timeout Test Runner for Zigcat
#
# Runs timeout tests with a global timeout to prevent hanging test suites.
# Individual tests have their own timeouts, but this provides a safety net.
#

set -euo pipefail

# Configuration
GLOBAL_TIMEOUT=300  # 5 minutes for entire test suite
TEST_TIMEOUT=30     # 30 seconds per individual test
LOG_FILE="timeout_test_results.log"
VERBOSE=${VERBOSE:-0}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print formatted message
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

# Check if running in CI environment
is_ci() {
    [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]
}

# Run a command with timeout
run_with_timeout() {
    local timeout=$1
    shift

    if command -v timeout &> /dev/null; then
        # GNU timeout
        timeout --signal=KILL "${timeout}s" "$@"
    elif command -v gtimeout &> /dev/null; then
        # macOS with coreutils
        gtimeout --signal=KILL "${timeout}s" "$@"
    else
        # Fallback: use perl
        perl -e 'alarm shift @ARGV; exec @ARGV' "$timeout" "$@"
    fi
}

# Main test execution
main() {
    log "Starting Zigcat Timeout Test Suite"
    log "Global timeout: ${GLOBAL_TIMEOUT}s"
    log "Per-test timeout: ${TEST_TIMEOUT}s"
    echo "" | tee -a "$LOG_FILE"

    # Clear previous log
    > "$LOG_FILE"

    # Build tests
    log "Building timeout tests..."
    if ! zig build test 2>&1 | tee -a "$LOG_FILE"; then
        error "Build failed"
        exit 1
    fi
    success "Build completed"
    echo "" | tee -a "$LOG_FILE"

    # Find test binary
    local test_binary
    test_binary=$(find zig-out zig-cache -name "test" -type f 2>/dev/null | head -1)

    if [[ -z "$test_binary" ]]; then
        # Fallback: run via zig build test
        log "Running tests via 'zig build test'..."

        if run_with_timeout "$GLOBAL_TIMEOUT" zig build test --summary all 2>&1 | tee -a "$LOG_FILE"; then
            success "All timeout tests passed!"
            exit 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]] || [[ $exit_code -eq 137 ]]; then
                error "Test suite timed out after ${GLOBAL_TIMEOUT}s"
                error "This indicates a test is hanging - review timeout_tests.zig"
                exit 2
            else
                error "Some tests failed (exit code: $exit_code)"
                exit 1
            fi
        fi
    fi

    # Run test binary with global timeout
    log "Executing test binary: $test_binary"

    local start_time
    start_time=$(date +%s)

    if run_with_timeout "$GLOBAL_TIMEOUT" "$test_binary" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        echo "" | tee -a "$LOG_FILE"
        success "All timeout tests passed!"
        log "Total execution time: ${duration}s"

        if [[ $duration -gt $((GLOBAL_TIMEOUT / 2)) ]]; then
            warning "Tests took longer than expected (${duration}s > ${GLOBAL_TIMEOUT}/2)"
            warning "Consider reviewing test performance"
        fi

        exit 0
    else
        local exit_code=$?
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        echo "" | tee -a "$LOG_FILE"

        if [[ $exit_code -eq 124 ]] || [[ $exit_code -eq 137 ]]; then
            error "Test suite timed out after ${GLOBAL_TIMEOUT}s (ran for ${duration}s)"
            error "This indicates a test is hanging - review timeout_tests.zig"
            error "Check for:"
            error "  - Tests without proper timeout handling"
            error "  - Mock servers not properly shutting down"
            error "  - Infinite loops in test code"
            exit 2
        else
            error "Some tests failed (exit code: $exit_code, duration: ${duration}s)"
            exit 1
        fi
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -t|--timeout)
            GLOBAL_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Run Zigcat timeout tests with safety timeouts.

OPTIONS:
    -v, --verbose       Enable verbose output
    -t, --timeout SEC   Set global timeout in seconds (default: 300)
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    VERBOSE             Set to 1 for verbose output
    CI                  Detected automatically for CI environments

EXIT CODES:
    0   All tests passed
    1   Some tests failed
    2   Test suite timed out (indicates hanging test)

EXAMPLES:
    $0                      # Run with default settings
    $0 -v                   # Run with verbose output
    $0 -t 600              # Run with 10 minute timeout
    VERBOSE=1 $0           # Run with verbose output via env var

EOF
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Execute main function with global timeout as safety net
main
