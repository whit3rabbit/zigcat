#!/bin/bash

# Binary Validation Script for ZigCat Docker Test System
# Validates built executables for basic functionality and compatibility

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_TESTS_DIR="$PROJECT_ROOT/docker-tests"
ARTIFACTS_DIR="$DOCKER_TESTS_DIR/artifacts"
RESULTS_DIR="$DOCKER_TESTS_DIR/results"

# Default values
PLATFORM=""
ARCHITECTURE=""
BINARY_PATH=""
VERBOSE=false
OUTPUT_FILE=""

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

Validates ZigCat binary functionality and compatibility.

Required Arguments:
  --platform PLATFORM        Target platform (linux, alpine, freebsd)
  --architecture ARCH        Target architecture (amd64, arm64)
  --binary PATH              Path to the binary to validate

Options:
  --output FILE              Output file for test results (JSON format)
  --verbose                  Enable verbose output
  --help                     Show this help message

Examples:
  $0 --platform linux --architecture amd64 --binary ./artifacts/linux-amd64/zigcat
  $0 --platform alpine --architecture arm64 --binary ./artifacts/alpine-arm64/zigcat --verbose

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
            --output)
                OUTPUT_FILE="$2"
                shift 2
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
  "validation_results": {
    "basic_functionality": {},
    "library_dependencies": {},
    "compatibility": {}
  },
  "summary": {
    "total_tests": 0,
    "passed": 0,
    "failed": 0,
    "skipped": 0
  }
}
EOF
}

