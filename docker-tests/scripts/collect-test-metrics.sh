#!/bin/bash
# Collect detailed test metrics and performance data

set -euo pipefail

# Configuration
RESULTS_DIR="${RESULTS_DIR:-docker-tests/results}"
LOGS_DIR="${LOGS_DIR:-docker-tests/logs}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-docker-tests/artifacts}"
PLATFORM="${PLATFORM:-unknown}"
ARCHITECTURE="${ARCHITECTURE:-unknown}"
TEST_SUITE="${TEST_SUITE:-basic}"
VERBOSE="${VERBOSE:-false}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS] -- COMMAND [ARGS...]

Collect detailed test metrics while running a test command.

OPTIONS:
    --platform PLATFORM     Platform being tested (e.g., linux, freebsd, alpine)
    --architecture ARCH      Architecture being tested (e.g., amd64, arm64)
    --test-suite SUITE       Test suite name (e.g., basic, protocols, features)
    --results-dir DIR        Results directory (default: docker-tests/results)
    --logs-dir DIR           Logs directory (default: docker-tests/logs)
    --artifacts-dir DIR      Artifacts directory (default: docker-tests/artifacts)
    --verbose                Enable verbose output
    --help                   Show this help message

EXAMPLES:
    # Collect metrics for a Zig test run
    $0 --platform linux --architecture amd64 --test-suite basic -- zig test

    # Collect metrics for binary validation
    $0 --platform freebsd --architecture amd64 --test-suite validation -- ./validate-binary.sh

EOF
}

# Parse command line arguments
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
        --test-suite)
            TEST_SUITE="$2"
            shift 2
            ;;
        --results-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --logs-dir)
            LOGS_DIR="$2"
            shift 2
            ;;
        --artifacts-dir)
            ARTIFACTS_DIR="$2"
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
        --)
            shift
            break
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    log_error "No command specified"
    usage
    exit 1
fi

# Create directories
mkdir -p "$RESULTS_DIR" "$LOGS_DIR" "$ARTIFACTS_DIR"

# Generate unique identifiers
PLATFORM_KEY="${PLATFORM}-${ARCHITECTURE}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID=$(cat "$RESULTS_DIR/session-id" 2>/dev/null || echo "unknown")
TEST_ID="${PLATFORM_KEY}-${TEST_SUITE}-$(date +%s)"

# Output files
METRICS_FILE="$RESULTS_DIR/test-metrics-${PLATFORM_KEY}-${TEST_SUITE}.json"
LOG_FILE="$LOGS_DIR/test-${PLATFORM_KEY}-${TEST_SUITE}.log"
TEMP_METRICS="/tmp/test-metrics-${TEST_ID}.json"

log "Starting test metrics collection"
log "Platform: $PLATFORM_KEY"
log "Test Suite: $TEST_SUITE"
log "Command: $*"
log "Session ID: $SESSION_ID"

# Initialize metrics structure
cat > "$TEMP_METRICS" << EOF
{
  "test_run": {
    "session_id": "$SESSION_ID",
    "platform_key": "$PLATFORM_KEY",
    "platform": "$PLATFORM",
    "architecture": "$ARCHITECTURE",
    "test_suite": "$TEST_SUITE",
    "test_id": "$TEST_ID",
    "timestamp": "$TIMESTAMP",
    "command": "$*",
    "metrics": {
      "start_time": "$TIMESTAMP",
      "end_time": null,
      "duration": 0,
      "exit_code": null,
      "resource_usage": {},
      "test_results": {
        "total_tests": 0,
        "passed_tests": 0,
        "failed_tests": 0,
        "skipped_tests": 0,
        "test_cases": []
      },
      "performance": {
        "cpu_usage": [],
        "memory_usage": [],
        "disk_io": {},
        "network_io": {}
      },
      "environment": {
        "container_id": "${CONTAINER_ID:-}",
        "docker_image": "${DOCKER_IMAGE:-}",
        "zig_version": "",
        "system_info": {}
      }
    }
  }
}
EOF

