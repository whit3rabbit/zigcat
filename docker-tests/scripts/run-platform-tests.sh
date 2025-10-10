#!/bin/bash

# ZigCat Platform Test Runner
# Main entry point for running tests on a specific platform
# Integrates Zig test execution, result collection, and reporting

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-/project-root}"
TEST_PLATFORM="${TEST_PLATFORM:-linux}"
TEST_ARCH="${TEST_ARCH:-amd64}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
VERBOSE="${VERBOSE:-false}"

# Paths
ARTIFACTS_DIR="/artifacts"
RESULTS_DIR="/test-results"
LOGS_DIR="/test-logs"
PLATFORM_RESULTS_DIR="${RESULTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}"
PLATFORM_LOGS_DIR="${LOGS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}"

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

# Initialize test environment
init_test_environment() {
    log_info "Initializing test environment for ${TEST_PLATFORM}-${TEST_ARCH}"
    
    # Create result directories
    mkdir -p "${PLATFORM_RESULTS_DIR}"
    mkdir -p "${PLATFORM_LOGS_DIR}"
    
    # Set up network environment
    if [[ -x "${SCRIPT_DIR}/setup-test-network.sh" ]]; then
        "${SCRIPT_DIR}/setup-test-network.sh" setup
    fi
    
    # Verify project structure
    if [[ ! -d "${PROJECT_ROOT}" ]]; then
        log_error "Project root not found: ${PROJECT_ROOT}"
        return 1
    fi
    
    if [[ ! -d "${PROJECT_ROOT}/tests" ]]; then
        log_error "Tests directory not found: ${PROJECT_ROOT}/tests"
        return 1
    fi
    
    log_success "Test environment initialized"
}

# Execute Zig unit tests
execute_zig_unit_tests() {
    log_info "Executing Zig unit tests..."
    
    local test_files=(
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
    
    local passed=0
    local failed=0
    local skipped=0
    
    for test_file in "${test_files[@]}"; do
        local test_name="$(basename "${test_file}" .zig)"
        local log_file="${PLATFORM_LOGS_DIR}/${test_name}.log"
        
        # Check if test should be skipped for this platform
        if should_skip_test "${test_name}"; then
            log_warn "Skipping ${test_name} for platform ${TEST_PLATFORM}"
            echo "Test skipped for platform ${TEST_PLATFORM}" > "${log_file}"
            ((skipped++))
            continue
        fi
        
        if [[ ! -f "${PROJECT_ROOT}/tests/${test_file}" ]]; then
            log_warn "Test file not found: ${test_file}"
            echo "Test file not found" > "${log_file}"
            ((skipped++))
            continue
        fi
        
        log_info "Running ${test_name}..."
        
        local start_time=$(date +%s.%N)
        local exit_code=0
        
        # Execute the test
        set +e
        timeout "${TEST_TIMEOUT}" zig test "${PROJECT_ROOT}/tests/${test_file}" \
            --main-pkg-path "${PROJECT_ROOT}" \
            >"${log_file}" 2>&1
        exit_code=$?
        set -e
        
        local end_time=$(date +%s.%N)
        local duration=$(echo "${end_time} - ${start_time}" | bc -l)
        
        if [[ ${exit_code} -eq 0 ]]; then
            log_success "${test_name} passed (${duration}s)"
            ((passed++))
        elif [[ ${exit_code} -eq 124 ]]; then
            log_error "${test_name} timed out after ${TEST_TIMEOUT}s"
            echo "Test timed out after ${TEST_TIMEOUT}s" >> "${log_file}"
            ((failed++))
        else
            log_error "${test_name} failed with exit code ${exit_code}"
            ((failed++))
        fi
    done
    
    log_info "Zig unit tests completed: ${passed} passed, ${failed} failed, ${skipped} skipped"
    return $([[ ${failed} -eq 0 ]] && echo 0 || echo 1)
}

# Execute integration tests
execute_integration_tests() {
    log_info "Executing integration tests..."
    
    # Check if binary exists
    local binary_path="${ARTIFACTS_DIR}/${TEST_PLATFORM}-${TEST_ARCH}/zigcat"
    if [[ ! -f "${binary_path}" ]]; then
        log_error "ZigCat binary not found: ${binary_path}"
        return 1
    fi
    
    # Make binary executable
    chmod +x "${binary_path}"
    
    # Copy binary to PATH for easier access
    cp "${binary_path}" /usr/local/bin/zigcat
    
    local integration_tests=(
        "binary-functionality"
        "server-client-basic"
        "tcp-echo"
        "udp-echo"
    )
    
    local passed=0
    local failed=0
    
    for test_name in "${integration_tests[@]}"; do
        local log_file="${PLATFORM_LOGS_DIR}/${test_name}.log"
        
        log_info "Running integration test: ${test_name}"
        
        local start_time=$(date +%s.%N)
        local exit_code=0
        
        # Execute the integration test
        set +e
        case "${test_name}" in
            "binary-functionality")
                execute_binary_functionality_test "${log_file}"
                exit_code=$?
                ;;
            "server-client-basic")
                execute_server_client_test "${log_file}"
                exit_code=$?
                ;;
            "tcp-echo")
                execute_tcp_echo_test "${log_file}"
                exit_code=$?
                ;;
            "udp-echo")
                execute_udp_echo_test "${log_file}"
                exit_code=$?
                ;;
        esac
        set -e
        
        local end_time=$(date +%s.%N)
        local duration=$(echo "${end_time} - ${start_time}" | bc -l)
        
        if [[ ${exit_code} -eq 0 ]]; then
            log_success "Integration test ${test_name} passed (${duration}s)"
            ((passed++))
        else
            log_error "Integration test ${test_name} failed with exit code ${exit_code}"
            ((failed++))
        fi
    done
    
    log_info "Integration tests completed: ${passed} passed, ${failed} failed"
    return $([[ ${failed} -eq 0 ]] && echo 0 || echo 1)
}

