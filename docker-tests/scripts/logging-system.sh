#!/bin/bash

# ZigCat Docker Test System - Comprehensive Logging System
# Implements structured logging with verbosity levels, error categorization, and debugging modes

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"

# Logging configuration
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FORMAT="${LOG_FORMAT:-structured}"
LOG_ROTATION="${LOG_ROTATION:-true}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-100M}"
LOG_MAX_FILES="${LOG_MAX_FILES:-10}"
DEBUG_MODE="${DEBUG_MODE:-false}"
TRACE_MODE="${TRACE_MODE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Get log level numeric value
get_log_level_value() {
    local level="$1"
    case "$level" in
        "TRACE") echo "0" ;;
        "DEBUG") echo "1" ;;
        "INFO") echo "2" ;;
        "WARN") echo "3" ;;
        "ERROR") echo "4" ;;
        "FATAL") echo "5" ;;
        *) echo "2" ;;
    esac
}

# Get error category description
get_error_category_description() {
    local category="$1"
    case "$category" in
        "TIMEOUT") echo "Test or operation timeout" ;;
        "BUILD") echo "Build or compilation error" ;;
        "NETWORK") echo "Network connectivity issue" ;;
        "RESOURCE") echo "Resource exhaustion or limit" ;;
        "CONFIG") echo "Configuration or setup error" ;;
        "DOCKER") echo "Docker daemon or container issue" ;;
        "PERMISSION") echo "Permission or access denied" ;;
        "DEPENDENCY") echo "Missing dependency or tool" ;;
        "VALIDATION") echo "Data validation or format error" ;;
        *) echo "Unclassified error" ;;
    esac
}

# Get recovery strategies for error category
get_recovery_strategies() {
    local category="$1"
    case "$category" in
        "TIMEOUT") echo "increase_timeout,retry_with_delay" ;;
        "BUILD") echo "verify_dependencies,clean_build" ;;
        "NETWORK") echo "reset_network,check_connectivity" ;;
        "RESOURCE") echo "cleanup_resources,increase_limits" ;;
        "CONFIG") echo "validate_config,reset_defaults" ;;
        "DOCKER") echo "restart_docker,cleanup_containers" ;;
        "PERMISSION") echo "check_permissions,run_as_root" ;;
        "DEPENDENCY") echo "install_dependencies,check_path" ;;
        "VALIDATION") echo "fix_format,regenerate_data" ;;
        *) echo "manual_investigation,collect_debug_info" ;;
    esac
}

# Initialize logging system
init_logging() {
    # Create logs directory structure
    mkdir -p "$LOGS_DIR"/{system,test,debug,trace,error,audit}
    
    # Set up log rotation if enabled
    if [[ "$LOG_ROTATION" == "true" ]]; then
        setup_log_rotation
    fi
    
    # Initialize system log
    local system_log="$LOGS_DIR/system/system-$(date +%Y%m%d).log"
    log_system "INIT" "Logging system initialized" \
        "log_level=$LOG_LEVEL" \
        "log_format=$LOG_FORMAT" \
        "debug_mode=$DEBUG_MODE" \
        "trace_mode=$TRACE_MODE"
}

