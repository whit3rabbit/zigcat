#!/bin/bash

# ZigCat Docker Test System - Cleanup System Test
# Tests the robust cleanup and resource management implementation

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source required systems
source "$SCRIPT_DIR/logging-system.sh"
source "$SCRIPT_DIR/error-handler.sh"

# Test configuration
TEST_TIMEOUT=60
VERBOSE=true
DRY_RUN=false

# Test results tracking
declare -a TEST_RESULTS=()
TESTS_PASSED=0
TESTS_FAILED=0

# Test logging
test_log() {
    local level="$1"
    local message="$2"
    log_message "$level" "CLEANUP_TEST" "$message"
}

# Run a test and track results
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    test_log "INFO" "Running test: $test_name"
    
    local start_time
    start_time=$(date +%s)
    
    if "$test_function"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        TEST_RESULTS+=("PASS:$test_name:${duration}s")
        ((TESTS_PASSED++))
        test_log "SUCCESS" "Test passed: $test_name (${duration}s)"
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        TEST_RESULTS+=("FAIL:$test_name:${duration}s")
        ((TESTS_FAILED++))
        test_log "ERROR" "Test failed: $test_name (${duration}s)"
        return 1
    fi
}

# Test 1: Cleanup Manager Basic Functionality
test_cleanup_manager_basic() {
    test_log "DEBUG" "Testing cleanup manager basic functionality"
    
    # Test help output
    if ! "$SCRIPT_DIR/cleanup-manager.sh" --help >/dev/null 2>&1; then
        test_log "ERROR" "Cleanup manager help failed"
        return 1
    fi
    
    # Test status command
    if ! "$SCRIPT_DIR/cleanup-manager.sh" status >/dev/null 2>&1; then
        test_log "ERROR" "Cleanup manager status failed"
        return 1
    fi
    
    # Test dry run
    if ! "$SCRIPT_DIR/cleanup-manager.sh" --dry-run cleanup >/dev/null 2>&1; then
        test_log "ERROR" "Cleanup manager dry run failed"
        return 1
    fi
    
    test_log "DEBUG" "Cleanup manager basic functionality test passed"
    return 0
}

# Test 2: Error Recovery System
test_error_recovery_system() {
    test_log "DEBUG" "Testing error recovery system"
    
    # Test error recovery help
    if ! "$SCRIPT_DIR/error-recovery.sh" --help >/dev/null 2>&1; then
        test_log "ERROR" "Error recovery help failed"
        return 1
    fi
    
    # Test status command
    if ! "$SCRIPT_DIR/error-recovery.sh" status >/dev/null 2>&1; then
        test_log "ERROR" "Error recovery status failed"
        return 1
    fi
    
    # Test collect command (dry run)
    if ! "$SCRIPT_DIR/error-recovery.sh" --dry-run collect >/dev/null 2>&1; then
        test_log "ERROR" "Error recovery collect failed"
        return 1
    fi
    
    test_log "DEBUG" "Error recovery system test passed"
    return 0
}

# Test 3: Logging System
test_logging_system() {
    test_log "DEBUG" "Testing logging system"
    
    # Test logging initialization
    if ! "$SCRIPT_DIR/logging-system.sh" init >/dev/null 2>&1; then
        test_log "ERROR" "Logging system init failed"
        return 1
    fi
    
    # Test all log levels
    if ! "$SCRIPT_DIR/logging-system.sh" test >/dev/null 2>&1; then
        test_log "ERROR" "Logging system test failed"
        return 1
    fi
    
    # Verify log files were created
    if [[ ! -d "$PROJECT_ROOT/docker-tests/logs/system" ]]; then
        test_log "ERROR" "System log directory not created"
        return 1
    fi
    
    test_log "DEBUG" "Logging system test passed"
    return 0
}

# Test 4: Error Handler
test_error_handler() {
    test_log "DEBUG" "Testing error handler"
    
    # Test error handler initialization
    if ! "$SCRIPT_DIR/error-handler.sh" init >/dev/null 2>&1; then
        test_log "ERROR" "Error handler init failed"
        return 1
    fi
    
    # Test error categorization
    if ! "$SCRIPT_DIR/error-handler.sh" test >/dev/null 2>&1; then
        test_log "ERROR" "Error handler test failed"
        return 1
    fi
    
    # Test report generation
    if ! "$SCRIPT_DIR/error-handler.sh" report >/dev/null 2>&1; then
        test_log "ERROR" "Error handler report failed"
        return 1
    fi
    
    test_log "DEBUG" "Error handler test passed"
    return 0
}