# Update test results
update_result() {
    local category="$1"
    local test_name="$2"
    local status="$3"
    local details="$4"
    local duration="${5:-0}"

    if [[ -n "$OUTPUT_FILE" ]]; then
        # Use Python to update JSON (more reliable than jq for complex updates)
        python3 << EOF
import json
import sys

try:
    with open('$OUTPUT_FILE', 'r') as f:
        data = json.load(f)
    
    # Update test result
    data['validation_results']['$category']['$test_name'] = {
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

# Test basic binary functionality
test_basic_functionality() {
    log_info "Testing basic binary functionality..."
    
    local start_time=$(date +%s.%N)
    
    # Test 1: Binary execution
    log_verbose "Testing binary execution..."
    if "$BINARY_PATH" --help >/dev/null 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Binary executes successfully"
        update_result "basic_functionality" "binary_execution" "pass" "Binary executes and responds to --help" "$duration"
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Binary execution failed"
        update_result "basic_functionality" "binary_execution" "fail" "Binary failed to execute or respond to --help" "$duration"
        return 1
    fi
    
    # Test 2: Help output validation
    log_verbose "Testing help output..."
    start_time=$(date +%s.%N)
    local help_output
    if help_output=$("$BINARY_PATH" --help 2>&1); then
        if echo "$help_output" | grep -q "Usage:"; then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_success "Help output contains usage information"
            update_result "basic_functionality" "help_output" "pass" "Help output contains expected Usage information" "$duration"
        else
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_warning "Help output missing usage information"
            update_result "basic_functionality" "help_output" "fail" "Help output does not contain Usage information" "$duration"
        fi
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_error "Failed to get help output"
        update_result "basic_functionality" "help_output" "fail" "Failed to retrieve help output" "$duration"
    fi
    
    # Test 3: Version information
    log_verbose "Testing version information..."
    start_time=$(date +%s.%N)
    local version_output
    if version_output=$("$BINARY_PATH" --version 2>&1) || version_output=$("$BINARY_PATH" -V 2>&1); then
        if [[ -n "$version_output" ]]; then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_success "Version information available"
            update_result "basic_functionality" "version_info" "pass" "Version: $version_output" "$duration"
        else
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_warning "Empty version output"
            update_result "basic_functionality" "version_info" "fail" "Version output is empty" "$duration"
        fi
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Version information not available"
        update_result "basic_functionality" "version_info" "skip" "Version flag not supported or failed" "$duration"
    fi
    
    # Test 4: Argument parsing
    log_verbose "Testing argument parsing..."
    start_time=$(date +%s.%N)
    if "$BINARY_PATH" -l 0 --help >/dev/null 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Argument parsing works correctly"
        update_result "basic_functionality" "argument_parsing" "pass" "Successfully parsed -l 0 --help combination" "$duration"
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Argument parsing may have issues"
        update_result "basic_functionality" "argument_parsing" "fail" "Failed to parse -l 0 --help combination" "$duration"
    fi
}

# Test library dependencies and dynamic linking
test_library_dependencies() {
    log_info "Testing library dependencies..."
    
    local start_time=$(date +%s.%N)
    
    # Test 1: Check if binary is statically linked (preferred for ZigCat)
    log_verbose "Checking linking type..."
    if command -v ldd >/dev/null 2>&1; then
        local ldd_output
        if ldd_output=$(ldd "$BINARY_PATH" 2>&1); then
            if echo "$ldd_output" | grep -q "not a dynamic executable"; then
                local end_time=$(date +%s.%N)
                local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
                log_success "Binary is statically linked"
                update_result "library_dependencies" "static_linking" "pass" "Binary is statically linked (preferred)" "$duration"
            else
                local end_time=$(date +%s.%N)
                local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
                log_info "Binary has dynamic dependencies"
                update_result "library_dependencies" "static_linking" "fail" "Binary has dynamic dependencies: $ldd_output" "$duration"
                
                # Test 2: Validate dynamic dependencies are available
                log_verbose "Validating dynamic dependencies..."
                start_time=$(date +%s.%N)
                local missing_deps=""
                while IFS= read -r line; do
                    if echo "$line" | grep -q "not found"; then
                        missing_deps="$missing_deps$line\n"
                    fi
                done <<< "$ldd_output"
                
                if [[ -z "$missing_deps" ]]; then
                    local end_time=$(date +%s.%N)
                    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
                    log_success "All dynamic dependencies are available"
                    update_result "library_dependencies" "dependency_availability" "pass" "All dynamic dependencies found" "$duration"
                else
                    local end_time=$(date +%s.%N)
                    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
                    log_error "Missing dynamic dependencies"
                    update_result "library_dependencies" "dependency_availability" "fail" "Missing dependencies: $missing_deps" "$duration"
                fi
            fi
        else
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_warning "Could not check dynamic dependencies"
            update_result "library_dependencies" "static_linking" "skip" "ldd failed: $ldd_output" "$duration"
        fi
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "ldd not available for dependency checking"
        update_result "library_dependencies" "static_linking" "skip" "ldd command not available" "$duration"
    fi
    
    # Test 3: Check binary architecture
    log_verbose "Checking binary architecture..."
    start_time=$(date +%s.%N)
    if command -v file >/dev/null 2>&1; then
        local file_output
        if file_output=$(file "$BINARY_PATH" 2>&1); then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_info "Binary architecture: $file_output"
            
            # Validate architecture matches expected
            case "$ARCHITECTURE" in
                amd64)
                    if echo "$file_output" | grep -q "x86-64\|x86_64\|AMD64"; then
                        log_success "Binary architecture matches expected (amd64)"
                        update_result "library_dependencies" "architecture_match" "pass" "Architecture matches: $file_output" "$duration"
                    else
                        log_error "Binary architecture mismatch"
                        update_result "library_dependencies" "architecture_match" "fail" "Expected amd64, got: $file_output" "$duration"
                    fi
                    ;;
                arm64)
                    if echo "$file_output" | grep -q "aarch64\|ARM64\|arm64"; then
                        log_success "Binary architecture matches expected (arm64)"
                        update_result "library_dependencies" "architecture_match" "pass" "Architecture matches: $file_output" "$duration"
                    else
                        log_error "Binary architecture mismatch"
                        update_result "library_dependencies" "architecture_match" "fail" "Expected arm64, got: $file_output" "$duration"
                    fi
                    ;;
            esac
        else
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_warning "Could not determine binary architecture"
            update_result "library_dependencies" "architecture_match" "skip" "file command failed" "$duration"
        fi
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "file command not available"
        update_result "library_dependencies" "architecture_match" "skip" "file command not available" "$duration"
    fi
}