# Binary functionality test
execute_binary_functionality_test() {
    local output_file="$1"
    
    {
        echo "=== Binary Functionality Test ==="
        echo "Platform: ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "Binary: /usr/local/bin/zigcat"
        echo "Timestamp: $(date)"
        echo
        
        # Test help output
        echo "Testing --help flag..."
        if timeout 10 zigcat --help; then
            echo "✓ Help output successful"
        else
            echo "✗ Help output failed"
            return 1
        fi
        
        echo
        
        # Test version output
        echo "Testing --version flag..."
        if timeout 10 zigcat --version; then
            echo "✓ Version output successful"
        else
            echo "✗ Version output failed"
            return 1
        fi
        
        echo
        
        # Test invalid arguments
        echo "Testing invalid arguments..."
        if timeout 10 zigcat --invalid-flag 2>/dev/null; then
            echo "✗ Should have failed with invalid flag"
            return 1
        else
            echo "✓ Correctly rejected invalid flag"
        fi
        
        echo
        echo "✅ All binary functionality tests passed"
        
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
        echo "Timestamp: $(date)"
        echo
        
        # Start server in background
        echo "Starting server on port ${server_port}..."
        timeout 30 zigcat -l -p "${server_port}" &
        local server_pid=$!
        
        # Wait for server to start
        sleep 2
        
        # Test client connection
        echo "Testing client connection..."
        if echo "${test_message}" | timeout 10 zigcat localhost "${server_port}"; then
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
        echo "Timestamp: $(date)"
        echo
        
        # Start echo server
        echo "Starting TCP echo server..."
        echo "${test_data}" | timeout 30 zigcat -l -p "${server_port}" &
        local server_pid=$!
        
        sleep 2
        
        # Connect and test echo
        echo "Testing TCP echo..."
        local result
        result=$(echo "${test_data}" | timeout 10 zigcat localhost "${server_port}")
        
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
        echo "Timestamp: $(date)"
        echo
        
        # Check if UDP is supported on this platform
        if [[ "${TEST_PLATFORM}" == "freebsd" ]]; then
            echo "⚠ UDP tests may be limited on FreeBSD in container"
        fi
        
        # Start UDP echo server
        echo "Starting UDP echo server..."
        echo "${test_data}" | timeout 30 zigcat -l -u -p "${server_port}" &
        local server_pid=$!
        
        sleep 2
        
        # Connect and test echo
        echo "Testing UDP echo..."
        local result
        result=$(echo "${test_data}" | timeout 10 zigcat -u localhost "${server_port}")
        
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

# Generate test reports
generate_test_reports() {
    log_info "Generating test reports..."
    
    # Use Python parser if available
    if command -v python3 >/dev/null 2>&1 && [[ -x "${SCRIPT_DIR}/parse-zig-test-output.py" ]]; then
        local json_report="${PLATFORM_RESULTS_DIR}/test-report.json"
        local junit_report="${PLATFORM_RESULTS_DIR}/junit-report.xml"
        
        python3 "${SCRIPT_DIR}/parse-zig-test-output.py" \
            "${PLATFORM_LOGS_DIR}" \
            --platform "${TEST_PLATFORM}" \
            --architecture "${TEST_ARCH}" \
            --output "${json_report}" \
            --junit "${junit_report}" \
            --verbose
        
        log_success "Structured reports generated"
    else
        log_warn "Python parser not available, generating basic report"
        generate_basic_report
    fi
}

# Generate basic test report
generate_basic_report() {
    local summary_file="${PLATFORM_RESULTS_DIR}/test-summary.txt"
    
    {
        echo "ZigCat Test Results - ${TEST_PLATFORM}-${TEST_ARCH}"
        echo "=================================================="
        echo "Timestamp: $(date)"
        echo "Platform: ${TEST_PLATFORM}"
        echo "Architecture: ${TEST_ARCH}"
        echo
        echo "Test logs available in: ${PLATFORM_LOGS_DIR}/"
        echo
        
        # Count test results
        local total_logs=$(find "${PLATFORM_LOGS_DIR}" -name "*.log" | wc -l)
        echo "Total test files: ${total_logs}"
        
        # Check for failures
        local failed_tests=()
        for log_file in "${PLATFORM_LOGS_DIR}"/*.log; do
            if [[ -f "${log_file}" ]]; then
                local test_name=$(basename "${log_file}" .log)
                if grep -q "✗\|FAILED\|ERROR\|failed with exit code" "${log_file}"; then
                    failed_tests+=("${test_name}")
                fi
            fi
        done
        
        if [[ ${#failed_tests[@]} -gt 0 ]]; then
            echo "Failed tests:"
            for test in "${failed_tests[@]}"; do
                echo "  - ${test}"
            done
        else
            echo "All tests completed successfully"
        fi
        
    } > "${summary_file}"
    
    log_success "Basic report generated: ${summary_file}"
}

# Main execution function
main() {
    log_info "Starting ZigCat platform tests for ${TEST_PLATFORM}-${TEST_ARCH}"
    
    # Initialize environment
    if ! init_test_environment; then
        log_error "Failed to initialize test environment"
        exit 1
    fi
    
    local overall_exit_code=0
    
    # Execute Zig unit tests
    if ! execute_zig_unit_tests; then
        log_error "Zig unit tests failed"
        overall_exit_code=1
    fi
    
    # Execute integration tests
    if ! execute_integration_tests; then
        log_error "Integration tests failed"
        overall_exit_code=1
    fi
    
    # Generate reports
    generate_test_reports
    
    # Print summary
    echo
    log_info "Platform test execution completed for ${TEST_PLATFORM}-${TEST_ARCH}"
    
    if [[ ${overall_exit_code} -eq 0 ]]; then
        log_success "All tests passed"
    else
        log_error "Some tests failed"
    fi
    
    exit ${overall_exit_code}
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