# Setup log rotation
setup_log_rotation() {
    local logrotate_config="$LOGS_DIR/logrotate.conf"
    
    cat > "$logrotate_config" << EOF
$LOGS_DIR/*/*.log {
    size $LOG_MAX_SIZE
    rotate $LOG_MAX_FILES
    compress
    delaycompress
    missingok
    notifempty
    create 644 $(whoami) $(id -gn)
    postrotate
        # Signal any running processes to reopen log files
        pkill -USR1 -f "zigcat.*test" || true
    endscript
}
EOF
    
    # Run logrotate if available
    if command -v logrotate &> /dev/null; then
        logrotate -f "$logrotate_config" 2>/dev/null || true
    fi
}

# Get current timestamp in ISO format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}



# Check if message should be logged based on level
should_log() {
    local message_level="$1"
    local current_level_value
    local message_level_value
    
    current_level_value=$(get_log_level_value "$LOG_LEVEL")
    message_level_value=$(get_log_level_value "$message_level")
    
    [[ $message_level_value -ge $current_level_value ]]
}

# Format log message based on LOG_FORMAT
format_log_message() {
    local level="$1"
    local component="$2"
    local message="$3"
    shift 3
    local metadata=("$@")
    
    local timestamp
    timestamp=$(get_timestamp)
    
    case "$LOG_FORMAT" in
        "json")
            if [[ ${#metadata[@]} -gt 0 ]] 2>/dev/null; then
                format_json_log "$timestamp" "$level" "$component" "$message" "${metadata[@]}"
            else
                format_json_log "$timestamp" "$level" "$component" "$message"
            fi
            ;;
        "structured")
            if [[ ${#metadata[@]} -gt 0 ]] 2>/dev/null; then
                format_structured_log "$timestamp" "$level" "$component" "$message" "${metadata[@]}"
            else
                format_structured_log "$timestamp" "$level" "$component" "$message"
            fi
            ;;
        "simple")
            format_simple_log "$timestamp" "$level" "$component" "$message"
            ;;
        *)
            if [[ ${#metadata[@]} -gt 0 ]] 2>/dev/null; then
                format_structured_log "$timestamp" "$level" "$component" "$message" "${metadata[@]}"
            else
                format_structured_log "$timestamp" "$level" "$component" "$message"
            fi
            ;;
    esac
}

# Format JSON log message
format_json_log() {
    local timestamp="$1"
    local level="$2"
    local component="$3"
    local message="$4"
    shift 4
    local metadata=("$@")
    
    local json_metadata=""
    if [[ $# -gt 0 ]]; then
        local metadata_pairs=()
        for item in "${metadata[@]}"; do
            if [[ "$item" == *"="* ]]; then
                local key="${item%%=*}"
                local value="${item#*=}"
                metadata_pairs+=("\"$key\": \"$value\"")
            fi
        done
        if [[ ${#metadata_pairs[@]} -gt 0 ]] 2>/dev/null; then
            json_metadata=", $(IFS=', '; echo "${metadata_pairs[*]}")"
        fi
    fi
    
    echo "{\"timestamp\": \"$timestamp\", \"level\": \"$level\", \"component\": \"$component\", \"message\": \"$message\", \"pid\": $$, \"hostname\": \"$(hostname)\"$json_metadata}"
}

# Format structured log message
format_structured_log() {
    local timestamp="$1"
    local level="$2"
    local component="$3"
    local message="$4"
    shift 4
    local metadata=("$@")
    
    local metadata_str=""
    if [[ $# -gt 0 ]]; then
        metadata_str=" [$(IFS=' '; echo "${metadata[*]}")]"
    fi
    
    echo "[$timestamp] [$level] [$component] [PID:$$] $message$metadata_str"
}

# Format simple log message
format_simple_log() {
    local timestamp="$1"
    local level="$2"
    local component="$3"
    local message="$4"
    
    echo "$(date '+%H:%M:%S') [$level] $message"
}

# Get color for log level
get_level_color() {
    local level="$1"
    case "$level" in
        "TRACE") echo "$PURPLE" ;;
        "DEBUG") echo "$CYAN" ;;
        "INFO") echo "$BLUE" ;;
        "WARN") echo "$YELLOW" ;;
        "ERROR") echo "$RED" ;;
        "FATAL") echo "$WHITE" ;;
        *) echo "$NC" ;;
    esac
}

# Core logging function
log_message() {
    local level="$1"
    local component="$2"
    local message="$3"
    shift 3
    local metadata=("$@")
    
    # Check if message should be logged
    if ! should_log "$level"; then
        return 0
    fi
    
    # Format the message
    local formatted_message
    if [[ $# -gt 3 ]]; then
        formatted_message=$(format_log_message "$level" "$component" "$message" "${@:4}")
    else
        formatted_message=$(format_log_message "$level" "$component" "$message")
    fi
    
    # Determine output destination
    local log_file=""
    case "$level" in
        "TRACE")
            log_file="$LOGS_DIR/trace/trace-$(date +%Y%m%d).log"
            ;;
        "DEBUG")
            log_file="$LOGS_DIR/debug/debug-$(date +%Y%m%d).log"
            ;;
        "ERROR"|"FATAL")
            log_file="$LOGS_DIR/error/error-$(date +%Y%m%d).log"
            ;;
        *)
            log_file="$LOGS_DIR/system/system-$(date +%Y%m%d).log"
            ;;
    esac
    
    # Write to log file
    echo "$formatted_message" >> "$log_file"
    
    # Write to stderr with color if terminal
    if [[ -t 2 ]]; then
        local color
        color=$(get_level_color "$level")
        echo -e "${color}${formatted_message}${NC}" >&2
    else
        echo "$formatted_message" >&2
    fi
    
    # Additional processing for errors
    if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then
        if [[ $# -gt 3 ]]; then
            process_error "$component" "$message" "${@:4}"
        else
            process_error "$component" "$message"
        fi
    fi
}

# Process error messages for categorization and recovery
process_error() {
    local component="$1"
    local message="$2"
    shift 2
    local metadata=("$@")
    
    # Categorize error
    local category
    category=$(categorize_error "$message")
    
    # Log error details
    local error_log="$LOGS_DIR/error/error-details-$(date +%Y%m%d).log"
    {
        echo "=== ERROR DETAILS ==="
        echo "Timestamp: $(get_timestamp)"
        echo "Component: $component"
        echo "Category: $category"
        echo "Message: $message"
        echo "Metadata: ${metadata[*]}"
        echo "Recovery Strategies: $(get_recovery_strategies "$category")"
        echo "Stack Trace:"
        if command -v caller &> /dev/null; then
            local frame=0
            while caller $frame 2>/dev/null; do
                ((frame++))
            done
        fi
        echo ""
    } >> "$error_log"
    
    # Trigger error recovery if enabled
    if [[ "${AUTO_RECOVERY:-false}" == "true" ]]; then
        trigger_error_recovery "$category" "$component" "$message"
    fi
}

# Categorize error based on message content
categorize_error() {
    local message="$1"
    local message_lower
    message_lower=$(echo "$message" | tr '[:upper:]' '[:lower:]')
    
    # Check for timeout patterns
    if [[ "$message_lower" == *"timeout"* || "$message_lower" == *"timed out"* ]]; then
        echo "TIMEOUT"
        return
    fi
    
    # Check for build patterns
    if [[ "$message_lower" == *"build failed"* || "$message_lower" == *"compilation"* || "$message_lower" == *"zig build"* ]]; then
        echo "BUILD"
        return
    fi
    
    # Check for network patterns
    if [[ "$message_lower" == *"network"* || "$message_lower" == *"connection"* || "$message_lower" == *"dns"* ]]; then
        echo "NETWORK"
        return
    fi
    
    # Check for resource patterns
    if [[ "$message_lower" == *"memory"* || "$message_lower" == *"disk"* || "$message_lower" == *"resource"* ]]; then
        echo "RESOURCE"
        return
    fi
    
    # Check for Docker patterns
    if [[ "$message_lower" == *"docker"* || "$message_lower" == *"container"* ]]; then
        echo "DOCKER"
        return
    fi
    
    # Check for permission patterns
    if [[ "$message_lower" == *"permission"* || "$message_lower" == *"access denied"* ]]; then
        echo "PERMISSION"
        return
    fi
    
    # Check for dependency patterns
    if [[ "$message_lower" == *"not found"* || "$message_lower" == *"missing"* ]]; then
        echo "DEPENDENCY"
        return
    fi
    
    # Check for configuration patterns
    if [[ "$message_lower" == *"config"* || "$message_lower" == *"invalid"* ]]; then
        echo "CONFIG"
        return
    fi
    
    # Check for validation patterns
    if [[ "$message_lower" == *"validation"* || "$message_lower" == *"format"* ]]; then
        echo "VALIDATION"
        return
    fi
    
    # Default to unknown
    echo "UNKNOWN"
}

# Trigger error recovery based on category
trigger_error_recovery() {
    local category="$1"
    local component="$2"
    local message="$3"
    
    log_message "INFO" "RECOVERY" "Triggering automatic recovery for $category error" \
        "component=$component"
    
    local strategies
    strategies=$(get_recovery_strategies "$category")
    IFS=',' read -ra strategy_list <<< "$strategies"
    
    for strategy in "${strategy_list[@]}"; do
        case "$strategy" in
            "increase_timeout")
                log_message "INFO" "RECOVERY" "Applying strategy: increase_timeout"
                # Implementation would increase timeout values
                ;;
            "retry_with_delay")
                log_message "INFO" "RECOVERY" "Applying strategy: retry_with_delay"
                # Implementation would schedule retry
                ;;
            "cleanup_resources")
                log_message "INFO" "RECOVERY" "Applying strategy: cleanup_resources"
                # Implementation would clean up resources
                ;;
            *)
                log_message "DEBUG" "RECOVERY" "Strategy not implemented: $strategy"
                ;;
        esac
    done
}

# Convenience logging functions
log_trace() {
    if [[ "$TRACE_MODE" == "true" ]]; then
        log_message "TRACE" "${2:-SYSTEM}" "$1" "${@:3}"
    fi
}

log_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        log_message "DEBUG" "${2:-SYSTEM}" "$1" "${@:3}"
    fi
}

log_info() {
    log_message "INFO" "${2:-SYSTEM}" "$1" "${@:3}"
}

log_warn() {
    log_message "WARN" "${2:-SYSTEM}" "$1" "${@:3}"
}

log_error() {
    log_message "ERROR" "${2:-SYSTEM}" "$1" "${@:3}"
}

log_fatal() {
    log_message "FATAL" "${2:-SYSTEM}" "$1" "${@:3}"
}

# Specialized logging functions
log_system() {
    log_message "INFO" "SYSTEM" "$@"
}

log_test() {
    local test_id="$1"
    local message="$2"
    shift 2
    local metadata=("$@")
    
    # Log to test-specific file
    local test_log="$LOGS_DIR/test/test-${test_id}-$(date +%Y%m%d).log"
    local formatted_message
    formatted_message=$(format_log_message "INFO" "TEST" "$message" "${metadata[@]}")
    echo "$formatted_message" >> "$test_log"
    
    # Also log to system
    log_message "INFO" "TEST" "$message" "test_id=$test_id" "${metadata[@]}"
}

log_audit() {
    local action="$1"
    local details="$2"
    shift 2
    local metadata=("$@")
    
    # Log to audit file
    local audit_log="$LOGS_DIR/audit/audit-$(date +%Y%m%d).log"
    local formatted_message
    formatted_message=$(format_log_message "INFO" "AUDIT" "$details" "action=$action" "${metadata[@]}")
    echo "$formatted_message" >> "$audit_log"
}

log_performance() {
    local operation="$1"
    local duration="$2"
    local details="$3"
    shift 3
    local metadata=("$@")
    
    log_message "INFO" "PERF" "$details" \
        "operation=$operation" \
        "duration=${duration}s" \
        "${metadata[@]}"
}

# Debug tracing functions
trace_enter() {
    local function_name="$1"
    shift
    local args=("$@")
    
    if [[ "$TRACE_MODE" == "true" ]]; then
        log_trace "ENTER $function_name" "TRACE" "args=${args[*]}"
    fi
}

trace_exit() {
    local function_name="$1"
    local exit_code="${2:-0}"
    
    if [[ "$TRACE_MODE" == "true" ]]; then
        log_trace "EXIT $function_name" "TRACE" "exit_code=$exit_code"
    fi
}

trace_var() {
    local var_name="$1"
    local var_value="$2"
    
    if [[ "$TRACE_MODE" == "true" ]]; then
        log_trace "VAR $var_name=$var_value" "TRACE"
    fi
}

# Log analysis and reporting
analyze_logs() {
    local start_date="${1:-$(date -d '1 day ago' +%Y%m%d)}"
    local end_date="${2:-$(date +%Y%m%d)}"
    
    log_info "Analyzing logs from $start_date to $end_date" "ANALYSIS"
    
    local analysis_report="$LOGS_DIR/analysis-$(date +%Y%m%d-%H%M%S).json"
    
    # Count messages by level
    local error_count=0
    local warn_count=0
    local info_count=0
    
    # Analyze error patterns
    local error_categories=()
    
    for log_file in "$LOGS_DIR"/*/*.log; do
        if [[ -f "$log_file" ]]; then
            local file_date
            file_date=$(basename "$log_file" .log | grep -o '[0-9]\{8\}' || echo "")
            
            if [[ -n "$file_date" && "$file_date" -ge "$start_date" && "$file_date" -le "$end_date" ]]; then
                # Count by level
                error_count=$((error_count + $(grep -c "\[ERROR\]" "$log_file" 2>/dev/null || echo 0)))
                warn_count=$((warn_count + $(grep -c "\[WARN\]" "$log_file" 2>/dev/null || echo 0)))
                info_count=$((info_count + $(grep -c "\[INFO\]" "$log_file" 2>/dev/null || echo 0)))
            fi
        fi
    done
    
    # Generate analysis report
    cat > "$analysis_report" << EOF
{
  "log_analysis": {
    "analysis_period": {
      "start_date": "$start_date",
      "end_date": "$end_date"
    },
    "message_counts": {
      "error": $error_count,
      "warn": $warn_count,
      "info": $info_count,
      "total": $((error_count + warn_count + info_count))
    },
    "error_categories": $(printf '%s\n' "${error_categories[@]}" 2>/dev/null | sort | uniq -c | jq -R 'split(" ") | {count: .[0], category: .[1]}' | jq -s . || echo "[]"),
    "analysis_timestamp": "$(get_timestamp)"
  }
}
EOF
    
    log_info "Log analysis completed: $analysis_report" "ANALYSIS"
    echo "$analysis_report"
}

