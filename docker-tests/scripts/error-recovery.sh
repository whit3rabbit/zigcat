#!/bin/bash

# ZigCat Docker Test System - Error Recovery and Partial Result Collection
# Implements graceful shutdown with partial result collection and retry mechanisms

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/docker-tests/results"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"
RECOVERY_DIR="$PROJECT_ROOT/docker-tests/recovery"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false
DRY_RUN=false
MAX_RETRIES=3
RETRY_DELAY=5
RECOVERY_TIMEOUT=60

# State tracking
declare -a FAILED_TESTS=()
declare -a PARTIAL_RESULTS=()
declare -a RECOVERY_ACTIONS=()

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
    fi
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

ZigCat Docker Test System - Error Recovery and Partial Result Collection

COMMANDS:
    collect                     Collect partial results from interrupted tests
    retry                       Retry failed tests with recovery mechanisms
    analyze                     Analyze failure patterns and suggest fixes
    recover                     Perform comprehensive recovery operations
    status                      Show recovery status and available data

OPTIONS:
    --max-retries COUNT         Maximum retry attempts (default: 3)
    --retry-delay SECONDS       Delay between retries (default: 5)
    --timeout SECONDS           Recovery operation timeout (default: 60)
    -v, --verbose               Enable verbose logging
    -n, --dry-run               Show what would be done without executing
    -h, --help                  Show this help message

EXAMPLES:
    $0 collect                  # Collect partial results from interrupted tests
    $0 retry                    # Retry failed tests with recovery
    $0 --max-retries 5 retry    # Retry with custom retry count
    $0 analyze                  # Analyze failure patterns

EOF
}

# Parse command-line arguments
parse_args() {
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --max-retries)
                MAX_RETRIES="$2"
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="$2"
                shift 2
                ;;
            --timeout)
                RECOVERY_TIMEOUT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            collect|retry|analyze|recover|status)
                command="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Default to collect if no command specified
    if [[ -z "$command" ]]; then
        command="collect"
    fi
    
    echo "$command"
}

# Initialize recovery environment
init_recovery() {
    log_debug "Initializing recovery environment..."
    
    # Create recovery directory structure
    mkdir -p "$RECOVERY_DIR"/{partial-results,failed-tests,retry-logs,analysis}
    
    # Create recovery state file
    local recovery_state="$RECOVERY_DIR/recovery-state.json"
    if [[ ! -f "$recovery_state" ]]; then
        cat > "$recovery_state" << EOF
{
  "recovery_session": {
    "id": "recovery-$(date +%Y%m%d-%H%M%S)",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "status": "initialized",
    "partial_results_collected": 0,
    "failed_tests_identified": 0,
    "retry_attempts": 0,
    "recovery_actions": []
  }
}
EOF
    fi
    
    log_debug "Recovery environment initialized"
}

