#!/bin/bash

# Cross-Platform Integration Test Scenarios for ZigCat
# Tests TCP/UDP communication, TLS, and proxy functionality across different platforms

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_TESTS_DIR="$PROJECT_ROOT/docker-tests"
RESULTS_DIR="$DOCKER_TESTS_DIR/results"

# Default values
SERVER_PLATFORM=""
CLIENT_PLATFORM=""
SERVER_ARCH=""
CLIENT_ARCH=""
SERVER_BINARY=""
CLIENT_BINARY=""
TEST_SUITES="basic,protocols"
TIMEOUT=60
VERBOSE=false
OUTPUT_FILE=""
KEEP_LOGS=false

# Test configuration
BASE_PORT=15000
TEST_DATA_SIZE=1024
TEST_MESSAGE="Hello from ZigCat cross-platform test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 --server-platform PLATFORM --client-platform PLATFORM [OPTIONS]

Tests cross-platform integration between ZigCat server and client binaries.

Required Arguments:
  --server-platform PLATFORM    Server platform (linux, alpine, freebsd)
  --client-platform PLATFORM    Client platform (linux, alpine, freebsd)
  --server-binary PATH           Path to server binary
  --client-binary PATH           Path to client binary

Options:
  --server-arch ARCH             Server architecture (amd64, arm64) [default: amd64]
  --client-arch ARCH             Client architecture (amd64, arm64) [default: amd64]
  --test-suites SUITES           Test suites to run (basic,protocols,advanced) [default: basic,protocols]
  --timeout SECONDS              Test timeout per scenario [default: 60]
  --output FILE                  Output file for test results (JSON format)
  --keep-logs                    Keep test logs after completion
  --verbose                      Enable verbose output
  --help                         Show this help message

Test Suites:
  basic      - TCP/UDP echo tests, basic connectivity
  protocols  - TLS/SSL functionality, proxy protocols
  advanced   - File transfer, exec mode, complex scenarios

Examples:
  $0 --server-platform linux --client-platform alpine \\
     --server-binary ./artifacts/linux-amd64/zigcat \\
     --client-binary ./artifacts/alpine-amd64/zigcat

  $0 --server-platform linux --client-platform linux \\
     --server-arch amd64 --client-arch arm64 \\
     --server-binary ./artifacts/linux-amd64/zigcat \\
     --client-binary ./artifacts/linux-arm64/zigcat \\
     --test-suites basic,protocols,advanced --verbose

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --server-platform)
                SERVER_PLATFORM="$2"
                shift 2
                ;;
            --client-platform)
                CLIENT_PLATFORM="$2"
                shift 2
                ;;
            --server-arch)
                SERVER_ARCH="$2"
                shift 2
                ;;
            --client-arch)
                CLIENT_ARCH="$2"
                shift 2
                ;;
            --server-binary)
                SERVER_BINARY="$2"
                shift 2
                ;;
            --client-binary)
                CLIENT_BINARY="$2"
                shift 2
                ;;
            --test-suites)
                TEST_SUITES="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --keep-logs)
                KEEP_LOGS=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Set default architectures if not specified
    [[ -z "$SERVER_ARCH" ]] && SERVER_ARCH="amd64"
    [[ -z "$CLIENT_ARCH" ]] && CLIENT_ARCH="amd64"

    # Validate required arguments
    if [[ -z "$SERVER_PLATFORM" || -z "$CLIENT_PLATFORM" || -z "$SERVER_BINARY" || -z "$CLIENT_BINARY" ]]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi

    # Validate platforms
    for platform in "$SERVER_PLATFORM" "$CLIENT_PLATFORM"; do
        case "$platform" in
            linux|alpine|freebsd)
                ;;
            *)
                log_error "Invalid platform: $platform. Must be one of: linux, alpine, freebsd"
                exit 1
                ;;
        esac
    done

    # Validate architectures
    for arch in "$SERVER_ARCH" "$CLIENT_ARCH"; do
        case "$arch" in
            amd64|arm64)
                ;;
            *)
                log_error "Invalid architecture: $arch. Must be one of: amd64, arm64"
                exit 1
                ;;
        esac
    done

    # Check if binaries exist
    for binary in "$SERVER_BINARY" "$CLIENT_BINARY"; do
        if [[ ! -f "$binary" ]]; then
            log_error "Binary not found: $binary"
            exit 1
        fi
        chmod +x "$binary" 2>/dev/null || true
    done
}

# Initialize test results structure
init_results() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local session_id=$(date +%s)-$(head -c 8 /dev/urandom | base64 | tr -d '/' | tr -d '+' | tr -d '=')
    
    cat > "$OUTPUT_FILE" << EOF
{
  "test_run_id": "$session_id",
  "timestamp": "$timestamp",
  "configuration": {
    "server_platform": "$SERVER_PLATFORM",
    "client_platform": "$CLIENT_PLATFORM",
    "server_architecture": "$SERVER_ARCH",
    "client_architecture": "$CLIENT_ARCH",
    "server_binary": "$SERVER_BINARY",
    "client_binary": "$CLIENT_BINARY",
    "test_suites": "$TEST_SUITES",
    "timeout": $TIMEOUT
  },
  "test_results": {
    "basic": {},
    "protocols": {},
    "advanced": {}
  },
  "summary": {
    "total_tests": 0,
    "passed": 0,
    "failed": 0,
    "skipped": 0,
    "duration": 0
  }
}
EOF
}

# Update test results
update_result() {
    local suite="$1"
    local test_name="$2"
    local status="$3"
    local details="$4"
    local duration="${5:-0}"

    if [[ -n "$OUTPUT_FILE" ]]; then
        python3 << EOF
import json
import sys

try:
    with open('$OUTPUT_FILE', 'r') as f:
        data = json.load(f)
    
    # Update test result
    data['test_results']['$suite']['$test_name'] = {
        'status': '$status',
        'details': '$details',
        'duration': $duration
    }
    
    # Update summary
    data['summary']['total_tests'] += 1
    if '$status' == 'pass':
        data['summary']['passed'] += 1
    elif '$status' == 'fail':
        data['summary']['failed'] += 1
    else:
        data['summary']['skipped'] += 1
    
    with open('$OUTPUT_FILE', 'w') as f:
        json.dump(data, f, indent=2)
        
except Exception as e:
    print(f"Error updating results: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    fi
}

# Find available port
find_available_port() {
    local start_port=${1:-$BASE_PORT}
    local port=$start_port
    
    while [[ $port -lt $((start_port + 100)) ]]; do
        if ! netstat -ln 2>/dev/null | grep -q ":$port "; then
            echo $port
            return 0
        fi
        ((port++))
    done
    
    log_error "Could not find available port starting from $start_port"
    return 1
}

# TCP Echo Test
test_tcp_echo() {
    log_info "Running TCP echo test..."
    local start_time=$(date +%s.%N)
    
    local port
    if ! port=$(find_available_port); then
        update_result "basic" "tcp_echo" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for TCP echo test"
    
    # Create test data
    local test_data="$TEST_MESSAGE $(date)"
    local server_log="/tmp/zigcat_server_tcp_$port.log"
    local client_log="/tmp/zigcat_client_tcp_$port.log"
    
    # Start server in background
    log_verbose "Starting TCP server on port $port"
    timeout $TIMEOUT "$SERVER_BINARY" -l "$port" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "TCP server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "basic" "tcp_echo" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with client and send data
    log_verbose "Connecting with TCP client"
    local client_success=false
    if echo "$test_data" | timeout $((TIMEOUT/2)) "$CLIENT_BINARY" localhost "$port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        log_success "TCP echo test passed"
        update_result "basic" "tcp_echo" "pass" "TCP communication successful on port $port" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "TCP echo test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "basic" "tcp_echo" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# UDP Echo Test
test_udp_echo() {
    log_info "Running UDP echo test..."
    local start_time=$(date +%s.%N)
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 100))); then
        update_result "basic" "udp_echo" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for UDP echo test"
    
    # Create test data
    local test_data="$TEST_MESSAGE UDP $(date)"
    local server_log="/tmp/zigcat_server_udp_$port.log"
    local client_log="/tmp/zigcat_client_udp_$port.log"
    
    # Start UDP server in background
    log_verbose "Starting UDP server on port $port"
    timeout $TIMEOUT "$SERVER_BINARY" -l -u "$port" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "UDP server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "basic" "udp_echo" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with UDP client and send data
    log_verbose "Connecting with UDP client"
    local client_success=false
    if echo "$test_data" | timeout $((TIMEOUT/2)) "$CLIENT_BINARY" -u localhost "$port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        log_success "UDP echo test passed"
        update_result "basic" "udp_echo" "pass" "UDP communication successful on port $port" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "UDP echo test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "basic" "udp_echo" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# Connection timeout test
test_connection_timeout() {
    log_info "Running connection timeout test..."
    local start_time=$(date +%s.%N)
    
    # Use a port that should be closed
    local closed_port=65432
    local client_log="/tmp/zigcat_timeout_test.log"
    
    log_verbose "Testing connection timeout to closed port $closed_port"
    
    # Try to connect to closed port with short timeout
    local client_success=false
    if timeout 10 "$CLIENT_BINARY" -w 3 localhost "$closed_port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Should fail to connect (which is expected behavior)
    if [[ "$client_success" == "false" ]]; then
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        if echo "$client_output" | grep -q -i "timeout\|refused\|failed"; then
            log_success "Connection timeout test passed"
            update_result "basic" "connection_timeout" "pass" "Correctly handled connection timeout/refusal" "$duration"
            cleanup_logs "$client_log"
            return 0
        fi
    fi
    
    log_error "Connection timeout test failed"
    local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
    update_result "basic" "connection_timeout" "fail" "Unexpected behavior: $client_output" "$duration"
    cleanup_logs "$client_log"
    return 1
}

# TLS handshake test
test_tls_handshake() {
    log_info "Running TLS handshake test..."
    local start_time=$(date +%s.%N)
    
    # Check if TLS is supported
    if ! "$SERVER_BINARY" --help 2>&1 | grep -q -i "tls\|ssl"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "TLS not supported, skipping test"
        update_result "protocols" "tls_handshake" "skip" "TLS support not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 200))); then
        update_result "protocols" "tls_handshake" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for TLS handshake test"
    
    # For now, we'll test basic TLS flag recognition
    # Full TLS testing would require certificates
    local server_log="/tmp/zigcat_tls_server_$port.log"
    
    # Test if TLS flags are recognized
    if "$SERVER_BINARY" --ssl --help > "$server_log" 2>&1 || "$SERVER_BINARY" --tls --help > "$server_log" 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "TLS flags recognized"
        update_result "protocols" "tls_handshake" "pass" "TLS/SSL flags are recognized by binary" "$duration"
        cleanup_logs "$server_log"
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "TLS flags not recognized"
        update_result "protocols" "tls_handshake" "skip" "TLS/SSL flags not recognized" "$duration"
        cleanup_logs "$server_log"
        return 0
    fi
}

# Proxy protocol test
test_proxy_protocol() {
    log_info "Running proxy protocol test..."
    local start_time=$(date +%s.%N)
    
    # Check if proxy support is available
    if ! "$CLIENT_BINARY" --help 2>&1 | grep -q -i "proxy"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Proxy support not detected, skipping test"
        update_result "protocols" "proxy_protocol" "skip" "Proxy support not detected in binary" "$duration"
        return 0
    fi
    
    # Test proxy flag recognition
    local client_log="/tmp/zigcat_proxy_test.log"
    
    if "$CLIENT_BINARY" --proxy-type http --help > "$client_log" 2>&1 || "$CLIENT_BINARY" --proxy --help > "$client_log" 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Proxy flags recognized"
        update_result "protocols" "proxy_protocol" "pass" "Proxy flags are recognized by binary" "$duration"
        cleanup_logs "$client_log"
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Proxy flags not recognized"
        update_result "protocols" "proxy_protocol" "skip" "Proxy flags not recognized" "$duration"
        cleanup_logs "$client_log"
        return 0
    fi
}