# Cleanup old logs
cleanup_old_logs() {
    local retention_days="${1:-30}"
    
    log_info "Cleaning up logs older than $retention_days days" "CLEANUP"
    
    local cleaned_count=0
    
    # Clean up old log files
    while IFS= read -r -d '' log_file; do
        rm "$log_file"
        ((cleaned_count++))
    done < <(find "$LOGS_DIR" -name "*.log" -type f -mtime +$retention_days -print0 2>/dev/null)
    
    log_info "Cleaned up $cleaned_count old log files" "CLEANUP"
}

# Export logging functions for use in other scripts
export -f log_trace log_debug log_info log_warn log_error log_fatal
export -f log_system log_test log_audit log_performance
export -f trace_enter trace_exit trace_var
export -f init_logging analyze_logs cleanup_old_logs

# Initialize logging if this script is sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    init_logging
fi

# Main function for standalone execution
main() {
    case "${1:-init}" in
        "init")
            init_logging
            log_info "Logging system initialized successfully"
            ;;
        "analyze")
            analyze_logs "${2:-}" "${3:-}"
            ;;
        "cleanup")
            cleanup_old_logs "${2:-30}"
            ;;
        "test")
            # Test all logging functions
            init_logging
            log_trace "This is a trace message" "TEST"
            log_debug "This is a debug message" "TEST"
            log_info "This is an info message" "TEST"
            log_warn "This is a warning message" "TEST"
            log_error "This is an error message" "TEST"
            log_test "test-123" "Test message" "status=running"
            log_audit "test_start" "Started test execution" "user=$(whoami)"
            log_performance "test_execution" "45" "Test completed successfully"
            ;;
        *)
            echo "Usage: $0 {init|analyze|cleanup|test}"
            echo ""
            echo "Commands:"
            echo "  init                    Initialize logging system"
            echo "  analyze [start] [end]   Analyze logs between dates (YYYYMMDD)"
            echo "  cleanup [days]          Clean up logs older than specified days"
            echo "  test                    Test all logging functions"
            exit 1
            ;;
    esac
}

# Run main function if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi