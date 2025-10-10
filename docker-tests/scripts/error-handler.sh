#!/bin/bash

# ZigCat Docker Test System - Comprehensive Error Handler
# Implements error categorization, recovery strategies, and debugging modes

set -euo pipefail

# Source the logging system
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging-system.sh"

# Error handling configuration
ERROR_HANDLING_MODE="${ERROR_HANDLING_MODE:-strict}"
AUTO_RECOVERY="${AUTO_RECOVERY:-false}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-5}"
RECOVERY_ATTEMPTS="${RECOVERY_ATTEMPTS:-3}"
DEBUG_ON_ERROR="${DEBUG_ON_ERROR:-false}"

# Error tracking
declare -A ERROR_COUNTS=()
declare -A ERROR_HISTORY=()
declare -A RECOVERY_ATTEMPTS_COUNT=()

# Initialize error handling
init_error_handling() {
    log_system "Initializing error handling system" \
        "mode=$ERROR_HANDLING_MODE" \
        "auto_recovery=$AUTO_RECOVERY" \
        "threshold=$ERROR_THRESHOLD"
    
    # Set up error traps
    trap 'handle_exit_error $? $LINENO $BASH_COMMAND' ERR
    trap 'handle_exit_signal SIGINT' SIGINT
    trap 'handle_exit_signal SIGTERM' SIGTERM
    
    # Enable debug mode if requested
    if [[ "$DEBUG_ON_ERROR" == "true" ]]; then
        set -x
    fi
}

# Handle script exit errors
handle_exit_error() {
    local exit_code="$1"
    local line_number="$2"
    local command="$3"
    
    log_error "Script error occurred" "ERROR_HANDLER" \
        "exit_code=$exit_code" \
        "line=$line_number" \
        "command=$command"
    
    # Collect debug information
    collect_debug_info "$exit_code" "$line_number" "$command"
    
    # Attempt recovery if enabled
    if [[ "$AUTO_RECOVERY" == "true" ]]; then
        attempt_error_recovery "SCRIPT_ERROR" "$command" "$exit_code"
    fi
    
    # Exit based on error handling mode
    case "$ERROR_HANDLING_MODE" in
        "strict")
            log_fatal "Exiting due to error in strict mode" "ERROR_HANDLER"
            exit "$exit_code"
            ;;
        "continue")
            log_warn "Continuing despite error in continue mode" "ERROR_HANDLER"
            return 0
            ;;
        "recover")
            if ! attempt_error_recovery "SCRIPT_ERROR" "$command" "$exit_code"; then
                log_fatal "Recovery failed, exiting" "ERROR_HANDLER"
                exit "$exit_code"
            fi
            ;;
    esac
}

# Handle exit signals
handle_exit_signal() {
    local signal="$1"
    
    log_warn "Received signal: $signal" "ERROR_HANDLER"
    
    # Perform graceful cleanup
    cleanup_on_error
    
    # Exit with appropriate code
    case "$signal" in
        "SIGINT")
            exit 130
            ;;
        "SIGTERM")
            exit 143
            ;;
        *)
            exit 1
            ;;
    esac
}