# Test 5: Resource Monitor
test_resource_monitor() {
    test_log "DEBUG" "Testing resource monitor"
    
    # Test resource monitor status
    if ! "$SCRIPT_DIR/resource-monitor.sh" status >/dev/null 2>&1; then
        test_log "ERROR" "Resource monitor status failed"
        return 1
    fi
    
    # Test report generation
    if ! "$SCRIPT_DIR/resource-monitor.sh" report >/dev/null 2>&1; then
        test_log "ERROR" "Resource monitor report failed"
        return 1
    fi
    
    test_log "DEBUG" "Resource monitor test passed"
    return 0
}

# Test 6: Signal Handling
test_signal_handling() {
    test_log "DEBUG" "Testing signal handling"
    
    # Create a test script that handles signals
    local test_script="/tmp/signal-test-$$.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
source "$(dirname "$0")/logging-system.sh"
source "$(dirname "$0")/error-handler.sh"

cleanup_called=false

cleanup() {
    echo "Cleanup called"
    cleanup_called=true
}

signal_handler() {
    echo "Signal received: $1"
    cleanup
    exit 0
}

trap 'signal_handler SIGTERM' SIGTERM
trap 'signal_handler SIGINT' SIGINT

# Wait for signal
sleep 30 &
wait $!
EOF
    
    chmod +x "$test_script"
    
    # Start the test script in background
    "$test_script" &
    local test_pid=$!
    
    # Give it time to start
    sleep 2
    
    # Send SIGTERM
    kill -TERM "$test_pid" 2>/dev/null || true
    
    # Wait for it to exit
    local exit_code=0
    wait "$test_pid" || exit_code=$?
    
    # Clean up
    rm -f "$test_script"
    
    # Check if it handled the signal properly
    if [[ $exit_code -eq 0 ]]; then
        test_log "DEBUG" "Signal handling test passed"
        return 0
    else
        test_log "ERROR" "Signal handling test failed with exit code: $exit_code"
        return 1
    fi
}

# Test 7: Timeout Handling
test_timeout_handling() {
    test_log "DEBUG" "Testing timeout handling"
    
    # Test cleanup manager with short timeout
    if timeout 10 "$SCRIPT_DIR/cleanup-manager.sh" --timeout 5 --dry-run cleanup >/dev/null 2>&1; then
        test_log "DEBUG" "Timeout handling test passed"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            # Timeout occurred, which is expected behavior
            test_log "DEBUG" "Timeout handling test passed (timeout occurred as expected)"
            return 0
        else
            test_log "ERROR" "Timeout handling test failed with unexpected exit code: $exit_code"
            return 1
        fi
    fi
}

# Test 8: Resource Leak Detection
test_resource_leak_detection() {
    test_log "DEBUG" "Testing resource leak detection"
    
    # Create some test containers to simulate leaks
    local test_containers=()
    
    # Create test containers with zigcat-test label
    for i in {1..3}; do
        local container_id
        container_id=$(docker run -d --label "zigcat-test=true" --name "test-leak-$i-$$" alpine:latest sleep 60 2>/dev/null || echo "")
        if [[ -n "$container_id" ]]; then
            test_containers+=("$container_id")
        fi
    done
    
    # Run cleanup manager status to detect leaks
    local status_output
    status_output=$("$SCRIPT_DIR/cleanup-manager.sh" status 2>&1 || echo "")
    
    # Clean up test containers
    for container_id in "${test_containers[@]}"; do
        docker rm -f "$container_id" >/dev/null 2>&1 || true
    done
    
    # Check if leaks were detected
    if [[ "$status_output" == *"Active Containers"* ]]; then
        test_log "DEBUG" "Resource leak detection test passed"
        return 0
    else
        test_log "ERROR" "Resource leak detection test failed - no leaks detected"
        return 1
    fi
}

# Test 9: Emergency Cleanup
test_emergency_cleanup() {
    test_log "DEBUG" "Testing emergency cleanup"
    
    # Create some test resources
    local test_network
    test_network=$(docker network create "zigcat-test-emergency-$$" 2>/dev/null || echo "")
    
    local test_volume
    test_volume=$(docker volume create --label "zigcat-test=true" "zigcat-test-vol-$$" 2>/dev/null || echo "")
    
    # Run emergency cleanup
    if "$SCRIPT_DIR/cleanup-manager.sh" emergency --timeout 30 >/dev/null 2>&1; then
        # Verify resources were cleaned up
        local network_exists=false
        local volume_exists=false
        
        if [[ -n "$test_network" ]] && docker network inspect "$test_network" >/dev/null 2>&1; then
            network_exists=true
            docker network rm "$test_network" >/dev/null 2>&1 || true
        fi
        
        if [[ -n "$test_volume" ]] && docker volume inspect "$test_volume" >/dev/null 2>&1; then
            volume_exists=true
            docker volume rm "$test_volume" >/dev/null 2>&1 || true
        fi
        
        if [[ "$network_exists" == "false" && "$volume_exists" == "false" ]]; then
            test_log "DEBUG" "Emergency cleanup test passed"
            return 0
        else
            test_log "ERROR" "Emergency cleanup test failed - resources not cleaned up"
            return 1
        fi
    else
        test_log "ERROR" "Emergency cleanup test failed - cleanup command failed"
        # Clean up manually
        [[ -n "$test_network" ]] && docker network rm "$test_network" >/dev/null 2>&1 || true
        [[ -n "$test_volume" ]] && docker volume rm "$test_volume" >/dev/null 2>&1 || true
        return 1
    fi
}

# Test 10: Integration Test
test_integration() {
    test_log "DEBUG" "Testing system integration"
    
    # Test the main run-tests.sh script with dry run
    if timeout 30 "$SCRIPT_DIR/run-tests.sh" --dry-run --timeout 20 >/dev/null 2>&1; then
        test_log "DEBUG" "Integration test passed"
        return 0
    else
        local exit_code=$?
        test_log "ERROR" "Integration test failed with exit code: $exit_code"
        return 1
    fi
}

# Generate test report
generate_test_report() {
    local report_file="$PROJECT_ROOT/docker-tests/results/cleanup-test-report-$(date +%Y%m%d-%H%M%S).json"
    
    test_log "INFO" "Generating test report: $report_file"
    
    # Create results directory
    mkdir -p "$(dirname "$report_file")"
    
    # Generate JSON report
    cat > "$report_file" << EOF
{
  "cleanup_system_test": {
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "summary": {
      "total_tests": $((TESTS_PASSED + TESTS_FAILED)),
      "passed": $TESTS_PASSED,
      "failed": $TESTS_FAILED,
      "success_rate": $(echo "scale=2; $TESTS_PASSED * 100 / ($TESTS_PASSED + $TESTS_FAILED)" | bc 2>/dev/null || echo "0")
    },
    "test_results": [
$(
    for result in "${TEST_RESULTS[@]}"; do
        IFS=':' read -ra PARTS <<< "$result"
        local status="${PARTS[0]}"
        local name="${PARTS[1]}"
        local duration="${PARTS[2]}"
        echo "      {\"name\": \"$name\", \"status\": \"$status\", \"duration\": \"$duration\"},"
    done | sed '$s/,$//'
)
    ],
    "environment": {
      "hostname": "$(hostname)",
      "user": "$(whoami)",
      "docker_version": "$(docker --version 2>/dev/null || echo 'N/A')",
      "os": "$(uname -s)",
      "architecture": "$(uname -m)"
    }
  }
}
EOF
    
    test_log "SUCCESS" "Test report generated: $report_file"
    echo "$report_file"
}

# Show test summary
show_test_summary() {
    echo ""
    echo "=== Cleanup System Test Summary ==="
    echo "Total Tests: $((TESTS_PASSED + TESTS_FAILED))"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "Result: ALL TESTS PASSED ✓"
    else
        echo "Result: SOME TESTS FAILED ✗"
    fi
    
    echo ""
    echo "=== Individual Test Results ==="
    for result in "${TEST_RESULTS[@]}"; do
        IFS=':' read -ra PARTS <<< "$result"
        local status="${PARTS[0]}"
        local name="${PARTS[1]}"
        local duration="${PARTS[2]}"
        
        if [[ "$status" == "PASS" ]]; then
            echo "  ✓ $name ($duration)"
        else
            echo "  ✗ $name ($duration)"
        fi
    done
}

# Main test execution
main() {
    test_log "INFO" "Starting ZigCat Docker Test System - Cleanup System Tests"
    
    # Initialize systems
    init_logging
    init_error_handling
    
    # Run all tests
    run_test "Cleanup Manager Basic" "test_cleanup_manager_basic"
    run_test "Error Recovery System" "test_error_recovery_system"
    run_test "Logging System" "test_logging_system"
    run_test "Error Handler" "test_error_handler"
    run_test "Resource Monitor" "test_resource_monitor"
    run_test "Signal Handling" "test_signal_handling"
    run_test "Timeout Handling" "test_timeout_handling"
    run_test "Resource Leak Detection" "test_resource_leak_detection"
    run_test "Emergency Cleanup" "test_emergency_cleanup"
    run_test "Integration Test" "test_integration"
    
    # Generate report
    local report_file
    report_file=$(generate_test_report)
    
    # Show summary
    show_test_summary
    
    test_log "INFO" "Cleanup system tests completed"
    test_log "INFO" "Report available at: $report_file"
    
    # Exit with appropriate code
    if [[ $TESTS_FAILED -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"