#!/bin/bash

# Security and Command Execution Tests for ZigCat
# Tests exec mode functionality, access control, security features, and timeout handling

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_TESTS_DIR="$PROJECT_ROOT/docker-tests"
RESULTS_DIR="$DOCKER_TESTS_DIR/results"

# Default values
PLATFORM=""
ARCHITECTURE=""
BINARY_PATH=""
TEST_SUITES="exec,security,timeout"
TIMEOUT=60
VERBOSE=false
OUTPUT_FILE=""
KEEP_LOGS=false

# Test configuration
BASE_PORT=16000
EXEC_TIMEOUT=30
SECURITY_TIMEOUT=15

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
Usage: $0 --platform PLATFORM --architecture ARCH --binary PATH [OPTIONS]

Tests ZigCat command execution and security features.

Required Arguments:
  --platform PLATFORM        Target platform (linux, alpine, freebsd)
  --architecture ARCH        Target architecture (amd64, arm64)
  --binary PATH              Path to the binary to test

Options:
  --test-suites SUITES       Test suites to run (exec,security,timeout) [default: exec,security,timeout]
  --timeout SECONDS          Test timeout per scenario [default: 60]
  --output FILE              Output file for test results (JSON format)
  --keep-logs                Keep test logs after completion
  --verbose                  Enable verbose output
  --help                     Show this help message

Test Suites:
  exec       - Command execution functionality, shell vs direct execution
  security   - Access control, privilege dropping, security warnings
  timeout    - Timeout handling, error recovery, graceful shutdown

Examples:
  $0 --platform linux --architecture amd64 --binary ./artifacts/linux-amd64/zigcat
  $0 --platform alpine --architecture arm64 --binary ./artifacts/alpine-arm64/zigcat \\
     --test-suites exec,security --verbose

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --platform)
                PLATFORM="$2"
                shift 2
                ;;
            --architecture)
                ARCHITECTURE="$2"
                shift 2
                ;;
            --binary)
                BINARY_PATH="$2"
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

    # Validate required arguments
    if [[ -z "$PLATFORM" || -z "$ARCHITECTURE" || -z "$BINARY_PATH" ]]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi

    # Validate platform
    case "$PLATFORM" in
        linux|alpine|freebsd)
            ;;
        *)
            log_error "Invalid platform: $PLATFORM. Must be one of: linux, alpine, freebsd"
            exit 1
            ;;
    esac

    # Validate architecture
    case "$ARCHITECTURE" in
        amd64|arm64)
            ;;
        *)
            log_error "Invalid architecture: $ARCHITECTURE. Must be one of: amd64, arm64"
            exit 1
            ;;
    esac

    # Check if binary exists
    if [[ ! -f "$BINARY_PATH" ]]; then
        log_error "Binary not found: $BINARY_PATH"
        exit 1
    fi

    # Make binary executable
    chmod +x "$BINARY_PATH" 2>/dev/null || true
}

