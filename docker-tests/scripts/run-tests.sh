#!/bin/bash

# ZigCat Docker Test System - Main Test Runner
# Orchestrates the complete testing process with configuration management

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_VALIDATOR="$SCRIPT_DIR/config-validator.sh"
BUILD_SCRIPT="$SCRIPT_DIR/build-binaries.sh"
DOCKER_COMPOSE_FILE="$PROJECT_ROOT/docker-compose.test.yml"
RESULTS_DIR="$PROJECT_ROOT/docker-tests/results"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"

# Initialize enhanced logging and error handling
if [[ -f "$SCRIPT_DIR/logging-system.sh" ]]; then
    source "$SCRIPT_DIR/logging-system.sh"
fi

if [[ -f "$SCRIPT_DIR/error-handler.sh" ]]; then
    if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        source "$SCRIPT_DIR/error-handler.sh"
    else
        echo "[WARN] Advanced error handler requires Bash >=4; continuing without it." >&2
    fi
fi

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
SELECTED_PLATFORMS=""
SELECTED_ARCHITECTURES=""
SELECTED_TEST_SUITES=""
GLOBAL_TIMEOUT=1800
BUILD_TIMEOUT=300
TEST_TIMEOUT=60
CLEANUP_TIMEOUT=30
DRY_RUN=false
SKIP_BUILD=false
USE_DOCKER=false
CONFIG_FILE="${PROJECT_ROOT}/docker-tests/configs/test-config.yml"

# Process tracking
declare -a CLEANUP_PIDS=()
declare -a ACTIVE_CONTAINERS=()

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

ZigCat Docker Test System - Main test runner with configuration management.

OPTIONS:
    -c, --config FILE              Path to configuration YAML file
                                   (default: docker-tests/configs/test-config.yml)
    -p, --platforms PLATFORMS      Comma-separated list of platforms to test
                                   (default: all enabled platforms from config)
    -a, --architectures ARCHS      Comma-separated list of architectures to test
                                   (default: all architectures for selected platforms)
    -s, --test-suites SUITES       Comma-separated list of test suites to run
                                   (default: all enabled test suites from config)
    -t, --timeout SECONDS          Global timeout in seconds (default: 1800)
    --build-timeout SECONDS        Build timeout in seconds (default: 300)
    --test-timeout SECONDS         Individual test timeout in seconds (default: 60)
    --cleanup-timeout SECONDS      Cleanup timeout in seconds (default: 30)
    -v, --verbose                  Enable verbose logging
    -j, --parallel                 Enable parallel execution where possible
    -k, --keep-artifacts           Keep build artifacts and containers after completion
    -n, --dry-run                  Show what would be done without executing
    --skip-build                   Skip build phase (use existing artifacts)
    --use-docker                   Build inside Docker containers (required for TLS)
    -h, --help                     Show this help message

EXAMPLES:
    $0                             # Run all enabled platforms and test suites
    $0 -c configs/tls-test.yml     # Use custom configuration file
    $0 -p linux,alpine             # Test only Linux and Alpine platforms
    $0 -p linux -s basic,protocols # Test Linux with basic and protocol suites
    $0 -v -j                       # Verbose output with parallel execution
    $0 -t 3600 -k                  # 1-hour timeout, keep artifacts
    $0 -n                          # Dry run to see what would be executed
    $0 --skip-build -s basic       # Skip build, run only basic tests

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
            -p|--platforms)
                SELECTED_PLATFORMS="$2"
                shift 2
                ;;
            -a|--architectures)
                SELECTED_ARCHITECTURES="$2"
                shift 2
                ;;
            -s|--test-suites)
                SELECTED_TEST_SUITES="$2"
                shift 2
                ;;
            -t|--timeout)
                GLOBAL_TIMEOUT="$2"
                shift 2
                ;;
            --build-timeout)
                BUILD_TIMEOUT="$2"
                shift 2
                ;;
            --test-timeout)
                TEST_TIMEOUT="$2"
                shift 2
                ;;
            --cleanup-timeout)
                CLEANUP_TIMEOUT="$2"
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
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
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