# Function to collect system information
collect_system_info() {
    local temp_file="/tmp/sysinfo-${TEST_ID}.json"
    
    cat > "$temp_file" << EOF
{
  "hostname": "$(hostname 2>/dev/null || echo 'unknown')",
  "kernel": "$(uname -r 2>/dev/null || echo 'unknown')",
  "os": "$(uname -s 2>/dev/null || echo 'unknown')",
  "arch": "$(uname -m 2>/dev/null || echo 'unknown')",
  "cpu_count": $(nproc 2>/dev/null || echo 1),
  "memory_total": "$(free -b 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 0)",
  "disk_space": "$(df -B1 . 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
}
EOF
    
    # Update metrics with system info
    if command -v jq &> /dev/null; then
        jq --slurpfile sysinfo "$temp_file" '.test_run.metrics.environment.system_info = $sysinfo[0]' "$TEMP_METRICS" > "${TEMP_METRICS}.tmp"
        mv "${TEMP_METRICS}.tmp" "$TEMP_METRICS"
    fi
    
    rm -f "$temp_file"
}

# Function to collect Zig version
collect_zig_version() {
    if command -v zig &> /dev/null; then
        local zig_version
        zig_version=$(zig version 2>/dev/null || echo "unknown")
        
        if command -v jq &> /dev/null; then
            jq --arg version "$zig_version" '.test_run.metrics.environment.zig_version = $version' "$TEMP_METRICS" > "${TEMP_METRICS}.tmp"
            mv "${TEMP_METRICS}.tmp" "$TEMP_METRICS"
        fi
    fi
}

# Function to monitor resource usage
monitor_resources() {
    local pid=$1
    local interval=1
    
    while kill -0 "$pid" 2>/dev/null; do
        if command -v ps &> /dev/null; then
            # Collect CPU and memory usage
            local cpu_mem
            cpu_mem=$(ps -p "$pid" -o %cpu,%mem --no-headers 2>/dev/null || echo "0.0 0.0")
            local cpu=$(echo "$cpu_mem" | awk '{print $1}')
            local mem=$(echo "$cpu_mem" | awk '{print $2}')
            
            local timestamp
            timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            
            # Append to temporary files for later processing
            echo "{\"timestamp\": \"$timestamp\", \"cpu_percent\": $cpu, \"memory_percent\": $mem}" >> "/tmp/cpu-${TEST_ID}.jsonl"
        fi
        
        sleep "$interval"
    done
}

# Function to parse test output and extract results
parse_test_results() {
    local log_file="$1"
    local results_file="/tmp/parsed-results-${TEST_ID}.json"
    
    # Initialize results
    cat > "$results_file" << EOF
{
  "total_tests": 0,
  "passed_tests": 0,
  "failed_tests": 0,
  "skipped_tests": 0,
  "test_cases": []
}
EOF
    
    if [[ -f "$log_file" ]]; then
        # Use Python script to parse Zig test output if available
        if [[ -f "$SCRIPT_DIR/parse-zig-test-output.py" ]]; then
            if python3 "$SCRIPT_DIR/parse-zig-test-output.py" "$log_file" > "$results_file" 2>/dev/null; then
                log "Test results parsed successfully"
            else
                log_warning "Failed to parse test results with Python script"
            fi
        else
            # Simple parsing fallback
            local total_tests=0
            local passed_tests=0
            local failed_tests=0
            
            if grep -q "All [0-9]* tests passed" "$log_file" 2>/dev/null; then
                total_tests=$(grep "All [0-9]* tests passed" "$log_file" | sed 's/All \([0-9]*\) tests passed.*/\1/')
                passed_tests=$total_tests
            elif grep -q "[0-9]* passed" "$log_file" 2>/dev/null; then
                passed_tests=$(grep -o "[0-9]* passed" "$log_file" | head -1 | cut -d' ' -f1)
            fi
            
            if grep -q "[0-9]* failed" "$log_file" 2>/dev/null; then
                failed_tests=$(grep -o "[0-9]* failed" "$log_file" | head -1 | cut -d' ' -f1)
            fi
            
            total_tests=$((passed_tests + failed_tests))
            
            cat > "$results_file" << EOF
{
  "total_tests": $total_tests,
  "passed_tests": $passed_tests,
  "failed_tests": $failed_tests,
  "skipped_tests": 0,
  "test_cases": []
}
EOF
        fi
    fi
    
    # Update main metrics file
    if command -v jq &> /dev/null; then
        jq --slurpfile results "$results_file" '.test_run.metrics.test_results = $results[0]' "$TEMP_METRICS" > "${TEMP_METRICS}.tmp"
        mv "${TEMP_METRICS}.tmp" "$TEMP_METRICS"
    fi
    
    rm -f "$results_file"
}