# Collect partial results from interrupted tests
collect_partial_results() {
    log_info "Collecting partial results from interrupted tests..."
    
    init_recovery
    
    local collected_count=0
    local partial_results_file="$RECOVERY_DIR/partial-results/collected-$(date +%Y%m%d-%H%M%S).json"
    
    # Initialize partial results collection
    cat > "$partial_results_file" << EOF
{
  "partial_results": {
    "collection_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "source_directories": ["$LOGS_DIR", "$RESULTS_DIR"],
    "collected_tests": []
  }
}
EOF
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would collect partial results"
        return 0
    fi
    
    # Collect from log files
    if [[ -d "$LOGS_DIR" ]]; then
        log_debug "Scanning log directory: $LOGS_DIR"
        
        for log_file in "$LOGS_DIR"/test-*.log; do
            if [[ -f "$log_file" ]]; then
                local test_id
                test_id=$(basename "$log_file" .log | sed 's/^test-//')
                
                # Extract test information
                local platform arch suite status duration
                platform=$(grep "Platform:" "$log_file" 2>/dev/null | cut -d' ' -f2 || echo "unknown")
                arch=$(grep "Architecture:" "$log_file" 2>/dev/null | cut -d' ' -f2 || echo "unknown")
                suite=$(grep "Test Suite:" "$log_file" 2>/dev/null | cut -d' ' -f3 || echo "unknown")
                
                # Determine test status
                if grep -q "Test Successful" "$log_file"; then
                    status="completed"
                elif grep -q "Test failed" "$log_file"; then
                    status="failed"
                elif grep -q "Starting Test Execution" "$log_file"; then
                    status="interrupted"
                else
                    status="unknown"
                fi
                
                # Extract duration if available
                duration=$(grep "Duration:" "$log_file" 2>/dev/null | sed 's/.*Duration: \([0-9]*\)s.*/\1/' || echo "0")
                
                # Add to partial results
                local test_result
                test_result=$(cat << EOF
    {
      "test_id": "$test_id",
      "platform": "$platform",
      "architecture": "$arch",
      "test_suite": "$suite",
      "status": "$status",
      "duration": $duration,
      "log_file": "$log_file",
      "collected_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
EOF
                )
                
                # Append to partial results (handling JSON formatting)
                if [[ $collected_count -eq 0 ]]; then
                    # First entry
                    sed -i '' 's/"collected_tests": \[\]/"collected_tests": [/' "$partial_results_file"
                    echo "$test_result" >> "$partial_results_file"
                else
                    # Subsequent entries
                    sed -i '' '$s/$/,/' "$partial_results_file"
                    echo "$test_result" >> "$partial_results_file"
                fi
                
                ((collected_count++))
                
                # Track failed tests for retry
                if [[ "$status" == "failed" || "$status" == "interrupted" ]]; then
                    FAILED_TESTS+=("$test_id")
                fi
                
                log_debug "Collected partial result: $test_id ($status)"
            fi
        done
        
        # Close JSON array
        echo "  ]" >> "$partial_results_file"
        echo "}" >> "$partial_results_file"
        echo "}" >> "$partial_results_file"
    fi
    
    # Collect from existing result files
    if [[ -d "$RESULTS_DIR" ]]; then
        log_debug "Scanning results directory: $RESULTS_DIR"
        
        for result_file in "$RESULTS_DIR"/test-report*.json; do
            if [[ -f "$result_file" ]]; then
                log_debug "Found existing result file: $result_file"
                cp "$result_file" "$RECOVERY_DIR/partial-results/"
                ((collected_count++))
            fi
        done
    fi
    
    # Update recovery state
    local recovery_state="$RECOVERY_DIR/recovery-state.json"
    local temp_state=$(mktemp)
    jq --arg count "$collected_count" --arg failed "${#FAILED_TESTS[@]}" \
       '.recovery_session.partial_results_collected = ($count | tonumber) |
        .recovery_session.failed_tests_identified = ($failed | tonumber) |
        .recovery_session.status = "partial_results_collected"' \
       "$recovery_state" > "$temp_state" && mv "$temp_state" "$recovery_state"
    
    log_success "Collected $collected_count partial results, identified ${#FAILED_TESTS[@]} failed tests"
    
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        log_info "Failed tests available for retry: ${FAILED_TESTS[*]}"
    fi
}

# Analyze failure patterns and suggest recovery actions
analyze_failures() {
    log_info "Analyzing failure patterns..."
    
    local analysis_file="$RECOVERY_DIR/analysis/failure-analysis-$(date +%Y%m%d-%H%M%S).json"
    local failure_patterns=()
    local recovery_suggestions=()
    
    # Initialize analysis file
    cat > "$analysis_file" << EOF
{
  "failure_analysis": {
    "analysis_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "total_failures": ${#FAILED_TESTS[@]},
    "patterns": [],
    "recovery_suggestions": []
  }
}
EOF
    
    if [[ ${#FAILED_TESTS[@]} -eq 0 ]]; then
        log_info "No failed tests to analyze"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would analyze ${#FAILED_TESTS[@]} failed tests"
        return 0
    fi
    
    # Analyze each failed test
    local timeout_failures=0
    local build_failures=0
    local network_failures=0
    local resource_failures=0
    local unknown_failures=0
    
    for test_id in "${FAILED_TESTS[@]}"; do
        local log_file="$LOGS_DIR/test-${test_id}.log"
        
        if [[ -f "$log_file" ]]; then
            log_debug "Analyzing failure: $test_id"
            
            # Categorize failure type
            if grep -q -i "timeout\|timed out" "$log_file"; then
                ((timeout_failures++))
                failure_patterns+=("timeout")
            elif grep -q -i "build failed\|compilation error" "$log_file"; then
                ((build_failures++))
                failure_patterns+=("build")
            elif grep -q -i "network\|connection refused\|dns" "$log_file"; then
                ((network_failures++))
                failure_patterns+=("network")
            elif grep -q -i "out of memory\|disk space\|resource" "$log_file"; then
                ((resource_failures++))
                failure_patterns+=("resource")
            else
                ((unknown_failures++))
                failure_patterns+=("unknown")
            fi
        fi
    done
    
    # Generate recovery suggestions based on patterns
    if [[ $timeout_failures -gt 0 ]]; then
        recovery_suggestions+=("Increase timeout values for affected tests")
        recovery_suggestions+=("Check for hanging processes or containers")
        RECOVERY_ACTIONS+=("increase_timeouts")
    fi
    
    if [[ $build_failures -gt 0 ]]; then
        recovery_suggestions+=("Verify build dependencies and Zig compiler version")
        recovery_suggestions+=("Check for missing source files or build configuration")
        RECOVERY_ACTIONS+=("verify_build_env")
    fi
    
    if [[ $network_failures -gt 0 ]]; then
        recovery_suggestions+=("Check Docker network configuration")
        recovery_suggestions+=("Verify container connectivity and DNS resolution")
        RECOVERY_ACTIONS+=("fix_network_config")
    fi
    
    if [[ $resource_failures -gt 0 ]]; then
        recovery_suggestions+=("Increase Docker resource limits")
        recovery_suggestions+=("Clean up disk space and memory")
        RECOVERY_ACTIONS+=("increase_resources")
    fi
    
    if [[ $unknown_failures -gt 0 ]]; then
        recovery_suggestions+=("Review individual test logs for specific error details")
        recovery_suggestions+=("Consider running tests individually for debugging")
        RECOVERY_ACTIONS+=("manual_investigation")
    fi
    
    # Update analysis file with findings
    local temp_analysis=$(mktemp)
    jq --argjson timeout "$timeout_failures" \
       --argjson build "$build_failures" \
       --argjson network "$network_failures" \
       --argjson resource "$resource_failures" \
       --argjson unknown "$unknown_failures" \
       --argjson suggestions "$(printf '%s\n' "${recovery_suggestions[@]}" | jq -R . | jq -s .)" \
       '.failure_analysis.patterns = [
         {"type": "timeout", "count": $timeout},
         {"type": "build", "count": $build},
         {"type": "network", "count": $network},
         {"type": "resource", "count": $resource},
         {"type": "unknown", "count": $unknown}
       ] |
       .failure_analysis.recovery_suggestions = $suggestions' \
       "$analysis_file" > "$temp_analysis" && mv "$temp_analysis" "$analysis_file"
    
    log_success "Failure analysis completed:"
    log_info "  Timeout failures: $timeout_failures"
    log_info "  Build failures: $build_failures"
    log_info "  Network failures: $network_failures"
    log_info "  Resource failures: $resource_failures"
    log_info "  Unknown failures: $unknown_failures"
    
    if [[ ${#recovery_suggestions[@]} -gt 0 ]]; then
        log_info "Recovery suggestions:"
        for suggestion in "${recovery_suggestions[@]}"; do
            log_info "  - $suggestion"
        done
    fi
    
    log_info "Detailed analysis saved to: $analysis_file"
}

# Retry failed tests with recovery mechanisms
retry_failed_tests() {
    log_info "Retrying failed tests with recovery mechanisms..."
    
    if [[ ${#FAILED_TESTS[@]} -eq 0 ]]; then
        log_info "No failed tests to retry"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would retry ${#FAILED_TESTS[@]} failed tests"
        return 0
    fi
    
    local retry_log="$RECOVERY_DIR/retry-logs/retry-$(date +%Y%m%d-%H%M%S).log"
    local successful_retries=0
    local failed_retries=0
    
    {
        echo "=== Test Retry Session ==="
        echo "Start Time: $(date)"
        echo "Failed Tests: ${#FAILED_TESTS[@]}"
        echo "Max Retries: $MAX_RETRIES"
        echo "Retry Delay: ${RETRY_DELAY}s"
        echo ""
    } > "$retry_log"
    
    # Apply recovery actions before retrying
    apply_recovery_actions
    
    # Retry each failed test
    for test_id in "${FAILED_TESTS[@]}"; do
        log_info "Retrying test: $test_id"
        
        local retry_count=0
        local retry_successful=false
        
        while [[ $retry_count -lt $MAX_RETRIES && "$retry_successful" == "false" ]]; do
            ((retry_count++))
            
            {
                echo "=== Retry Attempt $retry_count for $test_id ==="
                echo "Attempt Time: $(date)"
            } >> "$retry_log"
            
            log_debug "Retry attempt $retry_count/$MAX_RETRIES for $test_id"
            
            # Extract test parameters from original log
            local log_file="$LOGS_DIR/test-${test_id}.log"
            local platform arch suite
            
            if [[ -f "$log_file" ]]; then
                platform=$(grep "Platform:" "$log_file" 2>/dev/null | cut -d' ' -f2 || echo "linux")
                arch=$(grep "Architecture:" "$log_file" 2>/dev/null | cut -d' ' -f2 || echo "amd64")
                suite=$(grep "Test Suite:" "$log_file" 2>/dev/null | cut -d' ' -f3 || echo "basic")
            else
                # Parse from test_id if log not available
                IFS='-' read -ra PARTS <<< "$test_id"
                platform="${PARTS[0]:-linux}"
                arch="${PARTS[1]:-amd64}"
                suite="${PARTS[2]:-basic}"
            fi
            
            # Retry the test with enhanced timeout and recovery
            local retry_timeout=$((RECOVERY_TIMEOUT * retry_count))
            
            if timeout "$retry_timeout" "$SCRIPT_DIR/run-tests.sh" \
                -p "$platform" \
                -a "$arch" \
                -s "$suite" \
                --test-timeout "$retry_timeout" \
                -v >> "$retry_log" 2>&1; then
                
                retry_successful=true
                ((successful_retries++))
                
                {
                    echo "✓ Retry successful for $test_id (attempt $retry_count)"
                    echo ""
                } >> "$retry_log"
                
                log_success "Retry successful: $test_id (attempt $retry_count)"
                break
            else
                {
                    echo "✗ Retry failed for $test_id (attempt $retry_count)"
                    echo ""
                } >> "$retry_log"
                
                log_warn "Retry failed: $test_id (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -lt $MAX_RETRIES ]]; then
                    log_debug "Waiting ${RETRY_DELAY}s before next retry..."
                    sleep "$RETRY_DELAY"
                fi
            fi
        done
        
        if [[ "$retry_successful" == "false" ]]; then
            ((failed_retries++))
            log_error "All retry attempts failed for: $test_id"
        fi
    done
    
    {
        echo "=== Retry Session Summary ==="
        echo "End Time: $(date)"
        echo "Successful Retries: $successful_retries"
        echo "Failed Retries: $failed_retries"
        echo "Total Tests: ${#FAILED_TESTS[@]}"
    } >> "$retry_log"
    
    # Update recovery state
    local recovery_state="$RECOVERY_DIR/recovery-state.json"
    local temp_state=$(mktemp)
    jq --arg retries "$successful_retries" --arg failed "$failed_retries" \
       '.recovery_session.retry_attempts = ($retries | tonumber) |
        .recovery_session.failed_retries = ($failed | tonumber) |
        .recovery_session.status = "retry_completed"' \
       "$recovery_state" > "$temp_state" && mv "$temp_state" "$recovery_state"
    
    log_success "Retry session completed: $successful_retries successful, $failed_retries failed"
    log_info "Retry log saved to: $retry_log"
    
    if [[ $failed_retries -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# Apply recovery actions based on analysis
apply_recovery_actions() {
    log_info "Applying recovery actions..."
    
    if [[ ${#RECOVERY_ACTIONS[@]} -eq 0 ]]; then
        log_debug "No recovery actions to apply"
        return 0
    fi
    
    for action in "${RECOVERY_ACTIONS[@]}"; do
        log_debug "Applying recovery action: $action"
        
        case "$action" in
            "increase_timeouts")
                # Increase timeout values
                export GLOBAL_TIMEOUT=$((GLOBAL_TIMEOUT * 2))
                export BUILD_TIMEOUT=$((BUILD_TIMEOUT * 2))
                export TEST_TIMEOUT=$((TEST_TIMEOUT * 2))
                log_info "Increased timeout values (doubled)"
                ;;
            "verify_build_env")
                # Verify build environment
                if command -v zig &> /dev/null; then
                    log_info "Zig compiler available: $(zig version)"
                else
                    log_warn "Zig compiler not found in PATH"
                fi
                ;;
            "fix_network_config")
                # Clean up network configuration
                log_info "Cleaning up Docker network configuration"
                docker network prune -f >/dev/null 2>&1 || true
                ;;
            "increase_resources")
                # Clean up resources
                log_info "Cleaning up Docker resources to free space"
                docker system prune -f >/dev/null 2>&1 || true
                ;;
            "manual_investigation")
                log_info "Manual investigation required - check individual test logs"
                ;;
            *)
                log_warn "Unknown recovery action: $action"
                ;;
        esac
    done
    
    log_success "Recovery actions applied"
}

# Show recovery status
show_recovery_status() {
    log_info "ZigCat Docker Test System - Recovery Status"
    
    local recovery_state="$RECOVERY_DIR/recovery-state.json"
    
    if [[ -f "$recovery_state" ]]; then
        echo "=== Recovery Session Information ==="
        jq -r '.recovery_session | 
               "Session ID: " + .id + "\n" +
               "Status: " + .status + "\n" +
               "Timestamp: " + .timestamp + "\n" +
               "Partial Results: " + (.partial_results_collected | tostring) + "\n" +
               "Failed Tests: " + (.failed_tests_identified | tostring) + "\n" +
               "Retry Attempts: " + (.retry_attempts | tostring)' "$recovery_state"
    else
        echo "No recovery session found"
    fi
    
    echo ""
    echo "=== Available Recovery Data ==="
    
    if [[ -d "$RECOVERY_DIR/partial-results" ]]; then
        local partial_count
        partial_count=$(find "$RECOVERY_DIR/partial-results" -name "*.json" | wc -l)
        echo "Partial Results Files: $partial_count"
    fi
    
    if [[ -d "$RECOVERY_DIR/failed-tests" ]]; then
        local failed_count
        failed_count=$(find "$RECOVERY_DIR/failed-tests" -name "*.log" | wc -l)
        echo "Failed Test Logs: $failed_count"
    fi
    
    if [[ -d "$RECOVERY_DIR/retry-logs" ]]; then
        local retry_count
        retry_count=$(find "$RECOVERY_DIR/retry-logs" -name "*.log" | wc -l)
        echo "Retry Log Files: $retry_count"
    fi
    
    if [[ -d "$RECOVERY_DIR/analysis" ]]; then
        local analysis_count
        analysis_count=$(find "$RECOVERY_DIR/analysis" -name "*.json" | wc -l)
        echo "Analysis Files: $analysis_count"
    fi
    
    echo ""
    echo "=== Directory Sizes ==="
    if [[ -d "$RECOVERY_DIR" ]]; then
        echo "Recovery Directory: $(du -sh "$RECOVERY_DIR" 2>/dev/null || echo "N/A")"
    fi
    if [[ -d "$LOGS_DIR" ]]; then
        echo "Logs Directory: $(du -sh "$LOGS_DIR" 2>/dev/null || echo "N/A")"
    fi
    if [[ -d "$RESULTS_DIR" ]]; then
        echo "Results Directory: $(du -sh "$RESULTS_DIR" 2>/dev/null || echo "N/A")"
    fi
}

# Comprehensive recovery operation
comprehensive_recovery() {
    log_info "Performing comprehensive recovery operation..."
    
    local recovery_successful=true
    
    # Step 1: Collect partial results
    if ! collect_partial_results; then
        log_error "Failed to collect partial results"
        recovery_successful=false
    fi
    
    # Step 2: Analyze failures
    if ! analyze_failures; then
        log_error "Failed to analyze failures"
        recovery_successful=false
    fi
    
    # Step 3: Retry failed tests
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        if ! retry_failed_tests; then
            log_warn "Some test retries failed"
            # Don't mark as failed - partial recovery is still valuable
        fi
    fi
    
    # Step 4: Generate recovery report
    local recovery_report="$RECOVERY_DIR/recovery-report-$(date +%Y%m%d-%H%M%S).json"
    cat > "$recovery_report" << EOF
{
  "recovery_report": {
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "status": "$(if [[ "$recovery_successful" == "true" ]]; then echo "successful"; else echo "partial"; fi)",
    "partial_results_collected": ${#PARTIAL_RESULTS[@]},
    "failed_tests_identified": ${#FAILED_TESTS[@]},
    "recovery_actions_applied": ${#RECOVERY_ACTIONS[@]},
    "recovery_suggestions": $(printf '%s\n' "${recovery_suggestions[@]}" 2>/dev/null | jq -R . | jq -s . || echo "[]")
  }
}
EOF
    
    log_info "Recovery report generated: $recovery_report"
    
    if [[ "$recovery_successful" == "true" ]]; then
        log_success "Comprehensive recovery completed successfully"
        return 0
    else
        log_warn "Comprehensive recovery completed with some issues"
        return 1
    fi
}

# Main function
main() {
    local command
    command=$(parse_args "$@")
    
    log_info "ZigCat Docker Test System - Error Recovery"
    log_info "Command: $command"
    log_info "Max Retries: $MAX_RETRIES"
    log_info "Retry Delay: ${RETRY_DELAY}s"
    
    case "$command" in
        "collect")
            collect_partial_results
            ;;
        "retry")
            collect_partial_results
            analyze_failures
            retry_failed_tests
            ;;
        "analyze")
            collect_partial_results
            analyze_failures
            ;;
        "recover")
            comprehensive_recovery
            ;;
        "status")
            show_recovery_status
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"