# Collect debug information on error
collect_debug_info() {
    local exit_code="$1"
    local line_number="$2"
    local command="$3"
    
    local debug_file="$LOGS_DIR/debug/error-debug-$(date +%Y%m%d-%H%M%S).log"
    
    {
        echo "=== ERROR DEBUG INFORMATION ==="
        echo "Timestamp: $(get_timestamp)"
        echo "Exit Code: $exit_code"
        echo "Line Number: $line_number"
        echo "Failed Command: $command"
        echo "Script: ${BASH_SOURCE[1]:-unknown}"
        echo "Function: ${FUNCNAME[2]:-main}"
        echo "PID: $$"
        echo "User: $(whoami)"
        echo "Working Directory: $(pwd)"
        echo ""
        
        echo "=== ENVIRONMENT VARIABLES ==="
        env | grep -E '^(LOG_|ERROR_|DEBUG_|TRACE_|DOCKER_|COMPOSE_)' | sort
        echo ""
        
        echo "=== SYSTEM INFORMATION ==="
        echo "OS: $(uname -s)"
        echo "Kernel: $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo "Hostname: $(hostname)"
        echo "Uptime: $(uptime)"
        echo ""
        
        echo "=== DOCKER STATUS ==="
        if command -v docker &> /dev/null; then
            echo "Docker Version: $(docker --version 2>/dev/null || echo 'N/A')"
            echo "Docker Status: $(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'Not running')"
            echo "Running Containers: $(docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo 'N/A')"
        else
            echo "Docker not available"
        fi
        echo ""
        
        echo "=== PROCESS INFORMATION ==="
        echo "Process Tree:"
        pstree -p $$ 2>/dev/null || ps -ef | grep -E "($$|zigcat|docker)" || echo "Process info not available"
        echo ""
        
        echo "=== RECENT LOG ENTRIES ==="
        if [[ -f "$LOGS_DIR/system/system-$(date +%Y%m%d).log" ]]; then
            echo "Last 20 system log entries:"
            tail -20 "$LOGS_DIR/system/system-$(date +%Y%m%d).log" 2>/dev/null || echo "No recent logs"
        fi
        echo ""
        
        echo "=== STACK TRACE ==="
        local frame=0
        while caller $frame 2>/dev/null; do
            ((frame++))
        done
        echo ""
        
    } > "$debug_file"
    
    log_debug "Debug information collected: $debug_file" "ERROR_HANDLER"
}

# Cleanup resources on error
cleanup_on_error() {
    log_info "Performing error cleanup" "ERROR_HANDLER"
    
    # Stop any background processes
    local cleanup_pids
    cleanup_pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$cleanup_pids" ]]; then
        log_debug "Stopping background processes: $cleanup_pids" "ERROR_HANDLER"
        # shellcheck disable=SC2086
        kill $cleanup_pids 2>/dev/null || true
    fi
    
    # Clean up temporary files
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
        find "$TMPDIR" -name "zigcat-test-*" -type f -mmin +60 -delete 2>/dev/null || true
    fi
    
    # Call cleanup manager if available
    if [[ -f "$SCRIPT_DIR/cleanup-manager.sh" ]]; then
        log_debug "Calling cleanup manager" "ERROR_HANDLER"
        "$SCRIPT_DIR/cleanup-manager.sh" cleanup --timeout 30 || true
    fi
}

# Categorize error and determine recovery strategy
categorize_and_recover() {
    local error_message="$1"
    local context="${2:-unknown}"
    local exit_code="${3:-1}"
    
    # Categorize the error
    local category
    category=$(categorize_error "$error_message")
    
    # Track error occurrence
    ERROR_COUNTS["$category"]=$((${ERROR_COUNTS["$category"]:-0} + 1))
    ERROR_HISTORY["$(date +%s)"]="$category:$context:$exit_code"
    
    log_error "Categorized error: $category" "ERROR_HANDLER" \
        "context=$context" \
        "exit_code=$exit_code" \
        "count=${ERROR_COUNTS["$category"]}"
    
    # Check if error threshold exceeded
    if [[ ${ERROR_COUNTS["$category"]} -gt $ERROR_THRESHOLD ]]; then
        log_fatal "Error threshold exceeded for category: $category" "ERROR_HANDLER" \
            "count=${ERROR_COUNTS["$category"]}" \
            "threshold=$ERROR_THRESHOLD"
        return 1
    fi
    
    # Attempt recovery if enabled
    if [[ "$AUTO_RECOVERY" == "true" ]]; then
        attempt_error_recovery "$category" "$error_message" "$exit_code"
    else
        log_info "Auto-recovery disabled, manual intervention required" "ERROR_HANDLER"
        return 1
    fi
}