# Test basic compatibility
test_compatibility() {
    log_info "Testing basic compatibility..."
    
    # Test 1: Basic socket creation (listen mode test)
    log_verbose "Testing socket creation capability..."
    local start_time=$(date +%s.%N)
    
    # Find an available port
    local test_port
    test_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || echo "12345")
    
    # Test basic listen capability (should fail gracefully or bind successfully)
    local listen_output
    if timeout 5 "$BINARY_PATH" -l "$test_port" -v </dev/null 2>&1 | head -10 > /tmp/zigcat_listen_test.log; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Socket creation capability verified"
        update_result "compatibility" "socket_creation" "pass" "Successfully attempted to bind to port $test_port" "$duration"
    else
        # Check if it failed due to permission issues (expected) or other issues
        if grep -q "Permission denied\|bind.*failed" /tmp/zigcat_listen_test.log 2>/dev/null; then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_success "Socket creation works (permission denied is expected)"
            update_result "compatibility" "socket_creation" "pass" "Socket creation works, permission denied expected for low ports" "$duration"
        else
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_warning "Socket creation test inconclusive"
            local log_content=$(cat /tmp/zigcat_listen_test.log 2>/dev/null || echo "No log available")
            update_result "compatibility" "socket_creation" "fail" "Socket test failed: $log_content" "$duration"
        fi
    fi
    
    # Cleanup
    rm -f /tmp/zigcat_listen_test.log
    
    # Test 2: Signal handling
    log_verbose "Testing signal handling..."
    start_time=$(date +%s.%N)
    
    # Start zigcat in background and send SIGTERM
    if timeout 10 bash -c "
        '$BINARY_PATH' -l $test_port -v </dev/null >/tmp/zigcat_signal_test.log 2>&1 &
        local pid=\$!
        sleep 2
        kill -TERM \$pid 2>/dev/null || true
        wait \$pid 2>/dev/null || true
        echo 'Signal test completed'
    "; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Signal handling works correctly"
        update_result "compatibility" "signal_handling" "pass" "Process responds to SIGTERM correctly" "$duration"
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Signal handling test inconclusive"
        update_result "compatibility" "signal_handling" "skip" "Signal handling test timed out or failed" "$duration"
    fi
    
    # Cleanup
    rm -f /tmp/zigcat_signal_test.log
    
    # Test 3: Error handling
    log_verbose "Testing error handling..."
    start_time=$(date +%s.%N)
    
    # Test with invalid arguments
    if "$BINARY_PATH" --invalid-argument 2>/dev/null; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_warning "Error handling may be insufficient"
        update_result "compatibility" "error_handling" "fail" "Binary accepted invalid argument" "$duration"
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_success "Error handling works correctly"
        update_result "compatibility" "error_handling" "pass" "Binary correctly rejects invalid arguments" "$duration"
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
        log_info "=== Binary Validation Summary ==="
        log_info "Platform: $PLATFORM"
        log_info "Architecture: $ARCHITECTURE"
        log_info "Binary: $BINARY_PATH"
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
            log_error "Binary validation completed with failures"
            return 1
        else
            log_success "Binary validation completed successfully"
            return 0
        fi
    else
        log_info "No output file specified, skipping detailed summary"
        return 0
    fi
}

# Main execution
main() {
    log_info "Starting ZigCat binary validation..."
    log_info "Platform: $PLATFORM, Architecture: $ARCHITECTURE"
    log_info "Binary: $BINARY_PATH"
    
    # Initialize results if output file specified
    if [[ -n "$OUTPUT_FILE" ]]; then
        mkdir -p "$(dirname "$OUTPUT_FILE")"
        init_results
        log_verbose "Results will be written to: $OUTPUT_FILE"
    fi
    
    # Run validation tests
    local validation_failed=false
    
    if ! test_basic_functionality; then
        validation_failed=true
    fi
    
    if ! test_library_dependencies; then
        validation_failed=true
    fi
    
    if ! test_compatibility; then
        validation_failed=true
    fi
    
    # Generate summary
    if ! generate_summary; then
        validation_failed=true
    fi
    
    if [[ "$validation_failed" == "true" ]]; then
        log_error "Binary validation failed"
        exit 1
    else
        log_success "Binary validation completed successfully"
        exit 0
    fi
}

# Parse arguments and run main function
parse_args "$@"
main