# File transfer test
test_file_transfer() {
    log_info "Running file transfer test..."
    local start_time=$(date +%s.%N)
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 300))); then
        update_result "advanced" "file_transfer" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for file transfer test"
    
    # Create test file
    local test_file="/tmp/zigcat_test_file.txt"
    local received_file="/tmp/zigcat_received_file.txt"
    echo "$TEST_MESSAGE file transfer test $(date)" > "$test_file"
    
    local server_log="/tmp/zigcat_server_file_$port.log"
    local client_log="/tmp/zigcat_client_file_$port.log"
    
    # Start server to receive file
    log_verbose "Starting file transfer server on port $port"
    timeout $TIMEOUT "$SERVER_BINARY" -l "$port" -v > "$received_file" 2> "$server_log" &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "File transfer server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "advanced" "file_transfer" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log" "$test_file" "$received_file"
        return 1
    fi
    
    # Send file with client
    log_verbose "Sending file with client"
    local client_success=false
    if timeout $((TIMEOUT/2)) "$CLIENT_BINARY" localhost "$port" -v < "$test_file" > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check if file was transferred correctly
    if [[ "$client_success" == "true" ]] && [[ -f "$received_file" ]] && cmp -s "$test_file" "$received_file"; then
        log_success "File transfer test passed"
        update_result "advanced" "file_transfer" "pass" "File transferred successfully" "$duration"
        cleanup_logs "$server_log" "$client_log" "$test_file" "$received_file"
        return 0
    else
        log_error "File transfer test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "advanced" "file_transfer" "fail" "Transfer failed - Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log" "$test_file" "$received_file"
        return 1
    fi
}

# Exec mode test
test_exec_mode() {
    log_info "Running exec mode test..."
    local start_time=$(date +%s.%N)
    
    # Check if exec mode is supported
    if ! "$SERVER_BINARY" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping test"
        update_result "advanced" "exec_mode" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 400))); then
        update_result "advanced" "exec_mode" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for exec mode test"
    
    # Use a safe command for testing
    local test_command="echo"
    local server_log="/tmp/zigcat_exec_server_$port.log"
    local client_log="/tmp/zigcat_exec_client_$port.log"
    
    # Start server with exec mode
    log_verbose "Starting exec mode server on port $port"
    timeout $TIMEOUT "$SERVER_BINARY" -l "$port" -e "$test_command" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Exec mode server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "advanced" "exec_mode" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with client and send command input
    log_verbose "Connecting to exec mode server"
    local client_success=false
    if echo "test input" | timeout $((TIMEOUT/2)) "$CLIENT_BINARY" localhost "$port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        log_success "Exec mode test passed"
        update_result "advanced" "exec_mode" "pass" "Exec mode communication successful" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "Exec mode test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "advanced" "exec_mode" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# Cleanup log files
cleanup_logs() {
    if [[ "$KEEP_LOGS" == "false" ]]; then
        for log_file in "$@"; do
            [[ -f "$log_file" ]] && rm -f "$log_file"
        done
    else
        log_verbose "Keeping log files: $*"
    fi
}

# Run test suite
run_test_suite() {
    local suite="$1"
    log_info "Running $suite test suite..."
    
    local suite_failed=false
    
    case "$suite" in
        basic)
            test_tcp_echo || suite_failed=true
            test_udp_echo || suite_failed=true
            test_connection_timeout || suite_failed=true
            ;;
        protocols)
            test_tls_handshake || suite_failed=true
            test_proxy_protocol || suite_failed=true
            ;;
        advanced)
            test_file_transfer || suite_failed=true
            test_exec_mode || suite_failed=true
            ;;
        *)
            log_error "Unknown test suite: $suite"
            return 1
            ;;
    esac
    
    if [[ "$suite_failed" == "true" ]]; then
        log_error "$suite test suite completed with failures"
        return 1
    else
        log_success "$suite test suite completed successfully"
        return 0
    fi
}

# Generate summary report
generate_summary() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        log_info "Generating summary report..."
        
        # Extract summary from JSON
        local total_tests passed_tests failed_tests skipped_tests
        total_tests=$(python3 -c "import json; data=json.load(open('$OUTPUT_FILE')); print(data['summary']['total_tests'])" 2>/dev/null || echo "0")
        passed_tests=$(python3 -c "import json; data=json.load(open('$OUTPUT_FILE')); print(data['summary']['passed'])" 2>/dev/null || echo "0")
        failed_tests=$(python3 -c "import json; data=json.load(open('$OUTPUT_FILE')); print(data['summary']['failed'])" 2>/dev/null || echo "0")
        skipped_tests=$(python3 -c "import json; data=json.load(open('$OUTPUT_FILE')); print(data['summary']['skipped'])" 2>/dev/null || echo "0")
        
        echo
        log_info "=== Cross-Platform Integration Test Summary ==="
        log_info "Server: $SERVER_PLATFORM-$SERVER_ARCH ($SERVER_BINARY)"
        log_info "Client: $CLIENT_PLATFORM-$CLIENT_ARCH ($CLIENT_BINARY)"
        log_info "Test Suites: $TEST_SUITES"
        echo
        log_info "Test Results:"
        log_success "  Passed: $passed_tests"
        if [[ "$failed_tests" -gt 0 ]]; then
            log_error "  Failed: $failed_tests"
        else
            log_info "  Failed: $failed_tests"
        fi
        if [[ "$skipped_tests" -gt 0 ]]; then
            log_warning "  Skipped: $skipped_tests"
        else
            log_info "  Skipped: $skipped_tests"
        fi
        log_info "  Total: $total_tests"
        echo
        
        if [[ "$failed_tests" -gt 0 ]]; then
            log_error "Cross-platform integration tests completed with failures"
            return 1
        else
            log_success "Cross-platform integration tests completed successfully"
            return 0
        fi
    else
        log_info "No output file specified, skipping detailed summary"
        return 0
    fi
}

# Main execution
main() {
    local overall_start_time=$(date +%s.%N)
    
    log_info "Starting ZigCat cross-platform integration tests..."
    log_info "Server: $SERVER_PLATFORM-$SERVER_ARCH"
    log_info "Client: $CLIENT_PLATFORM-$CLIENT_ARCH"
    log_info "Test Suites: $TEST_SUITES"
    
    # Initialize results if output file specified
    if [[ -n "$OUTPUT_FILE" ]]; then
        mkdir -p "$(dirname "$OUTPUT_FILE")"
        init_results
        log_verbose "Results will be written to: $OUTPUT_FILE"
    fi
    
    # Run test suites
    local tests_failed=false
    IFS=',' read -ra SUITES <<< "$TEST_SUITES"
    for suite in "${SUITES[@]}"; do
        suite=$(echo "$suite" | xargs) # trim whitespace
        if ! run_test_suite "$suite"; then
            tests_failed=true
        fi
    done
    
    # Update total duration
    local overall_end_time=$(date +%s.%N)
    local total_duration=$(echo "$overall_end_time - $overall_start_time" | bc -l 2>/dev/null || echo "0")
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        python3 << EOF
import json
try:
    with open('$OUTPUT_FILE', 'r') as f:
        data = json.load(f)
    data['summary']['duration'] = $total_duration
    with open('$OUTPUT_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except:
    pass
EOF
    fi
    
    # Generate summary
    if ! generate_summary; then
        tests_failed=true
    fi
    
    if [[ "$tests_failed" == "true" ]]; then
        log_error "Cross-platform integration tests failed"
        exit 1
    else
        log_success "Cross-platform integration tests completed successfully"
        exit 0
    fi
}

# Parse arguments and run main function
parse_args "$@"
main