# Attempt error recovery based on category
attempt_error_recovery() {
    local category="$1"
    local error_message="$2"
    local exit_code="${3:-1}"
    
    # Check recovery attempt count
    local recovery_key="${category}:${error_message}"
    RECOVERY_ATTEMPTS_COUNT["$recovery_key"]=$((${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]:-0} + 1))
    
    if [[ ${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]} -gt $RECOVERY_ATTEMPTS ]]; then
        log_error "Maximum recovery attempts exceeded" "ERROR_HANDLER" \
            "category=$category" \
            "attempts=${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]}" \
            "max_attempts=$RECOVERY_ATTEMPTS"
        return 1
    fi
    
    log_info "Attempting error recovery" "ERROR_HANDLER" \
        "category=$category" \
        "attempt=${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]}"
    
    local recovery_successful=false
    
    case "$category" in
        "TIMEOUT")
            recovery_successful=$(recover_timeout_error "$error_message")
            ;;
        "BUILD")
            recovery_successful=$(recover_build_error "$error_message")
            ;;
        "NETWORK")
            recovery_successful=$(recover_network_error "$error_message")
            ;;
        "RESOURCE")
            recovery_successful=$(recover_resource_error "$error_message")
            ;;
        "DOCKER")
            recovery_successful=$(recover_docker_error "$error_message")
            ;;
        "CONFIG")
            recovery_successful=$(recover_config_error "$error_message")
            ;;
        "PERMISSION")
            recovery_successful=$(recover_permission_error "$error_message")
            ;;
        "DEPENDENCY")
            recovery_successful=$(recover_dependency_error "$error_message")
            ;;
        *)
            log_warn "No specific recovery strategy for category: $category" "ERROR_HANDLER"
            recovery_successful=false
            ;;
    esac
    
    if [[ "$recovery_successful" == "true" ]]; then
        log_success "Error recovery successful" "ERROR_HANDLER" \
            "category=$category" \
            "attempt=${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]}"
        return 0
    else
        log_error "Error recovery failed" "ERROR_HANDLER" \
            "category=$category" \
            "attempt=${RECOVERY_ATTEMPTS_COUNT["$recovery_key"]}"
        return 1
    fi
}

# Specific recovery functions
recover_timeout_error() {
    local error_message="$1"
    
    log_info "Applying timeout error recovery" "RECOVERY"
    
    # Increase timeout values
    if [[ -n "${GLOBAL_TIMEOUT:-}" ]]; then
        export GLOBAL_TIMEOUT=$((GLOBAL_TIMEOUT * 2))
        log_info "Increased global timeout to ${GLOBAL_TIMEOUT}s" "RECOVERY"
    fi
    
    if [[ -n "${TEST_TIMEOUT:-}" ]]; then
        export TEST_TIMEOUT=$((TEST_TIMEOUT * 2))
        log_info "Increased test timeout to ${TEST_TIMEOUT}s" "RECOVERY"
    fi
    
    # Wait before retry
    log_info "Waiting 10 seconds before retry" "RECOVERY"
    sleep 10
    
    echo "true"
}

recover_build_error() {
    local error_message="$1"
    
    log_info "Applying build error recovery" "RECOVERY"
    
    # Clean build artifacts
    if [[ -d "zig-out" ]]; then
        log_info "Cleaning build artifacts" "RECOVERY"
        rm -rf zig-out
    fi
    
    # Verify Zig installation
    if ! command -v zig &> /dev/null; then
        log_error "Zig compiler not found" "RECOVERY"
        echo "false"
        return
    fi
    
    local zig_version
    zig_version=$(zig version 2>/dev/null || echo "unknown")
    log_info "Zig version: $zig_version" "RECOVERY"
    
    # Check for common build issues
    if [[ "$error_message" == *"OutOfMemory"* ]]; then
        log_info "Detected out of memory error, reducing parallelism" "RECOVERY"
        export ZIG_BUILD_JOBS=1
    fi
    
    echo "true"
}