# Function to finalize metrics
finalize_metrics() {
    local exit_code=$1
    local end_time
    end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Calculate duration
    local start_epoch end_epoch duration
    start_epoch=$(date -d "$TIMESTAMP" +%s 2>/dev/null || echo 0)
    end_epoch=$(date -d "$end_time" +%s 2>/dev/null || echo 0)
    duration=$((end_epoch - start_epoch))
    
    # Update metrics with final values
    if command -v jq &> /dev/null; then
        jq --arg end_time "$end_time" \
           --arg exit_code "$exit_code" \
           --arg duration "$duration" \
           '.test_run.metrics.end_time = $end_time | 
            .test_run.metrics.exit_code = ($exit_code | tonumber) | 
            .test_run.metrics.duration = ($duration | tonumber)' \
           "$TEMP_METRICS" > "${TEMP_METRICS}.tmp"
        mv "${TEMP_METRICS}.tmp" "$TEMP_METRICS"
    fi
    
    # Process resource usage data
    if [[ -f "/tmp/cpu-${TEST_ID}.jsonl" ]]; then
        local cpu_data="[]"
        if command -v jq &> /dev/null; then
            cpu_data=$(jq -s '.' "/tmp/cpu-${TEST_ID}.jsonl" 2>/dev/null || echo "[]")
            jq --argjson cpu_data "$cpu_data" '.test_run.metrics.performance.cpu_usage = $cpu_data' "$TEMP_METRICS" > "${TEMP_METRICS}.tmp"
            mv "${TEMP_METRICS}.tmp" "$TEMP_METRICS"
        fi
        rm -f "/tmp/cpu-${TEST_ID}.jsonl"
    fi
    
    # Copy final metrics to results directory
    cp "$TEMP_METRICS" "$METRICS_FILE"
    rm -f "$TEMP_METRICS"
    
    log_success "Metrics collection completed"
    log "Metrics saved to: $METRICS_FILE"
    log "Log saved to: $LOG_FILE"
    log "Exit code: $exit_code"
    log "Duration: ${duration}s"
}

# Collect initial system information
collect_system_info
collect_zig_version

# Set up signal handlers for cleanup
cleanup() {
    local exit_code=$?
    log_warning "Received signal, cleaning up..."
    
    # Kill background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Finalize metrics
    finalize_metrics $exit_code
    
    exit $exit_code
}

trap cleanup INT TERM EXIT

# Start the command and capture output
log "Starting command execution..."
START_TIME=$(date +%s)

# Run command with output capture
if [[ "$VERBOSE" == "true" ]]; then
    # Show output in real-time and capture to log
    "$@" 2>&1 | tee "$LOG_FILE"
    COMMAND_EXIT_CODE=${PIPESTATUS[0]}
else
    # Capture output to log only
    "$@" > "$LOG_FILE" 2>&1
    COMMAND_EXIT_CODE=$?
fi &

COMMAND_PID=$!

# Start resource monitoring in background
monitor_resources $COMMAND_PID &
MONITOR_PID=$!

# Wait for command to complete
wait $COMMAND_PID
COMMAND_EXIT_CODE=$?

# Stop resource monitoring
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

# Parse test results from log
parse_test_results "$LOG_FILE"

# Finalize metrics
finalize_metrics $COMMAND_EXIT_CODE

# Show summary
if [[ "$COMMAND_EXIT_CODE" -eq 0 ]]; then
    log_success "Command completed successfully"
else
    log_error "Command failed with exit code $COMMAND_EXIT_CODE"
fi

# Extract key metrics for display
if command -v jq &> /dev/null && [[ -f "$METRICS_FILE" ]]; then
    local total_tests passed_tests failed_tests duration
    total_tests=$(jq -r '.test_run.metrics.test_results.total_tests' "$METRICS_FILE" 2>/dev/null || echo "0")
    passed_tests=$(jq -r '.test_run.metrics.test_results.passed_tests' "$METRICS_FILE" 2>/dev/null || echo "0")
    failed_tests=$(jq -r '.test_run.metrics.test_results.failed_tests' "$METRICS_FILE" 2>/dev/null || echo "0")
    duration=$(jq -r '.test_run.metrics.duration' "$METRICS_FILE" 2>/dev/null || echo "0")
    
    log "Test Summary: $passed_tests/$total_tests passed, $failed_tests failed, ${duration}s duration"
fi

exit $COMMAND_EXIT_CODE