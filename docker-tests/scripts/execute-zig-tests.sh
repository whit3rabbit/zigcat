#!/bin/bash

# ZigCat Test Execution Script
# Executes existing Zig test suite in containerized environments
# Supports platform-specific test execution and result collection

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_PLATFORM="${TEST_PLATFORM:-linux}"
TEST_ARCH="${TEST_ARCH:-amd64}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
VERBOSE="${VERBOSE:-false}"

# Paths
ARTIFACTS_DIR="/artifacts"
RESULTS_DIR="/test-results"
LOGS_DIR="/test-logs"
ZIG_BINARY="${ARTIFACTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/zigcat"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

# Test result tracking
declare -A test_results
declare -A test_durations
declare -A test_outputs
total_tests=0
passed_tests=0
failed_tests=0
skipped_tests=0

# Initialize test environment
init_test_environment() {
    log_info "Initializing test environment for ${TEST_PLATFORM}-${TEST_ARCH}"
    
    # Create result directories
    mkdir -p "${RESULTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}"
    mkdir -p "${LOGS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}"
    
    # Verify binary exists
    if [[ ! -f "${ZIG_BINARY}" ]]; then
        log_error "ZigCat binary not found: ${ZIG_BINARY}"
        return 1
    fi
    
    # Make binary executable
    chmod +x "${ZIG_BINARY}"
    
    # Test basic functionality
    log_info "Testing binary functionality..."
    if ! timeout 10 "${ZIG_BINARY}" --help >/dev/null 2>&1; then
        log_error "Binary failed basic functionality test"
        return 1
    fi
    
    log_success "Test environment initialized successfully"
}

# Execute a single Zig test file
execute_zig_test() {
    local test_file="$1"
    local test_name="$(basename "${test_file}" .zig)"
    local start_time
    local end_time
    local duration
    local exit_code
    local output_file="${LOGS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/${test_name}.log"
    
    log_info "Running test: ${test_name}"
    
    start_time=$(date +%s.%N)
    
    # Execute the test with timeout
    set +e
    if [[ "${VERBOSE}" == "true" ]]; then
        timeout "${TEST_TIMEOUT}" zig test "${PROJECT_ROOT}/tests/${test_file}" \
            --main-pkg-path "${PROJECT_ROOT}" \
            2>&1 | tee "${output_file}"
        exit_code=${PIPESTATUS[0]}
    else
        timeout "${TEST_TIMEOUT}" zig test "${PROJECT_ROOT}/tests/${test_file}" \
            --main-pkg-path "${PROJECT_ROOT}" \
            >"${output_file}" 2>&1
        exit_code=$?
    fi
    set -e
    
    end_time=$(date +%s.%N)
    duration=$(echo "${end_time} - ${start_time}" | bc -l)
    
    # Store results
    test_results["${test_name}"]=${exit_code}
    test_durations["${test_name}"]=${duration}
    test_outputs["${test_name}"]="${output_file}"
    
    ((total_tests++))
    
    if [[ ${exit_code} -eq 0 ]]; then
        ((passed_tests++))
        log_success "Test ${test_name} passed (${duration}s)"
    elif [[ ${exit_code} -eq 124 ]]; then
        log_warn "Test ${test_name} timed out after ${TEST_TIMEOUT}s"
        ((failed_tests++))
    else
        log_error "Test ${test_name} failed with exit code ${exit_code}"
        ((failed_tests++))
        
        # Show last few lines of output for failed tests
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "Last 10 lines of output:"
            tail -n 10 "${output_file}" || true
        fi
    fi
}

# Execute integration tests that require the binary
execute_integration_test() {
    local test_name="$1"
    local start_time
    local end_time
    local duration
    local exit_code
    local output_file="${LOGS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/${test_name}.log"
    
    log_info "Running integration test: ${test_name}"
    
    start_time=$(date +%s.%N)
    
    case "${test_name}" in
        "binary-functionality")
            execute_binary_functionality_test "${output_file}"
            exit_code=$?
            ;;
        "server-client-basic")
            execute_server_client_test "${output_file}"
            exit_code=$?
            ;;
        "tcp-echo")
            execute_tcp_echo_test "${output_file}"
            exit_code=$?
            ;;
        "udp-echo")
            execute_udp_echo_test "${output_file}"
            exit_code=$?
            ;;
        *)
            log_warn "Unknown integration test: ${test_name}"
            exit_code=2
            ;;
    esac
    
    end_time=$(date +%s.%N)
    duration=$(echo "${end_time} - ${start_time}" | bc -l)
    
    # Store results
    test_results["${test_name}"]=${exit_code}
    test_durations["${test_name}"]=${duration}
    test_outputs["${test_name}"]="${output_file}"
    
    ((total_tests++))
    
    if [[ ${exit_code} -eq 0 ]]; then
        ((passed_tests++))
        log_success "Integration test ${test_name} passed (${duration}s)"
    elif [[ ${exit_code} -eq 2 ]]; then
        ((skipped_tests++))
        log_warn "Integration test ${test_name} skipped"
    else
        log_error "Integration test ${test_name} failed with exit code ${exit_code}"
        ((failed_tests++))
    fi
}

# Binary functionality test
execute_binary_functionality_test() {
    local output_file="$1"
    
    {
        echo "=== Binary Functionality Test ==="
        echo "Platform: ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "Binary: ${ZIG_BINARY}"
        echo
        
        # Test help output
        echo "Testing --help flag..."
        if timeout 10 "${ZIG_BINARY}" --help; then
            echo "✓ Help output successful"
        else
            echo "✗ Help output failed"
            return 1
        fi
        
        echo
        
        # Test version output
        echo "Testing --version flag..."
        if timeout 10 "${ZIG_BINARY}" --version; then
            echo "✓ Version output successful"
        else
            echo "✗ Version output failed"
            return 1
        fi
        
        echo
        
        # Test invalid arguments
        echo "Testing invalid arguments..."
        if timeout 10 "${ZIG_BINARY}" --invalid-flag 2>/dev/null; then
            echo "✗ Should have failed with invalid flag"
            return 1
        else
            echo "✓ Correctly rejected invalid flag"
        fi
        
        echo "✓ All binary functionality tests passed"
        
    } >"${output_file}" 2>&1
    
    return 0
}

# Server-client basic test
execute_server_client_test() {
    local output_file="$1"
    local server_port=12345
    local test_message="Hello ZigCat Test"
    
    {
        echo "=== Server-Client Basic Test ==="
        echo "Platform: ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "Port: ${server_port}"
        echo
        
        # Start server in background
        echo "Starting server on port ${server_port}..."
        timeout 30 "${ZIG_BINARY}" -l -p "${server_port}" &
        local server_pid=$!
        
        # Wait for server to start
        sleep 2
        
        # Test client connection
        echo "Testing client connection..."
        if echo "${test_message}" | timeout 10 "${ZIG_BINARY}" localhost "${server_port}"; then
            echo "✓ Client connection successful"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 0
        else
            echo "✗ Client connection failed"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 1
        fi
        
    } >"${output_file}" 2>&1
}

# TCP echo test
execute_tcp_echo_test() {
    local output_file="$1"
    local server_port=12346
    local test_data="TCP Echo Test Data"
    
    {
        echo "=== TCP Echo Test ==="
        echo "Platform: ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "Port: ${server_port}"
        echo
        
        # Start echo server
        echo "Starting TCP echo server..."
        echo "${test_data}" | timeout 30 "${ZIG_BINARY}" -l -p "${server_port}" &
        local server_pid=$!
        
        sleep 2
        
        # Connect and test echo
        echo "Testing TCP echo..."
        local result
        result=$(echo "${test_data}" | timeout 10 "${ZIG_BINARY}" localhost "${server_port}")
        
        if [[ "${result}" == "${test_data}" ]]; then
            echo "✓ TCP echo successful"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 0
        else
            echo "✗ TCP echo failed. Expected: '${test_data}', Got: '${result}'"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 1
        fi
        
    } >"${output_file}" 2>&1
}

# UDP echo test
execute_udp_echo_test() {
    local output_file="$1"
    local server_port=12347
    local test_data="UDP Echo Test Data"
    
    {
        echo "=== UDP Echo Test ==="
        echo "Platform: ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "Port: ${server_port}"
        echo
        
        # Check if UDP is supported on this platform
        if [[ "${TEST_PLATFORM}" == "freebsd" ]]; then
            echo "⚠ UDP tests may be limited on FreeBSD in container"
        fi
        
        # Start UDP echo server
        echo "Starting UDP echo server..."
        echo "${test_data}" | timeout 30 "${ZIG_BINARY}" -l -u -p "${server_port}" &
        local server_pid=$!
        
        sleep 2
        
        # Connect and test echo
        echo "Testing UDP echo..."
        local result
        result=$(echo "${test_data}" | timeout 10 "${ZIG_BINARY}" -u localhost "${server_port}")
        
        if [[ "${result}" == "${test_data}" ]]; then
            echo "✓ UDP echo successful"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 0
        else
            echo "✗ UDP echo failed. Expected: '${test_data}', Got: '${result}'"
            kill "${server_pid}" 2>/dev/null || true
            wait "${server_pid}" 2>/dev/null || true
            return 1
        fi
        
    } >"${output_file}" 2>&1
}

# Check if test should be skipped for this platform
should_skip_test() {
    local test_name="$1"
    
    case "${TEST_PLATFORM}" in
        "freebsd")
            # Skip tests that may not work well in FreeBSD containers
            case "${test_name}" in
                "exec_safety_test"|"platform_test")
                    return 0  # Skip
                    ;;
            esac
            ;;
        "alpine")
            # Alpine-specific skips
            case "${test_name}" in
                "tls_test")
                    # May need different TLS setup
                    return 0  # Skip for now
                    ;;
            esac
            ;;
    esac
    
    return 1  # Don't skip
}

# Generate test report
generate_test_report() {
    local report_file="${RESULTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/test-report.json"
    local summary_file="${RESULTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/test-summary.txt"
    
    log_info "Generating test report..."
    
    # JSON report
    {
        echo "{"
        echo "  \"platform\": \"${TEST_PLATFORM}\","
        echo "  \"architecture\": \"${TEST_ARCH}\","
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"summary\": {"
        echo "    \"total\": ${total_tests},"
        echo "    \"passed\": ${passed_tests},"
        echo "    \"failed\": ${failed_tests},"
        echo "    \"skipped\": ${skipped_tests}"
        echo "  },"
        echo "  \"tests\": ["
        
        local first=true
        for test_name in "${!test_results[@]}"; do
            if [[ "${first}" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            
            local status="failed"
            case "${test_results[${test_name}]}" in
                0) status="passed" ;;
                2) status="skipped" ;;
                *) status="failed" ;;
            esac
            
            echo -n "    {"
            echo -n "\"name\": \"${test_name}\", "
            echo -n "\"status\": \"${status}\", "
            echo -n "\"duration\": ${test_durations[${test_name}]}, "
            echo -n "\"exit_code\": ${test_results[${test_name}]}, "
            echo -n "\"log_file\": \"${test_outputs[${test_name}]}\""
            echo -n "}"
        done
        
        echo
        echo "  ]"
        echo "}"
    } > "${report_file}"
    
    # Human-readable summary
    {
        echo "ZigCat Test Results - ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "=================================================="
        echo "Timestamp: $(date)"
        echo "Platform: ${TEST_PLATFORM}"
        echo "Architecture: ${TEST_ARCH}"
        echo
        echo "Summary:"
        echo "  Total tests: ${total_tests}"
        echo "  Passed: ${passed_tests}"
        echo "  Failed: ${failed_tests}"
        echo "  Skipped: ${skipped_tests}"
        echo
        
        if [[ ${failed_tests} -gt 0 ]]; then
            echo "Failed tests:"
            for test_name in "${!test_results[@]}"; do
                if [[ "${test_results[${test_name}]}" -ne 0 && "${test_results[${test_name}]}" -ne 2 ]]; then
                    echo "  - ${test_name} (exit code: ${test_results[${test_name}]})"
                fi
            done
            echo
        fi
        
        if [[ ${skipped_tests} -gt 0 ]]; then
            echo "Skipped tests:"
            for test_name in "${!test_results[@]}"; do
                if [[ "${test_results[${test_name}]}" -eq 2 ]]; then
                    echo "  - ${test_name}"
                fi
            done
            echo
        fi
        
        echo "Detailed logs available in: ${LOGS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/"
        
    } > "${summary_file}"
    
    log_success "Test report generated: ${report_file}"
    log_success "Test summary generated: ${summary_file}"
}

# Main execution function
main() {
    log_info "Starting ZigCat test execution for ${TEST_PLATFORM}-${TEST_ARCH}"
    
    # Initialize environment
    if ! init_test_environment; then
        log_error "Failed to initialize test environment"
        exit 1
    fi
    
    # List of Zig test files to execute
    local zig_tests=(
        "cli_test.zig"
        "net_test.zig"
        "security_test.zig"
        "proxy_test.zig"
        "tls_test.zig"
        "transfer_test.zig"
        "integration_test.zig"
        "platform_test.zig"
        "exec_safety_test.zig"
    )
    
    # Execute Zig unit tests
    log_info "Executing Zig unit tests..."
    for test_file in "${zig_tests[@]}"; do
        local test_name="$(basename "${test_file}" .zig)"
        
        if should_skip_test "${test_name}"; then
            log_warn "Skipping test ${test_name} for platform ${TEST_PLATFORM}"
            test_results["${test_name}"]=2
            test_durations["${test_name}"]=0
            test_outputs["${test_name}"]=""
            ((total_tests++))
            ((skipped_tests++))
            continue
        fi
        
        if [[ -f "${PROJECT_ROOT}/tests/${test_file}" ]]; then
            execute_zig_test "${test_file}"
        else
            log_warn "Test file not found: ${test_file}"
        fi
    done
    
    # Execute integration tests
    log_info "Executing integration tests..."
    local integration_tests=(
        "binary-functionality"
        "server-client-basic"
        "tcp-echo"
        "udp-echo"
    )
    
    for test_name in "${integration_tests[@]}"; do
        execute_integration_test "${test_name}"
    done
    
    # Generate report
    generate_test_report
    
    # Print summary
    echo
    log_info "Test execution completed for ${TEST_PLATFORM}-${TEST_ARCH}"
    log_info "Total: ${total_tests}, Passed: ${passed_tests}, Failed: ${failed_tests}, Skipped: ${skipped_tests}"
    
    # Exit with appropriate code
    if [[ ${failed_tests} -gt 0 ]]; then
        log_error "Some tests failed"
        exit 1
    else
        log_success "All tests passed or skipped"
        exit 0
    fi
}

# Handle script arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            TEST_PLATFORM="$2"
            shift 2
            ;;
        --arch)
            TEST_ARCH="$2"
            shift 2
            ;;
        --timeout)
            TEST_TIMEOUT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --platform PLATFORM    Test platform (linux, alpine, freebsd)"
            echo "  --arch ARCH            Architecture (amd64, arm64)"
            echo "  --timeout SECONDS      Test timeout (default: 300)"
            echo "  --verbose              Enable verbose output"
            echo "  --help                 Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"