recover_network_error() {
    local error_message="$1"
    
    log_info "Applying network error recovery" "RECOVERY"
    
    # Reset Docker networks
    log_info "Cleaning up Docker networks" "RECOVERY"
    docker network prune -f >/dev/null 2>&1 || true
    
    # Check connectivity
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_info "Internet connectivity verified" "RECOVERY"
    else
        log_warn "No internet connectivity detected" "RECOVERY"
    fi
    
    # Restart Docker daemon if possible
    if command -v systemctl &> /dev/null && [[ $(id -u) -eq 0 ]]; then
        log_info "Restarting Docker daemon" "RECOVERY"
        systemctl restart docker || true
        sleep 5
    fi
    
    echo "true"
}

recover_resource_error() {
    local error_message="$1"
    
    log_info "Applying resource error recovery" "RECOVERY"
    
    # Clean up Docker resources
    log_info "Cleaning up Docker resources" "RECOVERY"
    docker system prune -f --volumes >/dev/null 2>&1 || true
    
    # Clean up temporary files
    log_info "Cleaning up temporary files" "RECOVERY"
    find /tmp -name "zigcat-*" -type f -mmin +30 -delete 2>/dev/null || true
    
    # Check disk space
    local disk_usage
    disk_usage=$(df . | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        log_warn "Disk usage high: ${disk_usage}%" "RECOVERY"
        # Clean up old logs
        find "$LOGS_DIR" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    fi
    
    echo "true"
}

recover_docker_error() {
    local error_message="$1"
    
    log_info "Applying Docker error recovery" "RECOVERY"
    
    # Check Docker daemon status
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not accessible" "RECOVERY"
        echo "false"
        return
    fi
    
    # Clean up stuck containers
    log_info "Cleaning up stuck containers" "RECOVERY"
    docker ps -a --filter "status=exited" --filter "label=zigcat-test" -q | xargs -r docker rm >/dev/null 2>&1 || true
    
    # Reset Docker Compose
    if [[ -f "docker-compose.test.yml" ]]; then
        log_info "Resetting Docker Compose" "RECOVERY"
        docker-compose -f docker-compose.test.yml down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    
    echo "true"
}

recover_config_error() {
    local error_message="$1"
    
    log_info "Applying configuration error recovery" "RECOVERY"
    
    # Validate configuration files
    if [[ -f "docker-tests/configs/test-config.yml" ]]; then
        if command -v yq &> /dev/null; then
            if ! yq eval '.' "docker-tests/configs/test-config.yml" >/dev/null 2>&1; then
                log_error "Invalid YAML configuration" "RECOVERY"
                echo "false"
                return
            fi
        fi
    fi
    
    # Reset to default configuration if available
    if [[ -f "docker-tests/configs/test-config.yml.default" ]]; then
        log_info "Restoring default configuration" "RECOVERY"
        cp "docker-tests/configs/test-config.yml.default" "docker-tests/configs/test-config.yml"
    fi
    
    echo "true"
}

recover_permission_error() {
    local error_message="$1"
    
    log_info "Applying permission error recovery" "RECOVERY"
    
    # Check if running as root
    if [[ $(id -u) -eq 0 ]]; then
        log_info "Already running as root" "RECOVERY"
        echo "true"
        return
    fi
    
    # Check Docker group membership
    if groups | grep -q docker; then
        log_info "User is in docker group" "RECOVERY"
    else
        log_warn "User not in docker group, some operations may fail" "RECOVERY"
    fi
    
    # Fix common permission issues
    if [[ -d "$LOGS_DIR" ]]; then
        chmod -R u+w "$LOGS_DIR" 2>/dev/null || true
    fi
    
    echo "true"
}

recover_dependency_error() {
    local error_message="$1"
    
    log_info "Applying dependency error recovery" "RECOVERY"
    
    # Check for required tools
    local missing_tools=()
    
    for tool in docker docker-compose zig yq; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}" "RECOVERY"
        echo "false"
        return
    fi
    
    # Verify tool versions
    log_info "Docker version: $(docker --version)" "RECOVERY"
    log_info "Docker Compose version: $(docker-compose --version)" "RECOVERY"
    log_info "Zig version: $(zig version)" "RECOVERY"
    
    echo "true"
}