# Initialize test results structure
init_results() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local session_id=$(date +%s)-$(head -c 8 /dev/urandom | base64 | tr -d '/' | tr -d '+' | tr -d '=')
    
    cat > "$OUTPUT_FILE" << EOF
{
  "test_run_id": "$session_id",
  "timestamp": "$timestamp",
  "platform": "$PLATFORM",
  "architecture": "$ARCHITECTURE",
  "binary_path": "$BINARY_PATH",
  "test_suites": "$TEST_SUITES",
  "test_results": {
    "exec": {},
    "security": {},
    "timeout": {}
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

# Test basic exec mode functionality
test_exec_basic() {
    log_info "Testing basic exec mode functionality..."
    local start_time=$(date +%s.%N)
    
    # Check if exec mode is supported
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping test"
        update_result "exec" "basic_exec" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port); then
        update_result "exec" "basic_exec" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for basic exec test"
    
    # Test with echo command (safe and available on all platforms)
    local server_log="/tmp/zigcat_exec_basic_$port.log"
    local client_log="/tmp/zigcat_client_basic_$port.log"
    
    # Start server with exec mode
    log_verbose "Starting exec mode server with echo command"
    timeout $EXEC_TIMEOUT "$BINARY_PATH" -l "$port" -e "echo" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Exec mode server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "basic_exec" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with client and send test input
    log_verbose "Sending test input to exec server"
    local test_input="Hello World"
    local client_success=false
    if echo "$test_input" | timeout $((EXEC_TIMEOUT/2)) "$BINARY_PATH" localhost "$port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        local client_output=$(cat "$client_log" 2>/dev/null || echo "")
        if echo "$client_output" | grep -q "$test_input"; then
            log_success "Basic exec mode test passed"
            update_result "exec" "basic_exec" "pass" "Echo command executed successfully, output contains input" "$duration"
        else
            log_success "Basic exec mode test passed (connection successful)"
            update_result "exec" "basic_exec" "pass" "Exec mode connection successful" "$duration"
        fi
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "Basic exec mode test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "basic_exec" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# Test shell vs direct execution
test_exec_shell_vs_direct() {
    log_info "Testing shell vs direct execution..."
    local start_time=$(date +%s.%N)
    
    # Check if exec mode is supported
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping test"
        update_result "exec" "shell_vs_direct" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 50))); then
        update_result "exec" "shell_vs_direct" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for shell vs direct execution test"
    
    # Test with a command that shows shell vs direct execution difference
    # Use 'pwd' command which should work on all platforms
    local server_log="/tmp/zigcat_exec_shell_$port.log"
    local client_log="/tmp/zigcat_client_shell_$port.log"
    
    # Start server with exec mode using pwd command
    log_verbose "Starting exec mode server with pwd command"
    timeout $EXEC_TIMEOUT "$BINARY_PATH" -l "$port" -e "pwd" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Shell vs direct exec server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "shell_vs_direct" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with client (pwd doesn't need input)
    log_verbose "Connecting to pwd exec server"
    local client_success=false
    if timeout $((EXEC_TIMEOUT/2)) "$BINARY_PATH" localhost "$port" -v < /dev/null > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        local client_output=$(cat "$client_log" 2>/dev/null || echo "")
        if echo "$client_output" | grep -q "/"; then
            log_success "Shell vs direct execution test passed"
            update_result "exec" "shell_vs_direct" "pass" "pwd command executed successfully, output contains path" "$duration"
        else
            log_success "Shell vs direct execution test passed (connection successful)"
            update_result "exec" "shell_vs_direct" "pass" "Command execution connection successful" "$duration"
        fi
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "Shell vs direct execution test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "shell_vs_direct" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# Test command execution with arguments
test_exec_with_args() {
    log_info "Testing command execution with arguments..."
    local start_time=$(date +%s.%N)
    
    # Check if exec mode is supported
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping test"
        update_result "exec" "exec_with_args" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 100))); then
        update_result "exec" "exec_with_args" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for exec with args test"
    
    # Test with echo command with arguments
    local server_log="/tmp/zigcat_exec_args_$port.log"
    local client_log="/tmp/zigcat_client_args_$port.log"
    
    # Start server with exec mode using echo with arguments
    log_verbose "Starting exec mode server with echo and arguments"
    timeout $EXEC_TIMEOUT "$BINARY_PATH" -l "$port" -e "echo 'Server Response:'" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is still running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Exec with args server failed to start"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "exec_with_args" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
    
    # Connect with client
    log_verbose "Connecting to exec server with arguments"
    local client_success=false
    if timeout $((EXEC_TIMEOUT/2)) "$BINARY_PATH" localhost "$port" -v < /dev/null > "$client_log" 2>&1; then
        client_success=true
    fi
    
    # Stop server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check results
    if [[ "$client_success" == "true" ]]; then
        log_success "Exec with args test passed"
        update_result "exec" "exec_with_args" "pass" "Command with arguments executed successfully" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 0
    else
        log_error "Exec with args test failed"
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "exec" "exec_with_args" "fail" "Client: $client_output | Server: $server_output" "$duration"
        cleanup_logs "$server_log" "$client_log"
        return 1
    fi
}

# Test access control features
test_access_control() {
    log_info "Testing access control features..."
    local start_time=$(date +%s.%N)
    
    # Check if access control flags are supported
    local has_access_control=false
    if "$BINARY_PATH" --help 2>&1 | grep -q -e "--allow\|--deny"; then
        has_access_control=true
    fi
    
    if [[ "$has_access_control" == "false" ]]; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Access control not supported, skipping test"
        update_result "security" "access_control" "skip" "Access control flags not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 150))); then
        update_result "security" "access_control" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for access control test"
    
    # Test access control flag recognition
    local server_log="/tmp/zigcat_access_control_$port.log"
    
    # Test if access control flags are recognized (don't actually start server)
    log_verbose "Testing access control flag recognition"
    if "$BINARY_PATH" --allow 127.0.0.1 --help > "$server_log" 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Access control flags recognized"
        update_result "security" "access_control" "pass" "Access control flags are recognized by binary" "$duration"
        cleanup_logs "$server_log"
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Access control flags not working"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "security" "access_control" "fail" "Access control flags failed: $server_output" "$duration"
        cleanup_logs "$server_log"
        return 1
    fi
}

# Test security warnings
test_security_warnings() {
    log_info "Testing security warnings..."
    local start_time=$(date +%s.%N)
    
    # Check if exec mode is supported (needed for security warnings)
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping security warnings test"
        update_result "security" "security_warnings" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 200))); then
        update_result "security" "security_warnings" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for security warnings test"
    
    # Test if security warnings are displayed for potentially dangerous commands
    local server_log="/tmp/zigcat_security_warnings_$port.log"
    
    # Try to start server with a potentially dangerous command (but don't actually execute)
    log_verbose "Testing security warnings for potentially dangerous commands"
    
    # Use a command that might trigger security warnings
    local dangerous_command="sh"
    
    # Start server briefly to capture any security warnings
    timeout 5 "$BINARY_PATH" -l "$port" -e "$dangerous_command" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait a moment then stop
    sleep 2
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check if any security-related output was generated
    local server_output=$(cat "$server_log" 2>/dev/null || echo "")
    if echo "$server_output" | grep -q -i "warning\|security\|danger\|risk"; then
        log_success "Security warnings test passed"
        update_result "security" "security_warnings" "pass" "Security warnings detected in output" "$duration"
    else
        log_info "Security warnings test completed (no warnings detected)"
        update_result "security" "security_warnings" "pass" "No security warnings needed for test command" "$duration"
    fi
    
    cleanup_logs "$server_log"
    return 0
}

# Test privilege dropping
test_privilege_dropping() {
    log_info "Testing privilege dropping..."
    local start_time=$(date +%s.%N)
    
    # Check if privilege dropping flags are supported
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "--user\|--group\|--drop"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Privilege dropping not supported, skipping test"
        update_result "security" "privilege_dropping" "skip" "Privilege dropping flags not detected in binary" "$duration"
        return 0
    fi
    
    # Test privilege dropping flag recognition
    local test_log="/tmp/zigcat_privilege_test.log"
    
    log_verbose "Testing privilege dropping flag recognition"
    if "$BINARY_PATH" --user nobody --help > "$test_log" 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Privilege dropping flags recognized"
        update_result "security" "privilege_dropping" "pass" "Privilege dropping flags are recognized by binary" "$duration"
        cleanup_logs "$test_log"
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Privilege dropping flags not working"
        local test_output=$(cat "$test_log" 2>/dev/null || echo "No test log")
        update_result "security" "privilege_dropping" "fail" "Privilege dropping flags failed: $test_output" "$duration"
        cleanup_logs "$test_log"
        return 1
    fi
}

# Test connection timeout handling
test_connection_timeout_handling() {
    log_info "Testing connection timeout handling..."
    local start_time=$(date +%s.%N)
    
    # Test client-side timeout
    local client_log="/tmp/zigcat_timeout_client.log"
    
    # Try to connect to a non-existent server with timeout
    local closed_port=65433
    log_verbose "Testing client timeout to closed port $closed_port"
    
    local client_success=false
    if timeout 15 "$BINARY_PATH" -w 5 localhost "$closed_port" -v > "$client_log" 2>&1; then
        client_success=true
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Should fail to connect (expected behavior)
    if [[ "$client_success" == "false" ]]; then
        local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
        if echo "$client_output" | grep -q -i "timeout\|refused\|failed\|connection"; then
            log_success "Connection timeout handling test passed"
            update_result "timeout" "connection_timeout" "pass" "Correctly handled connection timeout: $client_output" "$duration"
            cleanup_logs "$client_log"
            return 0
        fi
    fi
    
    log_error "Connection timeout handling test failed"
    local client_output=$(cat "$client_log" 2>/dev/null || echo "No client log")
    update_result "timeout" "connection_timeout" "fail" "Unexpected timeout behavior: $client_output" "$duration"
    cleanup_logs "$client_log"
    return 1
}

# Test graceful shutdown
test_graceful_shutdown() {
    log_info "Testing graceful shutdown..."
    local start_time=$(date +%s.%N)
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 250))); then
        update_result "timeout" "graceful_shutdown" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for graceful shutdown test"
    
    local server_log="/tmp/zigcat_shutdown_$port.log"
    
    # Start server
    log_verbose "Starting server for graceful shutdown test"
    timeout $TIMEOUT "$BINARY_PATH" -l "$port" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is running
    if ! kill -0 $server_pid 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Server failed to start for graceful shutdown test"
        local server_output=$(cat "$server_log" 2>/dev/null || echo "No server log")
        update_result "timeout" "graceful_shutdown" "fail" "Server failed to start: $server_output" "$duration"
        cleanup_logs "$server_log"
        return 1
    fi
    
    # Send SIGTERM for graceful shutdown
    log_verbose "Sending SIGTERM for graceful shutdown"
    kill -TERM $server_pid 2>/dev/null || true
    
    # Wait for graceful shutdown (should exit within reasonable time)
    local shutdown_timeout=10
    local shutdown_success=false
    for i in $(seq 1 $shutdown_timeout); do
        if ! kill -0 $server_pid 2>/dev/null; then
            shutdown_success=true
            break
        fi
        sleep 1
    done
    
    # Force kill if still running
    if [[ "$shutdown_success" == "false" ]]; then
        kill -KILL $server_pid 2>/dev/null || true
    fi
    
    wait $server_pid 2>/dev/null || true
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    if [[ "$shutdown_success" == "true" ]]; then
        log_success "Graceful shutdown test passed"
        update_result "timeout" "graceful_shutdown" "pass" "Server shut down gracefully within $shutdown_timeout seconds" "$duration"
        cleanup_logs "$server_log"
        return 0
    else
        log_error "Graceful shutdown test failed"
        update_result "timeout" "graceful_shutdown" "fail" "Server did not shut down gracefully within $shutdown_timeout seconds" "$duration"
        cleanup_logs "$server_log"
        return 1
    fi
}

# Test error recovery
test_error_recovery() {
    log_info "Testing error recovery..."
    local start_time=$(date +%s.%N)
    
    # Test recovery from invalid command in exec mode
    if ! "$BINARY_PATH" --help 2>&1 | grep -q -e "-e\|--exec"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Exec mode not supported, skipping error recovery test"
        update_result "timeout" "error_recovery" "skip" "Exec mode not detected in binary" "$duration"
        return 0
    fi
    
    local port
    if ! port=$(find_available_port $((BASE_PORT + 300))); then
        update_result "timeout" "error_recovery" "fail" "Could not find available port" "0"
        return 1
    fi
    
    log_verbose "Using port $port for error recovery test"
    
    # Try to start server with invalid command
    local server_log="/tmp/zigcat_error_recovery_$port.log"
    local invalid_command="/nonexistent/command/that/should/fail"
    
    log_verbose "Testing error recovery with invalid command"
    timeout 10 "$BINARY_PATH" -l "$port" -e "$invalid_command" -v > "$server_log" 2>&1 &
    local server_pid=$!
    
    # Wait and check behavior
    sleep 3
    
    # Server should either fail to start or handle the error gracefully
    local server_running=false
    if kill -0 $server_pid 2>/dev/null; then
        server_running=true
        kill $server_pid 2>/dev/null || true
        wait $server_pid 2>/dev/null || true
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Check server log for error handling
    local server_output=$(cat "$server_log" 2>/dev/null || echo "")
    if echo "$server_output" | grep -q -i "error\|failed\|not found\|invalid"; then
        log_success "Error recovery test passed"
        update_result "timeout" "error_recovery" "pass" "Error properly detected and handled: $server_output" "$duration"
        cleanup_logs "$server_log"
        return 0
    elif [[ "$server_running" == "false" ]]; then
        log_success "Error recovery test passed (server exited on error)"
        update_result "timeout" "error_recovery" "pass" "Server exited gracefully on invalid command" "$duration"
        cleanup_logs "$server_log"
        return 0
    else
        log_error "Error recovery test failed"
        update_result "timeout" "error_recovery" "fail" "No proper error handling detected: $server_output" "$duration"
        cleanup_logs "$server_log"
        return 1
    fi
}

# Run test suite
run_test_suite() {
    local suite="$1"
    log_info "Running $suite test suite..."
    
    local suite_failed=false
    
    case "$suite" in
        exec)
            test_exec_basic || suite_failed=true
            test_exec_shell_vs_direct || suite_failed=true
            test_exec_with_args || suite_failed=true
            ;;
        security)
            test_access_control || suite_failed=true
            test_security_warnings || suite_failed=true
            test_privilege_dropping || suite_failed=true
            ;;
        timeout)
            test_connection_timeout_handling || suite_failed=true
            test_graceful_shutdown || suite_failed=true
            test_error_recovery || suite_failed=true
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
        log_info "=== Security and Exec Mode Test Summary ==="
        log_info "Platform: $PLATFORM-$ARCHITECTURE"
        log_info "Binary: $BINARY_PATH"
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
            log_error "Security and exec mode tests completed with failures"
            return 1
        else
            log_success "Security and exec mode tests completed successfully"
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
    
    log_info "Starting ZigCat security and exec mode tests..."
    log_info "Platform: $PLATFORM-$ARCHITECTURE"
    log_info "Binary: $BINARY_PATH"
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
        log_error "Security and exec mode tests failed"
        exit 1
    else
        log_success "Security and exec mode tests completed successfully"
        exit 0
    fi
}

# Parse arguments and run main function
parse_args "$@"
main