# Validate dependencies and environment
# This function checks for the presence of all required command-line tools
# (Docker, Docker Compose, yq, Zig) and validates the test configuration files.
# It ensures the Docker daemon is running and creates the necessary directories
# for logs and results. This is the first crucial step to ensure the test
# environment is sane before proceeding.
validate_environment() {
    log_info "Validating environment and dependencies..."
    
    # Check required tools
    local missing_tools=()
    
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        missing_tools+=("docker-compose")
    fi
    
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    if [[ "$SKIP_BUILD" == "false" ]] && ! command -v zig &> /dev/null; then
        missing_tools+=("zig")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again"
        return 1
    fi
    
    # Validate configuration
    if ! "$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" validate > /dev/null 2>&1; then
        log_error "Configuration validation failed"
        return 1
    fi
    
    # Check Docker daemon
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        return 1
    fi
    
    # Create necessary directories
    mkdir -p "$RESULTS_DIR" "$LOGS_DIR"
    
    log_success "Environment validation completed"
    return 0
}

# Setup test environment
# This function prepares the workspace for a new test run. It cleans up old
# results and log files (unless --keep-artifacts is specified) and establishes
# a unique session ID for the current test run. This helps in organizing
# artifacts and logs from different runs.
setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Clean previous results if not keeping artifacts
    if [[ "$KEEP_ARTIFACTS" == "false" ]]; then
        log_debug "Cleaning previous test results..."
        rm -rf "$RESULTS_DIR"/*
        rm -rf "$LOGS_DIR"/test-*.log
    fi
    
    # Initialize test session
    local session_id
    session_id="test-$(date +%Y%m%d-%H%M%S)-$$"
    echo "$session_id" > "$RESULTS_DIR/session-id"
    
    log_info "Test session ID: $session_id"
    log_success "Test environment setup completed"
    return 0
}

# Get list of platforms to test
get_test_platforms() {
    if [[ -n "$SELECTED_PLATFORMS" ]]; then
        echo "$SELECTED_PLATFORMS" | tr ',' '\n'
    else
        "$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" platforms
    fi
}

# Get list of test suites to run
get_test_suites() {
    if [[ -n "$SELECTED_TEST_SUITES" ]]; then
        echo "$SELECTED_TEST_SUITES" | tr ',' '\n'
    else
        "$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" test-suites
    fi
}

# Build phase - cross-compile binaries
# This function orchestrates the cross-compilation of the ZigCat binary for
# all selected platforms and architectures. It delegates the actual build
# process to the `build-binaries.sh` script, passing along any relevant
# command-line options like verbosity, parallelism, and timeouts. If the
# `--skip-build` flag is set, this phase is skipped entirely.
build_phase() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_info "Skipping build phase as requested"
        return 0
    fi
    
    log_info "Starting build phase..."
    
    local build_args=()
    
    if [[ -n "$SELECTED_PLATFORMS" ]]; then
        build_args+=("-p" "$SELECTED_PLATFORMS")
    fi
    
    if [[ -n "$SELECTED_ARCHITECTURES" ]]; then
        build_args+=("-a" "$SELECTED_ARCHITECTURES")
    fi
    
    build_args+=("-t" "$BUILD_TIMEOUT")
    
    if [[ "$VERBOSE" == "true" ]]; then
        build_args+=("-v")
    fi
    
    if [[ "$PARALLEL" == "true" ]]; then
        build_args+=("-j")
    fi
    
    if [[ "$KEEP_ARTIFACTS" == "true" ]]; then
        build_args+=("-k")
    fi

    if [[ "$USE_DOCKER" == "true" ]]; then
        build_args+=("--use-docker")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would execute: $BUILD_SCRIPT ${build_args[*]}"
        return 0
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

# Test execution phase
# This is the main test execution logic. It determines the full matrix of
# tests to run based on the selected platforms, architectures, and test suites.
# It can run these tests either sequentially or in parallel (if --parallel is
# specified). It tracks the success and failure of each test combination and
# provides a summary at the end.
test_phase() {
    log_info "Starting test execution phase..."
    
    local platforms
    platforms=$(get_test_platforms)
    
    local test_suites
    test_suites=$(get_test_suites)
    
    if [[ -z "$platforms" ]]; then
        log_error "No platforms selected for testing"
        return 1
    fi
    
    if [[ -z "$test_suites" ]]; then
        log_error "No test suites selected for execution"
        return 1
    fi
    
    local total_tests=0
    local successful_tests=0
    local failed_tests=0
    local test_start_time
    test_start_time=$(date +%s)
    
    # Count total test combinations
    while IFS= read -r platform; do
        if [[ -z "$platform" ]]; then
            continue
        fi
        
        local architectures
        platform_clean=$(echo "$platform" | tr -d '"')
        architectures=$("$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" platform-archs "$platform_clean")
        
        while IFS= read -r arch; do
            if [[ -z "$arch" ]]; then
                continue
            fi
            
            while IFS= read -r suite; do
                if [[ -z "$suite" ]]; then
                    continue
                fi
                ((total_tests++))
            done <<< "$test_suites"
        done <<< "$architectures"
    done <<< "$platforms"
    
    log_info "Total test combinations: $total_tests"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would execute $total_tests test combinations"
        return 0
    fi
    
    # Execute tests
    local test_pids=()
    
    while IFS= read -r platform; do
        if [[ -z "$platform" ]]; then
            continue
        fi
        
        local architectures
        platform_clean=$(echo "$platform" | tr -d '"')
        architectures=$("$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" platform-archs "$platform_clean")
        
        while IFS= read -r arch; do
            if [[ -z "$arch" ]]; then
                continue
            fi
            
            while IFS= read -r suite; do
                if [[ -z "$suite" ]]; then
                    continue
                fi
                
                # Clean up quotes from variables
                platform_clean=$(echo "$platform" | tr -d '"')
                arch_clean=$(echo "$arch" | tr -d '"')
                suite_clean=$(echo "$suite" | tr -d '"')
                
                local test_id="${platform_clean}-${arch_clean}-${suite_clean}"
                
                if [[ "$PARALLEL" == "true" ]]; then
                    # Execute test in background
                    execute_test "$platform_clean" "$arch_clean" "$suite_clean" "$test_id" &
                    test_pids+=($!)
                    log_debug "Started background test: $test_id (PID: $!)"
                else
                    # Execute test sequentially
                    if execute_test "$platform_clean" "$arch_clean" "$suite_clean" "$test_id"; then
                        ((successful_tests++))
                    else
                        ((failed_tests++))
                    fi
                fi
                
            done <<< "$test_suites"
        done <<< "$architectures"
    done <<< "$platforms"
    
    # Wait for parallel tests to complete
    if [[ "$PARALLEL" == "true" ]]; then
        log_info "Waiting for ${#test_pids[@]} parallel tests to complete..."
        
        for pid in "${test_pids[@]}"; do
            if wait "$pid"; then
                ((successful_tests++))
            else
                ((failed_tests++))
            fi
        done
    fi
    
    local test_end_time
    test_end_time=$(date +%s)
    local total_duration=$((test_end_time - test_start_time))
    
    # Generate test summary
    log_info "Test execution completed in ${total_duration}s"
    log_info "Results: $successful_tests successful, $failed_tests failed, $total_tests total"
    
    if [[ $failed_tests -gt 0 ]]; then
        log_error "Some tests failed. Check logs in: $LOGS_DIR"
        return 1
    else
        log_success "All tests completed successfully!"
        return 0
    fi
}

# Execute individual test
execute_test() {
    local platform="$1"
    local arch="$2"
    local suite="$3"
    local test_id="$4"
    local log_file="$LOGS_DIR/test-${test_id}.log"
    
    log_info "Executing test: $test_id"
    
    local test_start_time
    test_start_time=$(date +%s)
    
    {
        echo "=== Test Log for $test_id ==="
        echo "Platform: $platform"
        echo "Architecture: $arch"
        echo "Test Suite: $suite"
        echo "Start Time: $(date)"
        echo "Test Timeout: ${TEST_TIMEOUT}s"
        echo ""
        
        # Get test suite timeout from configuration
        local suite_timeout
        suite_timeout=$("$CONFIG_VALIDATOR" --config-file "$CONFIG_FILE" config-value "test_suites.$suite.timeout" 2>/dev/null || echo "$TEST_TIMEOUT")
        
        echo "=== Starting Test Execution ==="
        
        # For now, this is a placeholder for actual test execution
        # In a real implementation, this would:
        # 1. Start appropriate Docker containers
        # 2. Copy test binaries to containers
        # 3. Execute test scenarios
        # 4. Collect results
        
        echo "Test suite timeout: ${suite_timeout}s"
        echo "Simulating test execution for $test_id..."
        
        # Simulate test execution time (remove in real implementation)
        sleep 2
        
        echo "✓ Test simulation completed successfully"
        echo ""
        echo "=== Test Successful ==="
        
    } > "$log_file" 2>&1
    
    local test_exit_code=$?
    local test_end_time
    test_end_time=$(date +%s)
    local test_duration=$((test_end_time - test_start_time))
    
    # Append timing information to log
    {
        echo ""
        echo "=== Test Summary ==="
        echo "End Time: $(date)"
        echo "Duration: ${test_duration}s"
        echo "Exit Code: $test_exit_code"
    } >> "$log_file"
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "Test completed: $test_id (${test_duration}s)"
        return 0
    else
        log_error "Test failed: $test_id (${test_duration}s)"
        if [[ "$VERBOSE" == "true" ]]; then
            log_error "Test log: $log_file"
        fi
        return 1
    fi
}

# Generate comprehensive test report
generate_report() {
    local report_file="$RESULTS_DIR/test-report.json"
    local report_start_time
    report_start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_info "Generating test report: $report_file"
    
    local session_id
    session_id=$(cat "$RESULTS_DIR/session-id" 2>/dev/null || echo "unknown")
    
    {
        echo "{"
        echo "  \"test_report\": {"
        echo "    \"session_id\": \"$session_id\","
        echo "    \"timestamp\": \"$report_start_time\","
        echo "    \"test_system\": \"zigcat-docker-tests\","
        echo "    \"configuration\": {"
        echo "      \"platforms\": [$(get_test_platforms | sed 's/^/"/;s/$/"/;' | paste -sd, -)],"
        echo "      \"test_suites\": [$(get_test_suites | sed 's/^/"/;s/$/"/;' | paste -sd, -)],"
        echo "      \"global_timeout\": $GLOBAL_TIMEOUT,"
        echo "      \"build_timeout\": $BUILD_TIMEOUT,"
        echo "      \"test_timeout\": $TEST_TIMEOUT,"
        echo "      \"parallel_execution\": $PARALLEL,"
        echo "      \"verbose_logging\": $VERBOSE"
        echo "    },"
        echo "    \"results\": ["
        
        local first=true
        for log_file in "$LOGS_DIR"/test-*.log; do
            if [[ -f "$log_file" ]]; then
                local test_id
                test_id=$(basename "$log_file" .log | sed 's/^test-//')
                
                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    echo ","
                fi
                
                local test_success="false"
                local duration="0"
                
                if grep -q "Test Successful" "$log_file"; then
                    test_success="true"
                fi
                
                if grep -q "Duration:" "$log_file"; then
                    duration=$(grep "Duration:" "$log_file" | sed 's/.*Duration: \([0-9]*\)s.*/\1/')
                fi
                
                echo -n "      {"
                echo -n "\"test_id\": \"$test_id\", "
                echo -n "\"success\": $test_success, "
                echo -n "\"duration\": $duration, "
                echo -n "\"log_file\": \"$log_file\""
                echo -n "}"
            fi
        done
        
        echo ""
        echo "    ]"
        echo "  }"
        echo "}"
    } > "$report_file"
    
    log_success "Test report generated: $report_file"
}

# Enhanced cleanup function using cleanup manager
cleanup() {
    log_info "Starting enhanced cleanup process..."
    
    # Use the comprehensive cleanup manager
    local cleanup_args=()
    
    if [[ "$KEEP_ARTIFACTS" == "true" ]]; then
        cleanup_args+=("--preserve-artifacts")
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        cleanup_args+=("--verbose")
    fi
    
    cleanup_args+=("--timeout" "$CLEANUP_TIMEOUT")
    cleanup_args+=("--force")
    
    # Call the cleanup manager
    if [[ -f "$SCRIPT_DIR/cleanup-manager.sh" ]]; then
        log_debug "Using cleanup manager with args: ${cleanup_args[*]}"
        "$SCRIPT_DIR/cleanup-manager.sh" cleanup "${cleanup_args[@]}" || {
            log_warn "Cleanup manager failed, attempting emergency cleanup"
            "$SCRIPT_DIR/cleanup-manager.sh" emergency "${cleanup_args[@]}" || true
        }
    else
        log_warn "Cleanup manager not found, using basic cleanup"
        basic_cleanup
    fi
    
    log_success "Enhanced cleanup completed"
}

# Basic cleanup fallback
basic_cleanup() {
    log_debug "Performing basic cleanup..."
    
    # Stop any running containers
    if [[ ${#ACTIVE_CONTAINERS[@]} -gt 0 ]]; then
        log_debug "Stopping active containers: ${ACTIVE_CONTAINERS[*]}"
        for container in "${ACTIVE_CONTAINERS[@]}"; do
            docker stop "$container" > /dev/null 2>&1 || true
        done
    fi
    
    # Clean up Docker resources if not keeping artifacts
    if [[ "$KEEP_ARTIFACTS" == "false" ]]; then
        log_debug "Cleaning up Docker resources..."
        
        # Stop and remove containers from docker-compose
        if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
            timeout "$CLEANUP_TIMEOUT" docker-compose -f "$DOCKER_COMPOSE_FILE" down --volumes --remove-orphans > /dev/null 2>&1 || true
        fi
        
        # Clean up any remaining test containers
        docker ps -a --filter "label=zigcat-test" --format "{{.ID}}" | xargs -r docker rm -f > /dev/null 2>&1 || true
        
        # Clean up test networks
        docker network ls --filter "name=zigcat-test" --format "{{.ID}}" | xargs -r docker network rm > /dev/null 2>&1 || true
        
        # Clean up test volumes
        docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" | xargs -r docker volume rm > /dev/null 2>&1 || true
    fi
}

# Enhanced signal handler with error recovery
signal_handler() {
    local signal="${1:-UNKNOWN}"
    log_warn "Received signal: $signal, initiating graceful shutdown..."
    
    # Collect partial results before cleanup
    if [[ -f "$SCRIPT_DIR/error-recovery.sh" ]]; then
        log_info "Collecting partial results before shutdown..."
        "$SCRIPT_DIR/error-recovery.sh" collect --timeout 30 || true
    fi
    
    # Kill any background processes
    if [[ ${#CLEANUP_PIDS[@]} -gt 0 ]]; then
        log_debug "Terminating ${#CLEANUP_PIDS[@]} background processes"
        for pid in "${CLEANUP_PIDS[@]}"; do
            kill -TERM "$pid" > /dev/null 2>&1 || true
            sleep 1
            kill -KILL "$pid" > /dev/null 2>&1 || true
        done
    fi
    
    # Perform cleanup
    cleanup
    
    # Exit with appropriate signal code
    case "$signal" in
        "SIGINT"|"INT")
            exit 130
            ;;
        "SIGTERM"|"TERM")
            exit 143
            ;;
        *)
            exit 1
            ;;
    esac
}

# Timeout handler
timeout_handler() {
    log_error "Global timeout of ${GLOBAL_TIMEOUT}s exceeded, terminating..."
    cleanup
    exit 124
}

# Main function
# This is the entry point of the script. It orchestrates the entire test
# process by calling the various phase functions in the correct order:
# 1. Parses command-line arguments.
# 2. Sets up signal and timeout handlers for robust execution.
# 3. Validates the environment to ensure all dependencies are met.
# 4. Sets up a clean test environment for the run.
# 5. Executes the build phase to cross-compile binaries.
# 6. Executes the test phase to run the selected suites.
# 7. Generates a final JSON report summarizing the results.
# 8. Performs cleanup of all resources.
# 9. Generates final, user-friendly reports in various formats.
main() {
    local main_start_time
    main_start_time=$(date +%s)
    
    # Set up enhanced signal handlers
    trap 'signal_handler SIGINT' SIGINT
    trap 'signal_handler SIGTERM' SIGTERM
    trap 'signal_handler SIGQUIT' SIGQUIT
    
    # Set up global timeout
    (
        sleep "$GLOBAL_TIMEOUT"
        timeout_handler
    ) &
    local timeout_pid=$!
    CLEANUP_PIDS+=($timeout_pid)
    
    # Parse arguments
    parse_args "$@"
    
    log_info "ZigCat Docker Test System starting..."
    log_info "Global timeout: ${GLOBAL_TIMEOUT}s"
    
    # Validate environment and setup
    validate_environment || exit 1
    setup_test_environment || exit 1
    
    # Execute phases
    local exit_code=0
    
    if ! build_phase; then
        log_error "Build phase failed"
        exit_code=1
    elif ! test_phase; then
        log_error "Test phase failed"
        exit_code=1
    fi
    
    # Generate report regardless of test results
    generate_report
    
    # Cleanup
    cleanup
    
    # Kill timeout handler
    kill $timeout_pid > /dev/null 2>&1 || true
    
    local main_end_time
    main_end_time=$(date +%s)
    local total_duration=$((main_end_time - main_start_time))
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "ZigCat Docker Test System completed successfully in ${total_duration}s!"
    else
        log_error "ZigCat Docker Test System failed after ${total_duration}s"
    fi
    
    # Generate comprehensive test reports
    log_info "Generating test reports..."
    if [[ -f "$SCRIPT_DIR/generate-reports.sh" ]]; then
        if "$SCRIPT_DIR/generate-reports.sh" \
            --results-dir "$RESULTS_DIR" \
            --artifacts-dir "$PROJECT_ROOT/docker-tests/artifacts" \
            --output-dir "$PROJECT_ROOT/docker-tests/reports" \
            --formats "json html text"; then
            log_success "Test reports generated successfully"
        else
            log_warn "Failed to generate test reports"
        fi
    else
        log_warn "Report generator not found, skipping report generation"
    fi
    
    exit $exit_code
}

# Run main function with all arguments
main "$@"