# Generate error report
generate_error_report() {
    local report_file="$LOGS_DIR/error-report-$(date +%Y%m%d-%H%M%S).json"
    
    log_info "Generating error report: $report_file" "ERROR_HANDLER"
    
    # Calculate error statistics
    local total_errors=0
    local error_categories_json="["
    local first=true
    
    for category in "${!ERROR_COUNTS[@]}"; do
        local count="${ERROR_COUNTS[$category]}"
        total_errors=$((total_errors + count))
        
        if [[ "$first" == "true" ]]; then
            first=false
        else
            error_categories_json+=","
        fi
        
        error_categories_json+="{\"category\": \"$category\", \"count\": $count}"
    done
    error_categories_json+="]"
    
    # Generate report
    cat > "$report_file" << EOF
{
  "error_report": {
    "timestamp": "$(get_timestamp)",
    "total_errors": $total_errors,
    "error_threshold": $ERROR_THRESHOLD,
    "auto_recovery_enabled": $AUTO_RECOVERY,
    "error_handling_mode": "$ERROR_HANDLING_MODE",
    "error_categories": $error_categories_json,
    "recovery_attempts": {
$(
    for key in "${!RECOVERY_ATTEMPTS_COUNT[@]}"; do
        echo "      \"$key\": ${RECOVERY_ATTEMPTS_COUNT[$key]},"
    done | sed '$s/,$//'
)
    },
    "system_info": {
      "hostname": "$(hostname)",
      "user": "$(whoami)",
      "pid": $$,
      "working_directory": "$(pwd)"
    }
  }
}
EOF
    
    log_success "Error report generated: $report_file" "ERROR_HANDLER"
    echo "$report_file"
}

# Show error statistics
show_error_stats() {
    log_info "Error Statistics" "ERROR_HANDLER"
    
    echo "=== Error Counts by Category ==="
    for category in "${!ERROR_COUNTS[@]}"; do
        echo "  $category: ${ERROR_COUNTS[$category]}"
    done
    
    echo ""
    echo "=== Recovery Attempts ==="
    for key in "${!RECOVERY_ATTEMPTS_COUNT[@]}"; do
        echo "  $key: ${RECOVERY_ATTEMPTS_COUNT[$key]}"
    done
    
    echo ""
    echo "=== Configuration ==="
    echo "  Error Handling Mode: $ERROR_HANDLING_MODE"
    echo "  Auto Recovery: $AUTO_RECOVERY"
    echo "  Error Threshold: $ERROR_THRESHOLD"
    echo "  Recovery Attempts: $RECOVERY_ATTEMPTS"
    echo "  Debug on Error: $DEBUG_ON_ERROR"
}

# Export error handling functions
export -f init_error_handling categorize_and_recover attempt_error_recovery
export -f generate_error_report show_error_stats

# Initialize error handling if this script is sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    init_error_handling
fi

# Main function for standalone execution
main() {
    case "${1:-init}" in
        "init")
            init_error_handling
            log_info "Error handling system initialized"
            ;;
        "report")
            generate_error_report
            ;;
        "stats")
            show_error_stats
            ;;
        "test")
            # Test error handling
            init_error_handling
            log_info "Testing error handling..."
            
            # Simulate different types of errors
            categorize_and_recover "Connection timeout after 30 seconds" "network_test" 1
            categorize_and_recover "Build failed: out of memory" "build_test" 2
            categorize_and_recover "Docker daemon not responding" "docker_test" 3
            
            show_error_stats
            ;;
        *)
            echo "Usage: $0 {init|report|stats|test}"
            echo ""
            echo "Commands:"
            echo "  init     Initialize error handling system"
            echo "  report   Generate error report"
            echo "  stats    Show error statistics"
            echo "  test     Test error handling functions"
            exit 1
            ;;
    esac
}

# Run main function if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi