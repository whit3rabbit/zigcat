#!/bin/bash

# ZigCat Docker Test System - Resource Monitor
# Monitors resource usage and enforces limits during test execution

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source logging system
if [[ -f "$SCRIPT_DIR/logging-system.sh" ]]; then
    source "$SCRIPT_DIR/logging-system.sh"
fi

# Resource monitoring configuration
MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
CPU_LIMIT="${CPU_LIMIT:-80}"
MEMORY_LIMIT="${MEMORY_LIMIT:-80}"
DISK_LIMIT="${DISK_LIMIT:-90}"
CONTAINER_LIMIT="${CONTAINER_LIMIT:-20}"
NETWORK_LIMIT="${NETWORK_LIMIT:-10}"
VOLUME_LIMIT="${VOLUME_LIMIT:-50}"

# Monitoring state
MONITORING_ACTIVE=false
MONITOR_PID=""
RESOURCE_VIOLATIONS=0
MAX_VIOLATIONS=5

# Initialize resource monitoring
init_resource_monitoring() {
    log_info "Initializing resource monitoring" "RESOURCE_MONITOR" \
        "interval=${MONITOR_INTERVAL}s" \
        "cpu_limit=${CPU_LIMIT}%" \
        "memory_limit=${MEMORY_LIMIT}%" \
        "disk_limit=${DISK_LIMIT}%"
    
    # Create monitoring directory
    mkdir -p "$PROJECT_ROOT/docker-tests/monitoring"
    
    # Set up monitoring log
    local monitor_log="$PROJECT_ROOT/docker-tests/monitoring/resource-monitor-$(date +%Y%m%d).log"
    exec 3> "$monitor_log"
    
    log_success "Resource monitoring initialized" "RESOURCE_MONITOR"
}

# Start resource monitoring
start_monitoring() {
    if [[ "$MONITORING_ACTIVE" == "true" ]]; then
        log_warn "Resource monitoring already active" "RESOURCE_MONITOR"
        return 0
    fi
    
    log_info "Starting resource monitoring" "RESOURCE_MONITOR"
    
    # Start monitoring in background
    monitor_resources &
    MONITOR_PID=$!
    MONITORING_ACTIVE=true
    
    log_info "Resource monitoring started" "RESOURCE_MONITOR" "pid=$MONITOR_PID"
}

# Stop resource monitoring
stop_monitoring() {
    if [[ "$MONITORING_ACTIVE" == "false" ]]; then
        log_debug "Resource monitoring not active" "RESOURCE_MONITOR"
        return 0
    fi
    
    log_info "Stopping resource monitoring" "RESOURCE_MONITOR"
    
    if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -TERM "$MONITOR_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$MONITOR_PID" 2>/dev/null || true
    fi
    
    MONITORING_ACTIVE=false
    MONITOR_PID=""
    
    # Close monitoring log
    exec 3>&-
    
    log_success "Resource monitoring stopped" "RESOURCE_MONITOR"
}

# Main monitoring loop
monitor_resources() {
    local start_time
    start_time=$(date +%s)
    
    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Collect resource metrics
        local cpu_usage memory_usage disk_usage
        local container_count network_count volume_count
        
        # Get system resource usage
        cpu_usage=$(get_cpu_usage)
        memory_usage=$(get_memory_usage)
        disk_usage=$(get_disk_usage)
        
        # Get Docker resource usage
        container_count=$(get_container_count)
        network_count=$(get_network_count)
        volume_count=$(get_volume_count)
        
        # Log metrics
        {
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") METRICS cpu=$cpu_usage memory=$memory_usage disk=$disk_usage containers=$container_count networks=$network_count volumes=$volume_count elapsed=${elapsed}s"
        } >&3
        
        # Check for violations
        check_resource_limits "$cpu_usage" "$memory_usage" "$disk_usage" "$container_count" "$network_count" "$volume_count"
        
        # Sleep until next check
        sleep "$MONITOR_INTERVAL"
    done
}

# Get CPU usage percentage
get_cpu_usage() {
    if command -v top &> /dev/null; then
        # Use top command
        top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' 2>/dev/null || echo "0"
    elif [[ -f /proc/loadavg ]]; then
        # Use load average as approximation
        local load
        load=$(awk '{print $1}' /proc/loadavg)
        local cpu_count
        cpu_count=$(nproc 2>/dev/null || echo "1")
        echo "scale=0; $load * 100 / $cpu_count" | bc 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Get memory usage percentage
get_memory_usage() {
    if [[ -f /proc/meminfo ]]; then
        # Linux
        local total available
        total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
        available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
        if [[ -n "$total" && -n "$available" && "$total" -gt 0 ]]; then
            echo "scale=0; (($total - $available) * 100) / $total" | bc 2>/dev/null || echo "0"
        else
            echo "0"
        fi
    elif command -v vm_stat &> /dev/null; then
        # macOS
        local page_size total_pages free_pages
        page_size=$(vm_stat | grep "page size" | awk '{print $8}' || echo "4096")
        total_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//' || echo "0")
        free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//' || echo "0")
        if [[ "$total_pages" -gt 0 ]]; then
            echo "scale=0; (($total_pages - $free_pages) * 100) / $total_pages" | bc 2>/dev/null || echo "0"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Get disk usage percentage
get_disk_usage() {
    df . | awk 'NR==2 {print $5}' | sed 's/%//' 2>/dev/null || echo "0"
}

# Get Docker container count
get_container_count() {
    docker ps -a --filter "label=zigcat-test" --format "{{.ID}}" 2>/dev/null | wc -l | tr -d ' '
}

# Get Docker network count
get_network_count() {
    docker network ls --filter "name=zigcat-test" --format "{{.ID}}" 2>/dev/null | wc -l | tr -d ' '
}

# Get Docker volume count
get_volume_count() {
    docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" 2>/dev/null | wc -l | tr -d ' '
}

# Check resource limits and take action
check_resource_limits() {
    local cpu_usage="$1"
    local memory_usage="$2"
    local disk_usage="$3"
    local container_count="$4"
    local network_count="$5"
    local volume_count="$6"
    
    local violations=()
    
    # Check CPU limit
    if [[ $cpu_usage -gt $CPU_LIMIT ]]; then
        violations+=("CPU usage ${cpu_usage}% exceeds limit ${CPU_LIMIT}%")
    fi
    
    # Check memory limit
    if [[ $memory_usage -gt $MEMORY_LIMIT ]]; then
        violations+=("Memory usage ${memory_usage}% exceeds limit ${MEMORY_LIMIT}%")
    fi
    
    # Check disk limit
    if [[ $disk_usage -gt $DISK_LIMIT ]]; then
        violations+=("Disk usage ${disk_usage}% exceeds limit ${DISK_LIMIT}%")
    fi
    
    # Check container limit
    if [[ $container_count -gt $CONTAINER_LIMIT ]]; then
        violations+=("Container count $container_count exceeds limit $CONTAINER_LIMIT")
    fi
    
    # Check network limit
    if [[ $network_count -gt $NETWORK_LIMIT ]]; then
        violations+=("Network count $network_count exceeds limit $NETWORK_LIMIT")
    fi
    
    # Check volume limit
    if [[ $volume_count -gt $VOLUME_LIMIT ]]; then
        violations+=("Volume count $volume_count exceeds limit $VOLUME_LIMIT")
    fi
    
    # Handle violations
    if [[ ${#violations[@]} -gt 0 ]]; then
        RESOURCE_VIOLATIONS=$((RESOURCE_VIOLATIONS + 1))
        
        log_warn "Resource limit violations detected" "RESOURCE_MONITOR" \
            "violation_count=$RESOURCE_VIOLATIONS" \
            "max_violations=$MAX_VIOLATIONS"
        
        for violation in "${violations[@]}"; do
            log_warn "  - $violation" "RESOURCE_MONITOR"
        done
        
        # Take corrective action
        if [[ $RESOURCE_VIOLATIONS -ge $MAX_VIOLATIONS ]]; then
            log_error "Maximum resource violations exceeded, triggering cleanup" "RESOURCE_MONITOR"
            trigger_resource_cleanup
        else
            # Apply resource management
            apply_resource_management "$cpu_usage" "$memory_usage" "$disk_usage" "$container_count"
        fi
    else
        # Reset violation count on successful check
        if [[ $RESOURCE_VIOLATIONS -gt 0 ]]; then
            log_info "Resource usage back to normal" "RESOURCE_MONITOR"
            RESOURCE_VIOLATIONS=0
        fi
    fi
}

# Apply resource management strategies
apply_resource_management() {
    local cpu_usage="$1"
    local memory_usage="$2"
    local disk_usage="$3"
    local container_count="$4"
    
    log_info "Applying resource management strategies" "RESOURCE_MONITOR"
    
    # CPU management
    if [[ $cpu_usage -gt $CPU_LIMIT ]]; then
        log_info "Reducing CPU usage by limiting parallel operations" "RESOURCE_MONITOR"
        # Signal running processes to reduce parallelism
        pkill -USR1 -f "zigcat.*test" 2>/dev/null || true
    fi
    
    # Memory management
    if [[ $memory_usage -gt $MEMORY_LIMIT ]]; then
        log_info "Managing memory usage" "RESOURCE_MONITOR"
        # Clean up Docker system
        docker system prune -f >/dev/null 2>&1 || true
    fi
    
    # Disk management
    if [[ $disk_usage -gt $DISK_LIMIT ]]; then
        log_info "Managing disk usage" "RESOURCE_MONITOR"
        # Clean up old logs
        find "$PROJECT_ROOT/docker-tests/logs" -name "*.log" -type f -mtime +1 -delete 2>/dev/null || true
        # Clean up Docker volumes
        docker volume prune -f >/dev/null 2>&1 || true
    fi
    
    # Container management
    if [[ $container_count -gt $CONTAINER_LIMIT ]]; then
        log_info "Managing container count" "RESOURCE_MONITOR"
        # Remove exited containers
        docker ps -a --filter "status=exited" --filter "label=zigcat-test" -q | head -5 | xargs -r docker rm >/dev/null 2>&1 || true
    fi
}

# Trigger resource cleanup
trigger_resource_cleanup() {
    log_error "Triggering emergency resource cleanup" "RESOURCE_MONITOR"
    
    # Call cleanup manager
    if [[ -f "$SCRIPT_DIR/cleanup-manager.sh" ]]; then
        "$SCRIPT_DIR/cleanup-manager.sh" emergency --timeout 60 --force || true
    fi
    
    # Additional cleanup
    docker system prune -af --volumes >/dev/null 2>&1 || true
    
    # Reset violation count
    RESOURCE_VIOLATIONS=0
    
    log_info "Emergency resource cleanup completed" "RESOURCE_MONITOR"
}

# Generate resource usage report
generate_resource_report() {
    local report_file="$PROJECT_ROOT/docker-tests/monitoring/resource-report-$(date +%Y%m%d-%H%M%S).json"
    
    log_info "Generating resource usage report" "RESOURCE_MONITOR"
    
    # Get current metrics
    local cpu_usage memory_usage disk_usage
    local container_count network_count volume_count
    
    cpu_usage=$(get_cpu_usage)
    memory_usage=$(get_memory_usage)
    disk_usage=$(get_disk_usage)
    container_count=$(get_container_count)
    network_count=$(get_network_count)
    volume_count=$(get_volume_count)
    
    # Generate report
    cat > "$report_file" << EOF
{
  "resource_report": {
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "current_usage": {
      "cpu_percent": $cpu_usage,
      "memory_percent": $memory_usage,
      "disk_percent": $disk_usage,
      "container_count": $container_count,
      "network_count": $network_count,
      "volume_count": $volume_count
    },
    "limits": {
      "cpu_limit": $CPU_LIMIT,
      "memory_limit": $MEMORY_LIMIT,
      "disk_limit": $DISK_LIMIT,
      "container_limit": $CONTAINER_LIMIT,
      "network_limit": $NETWORK_LIMIT,
      "volume_limit": $VOLUME_LIMIT
    },
    "violations": {
      "total_violations": $RESOURCE_VIOLATIONS,
      "max_violations": $MAX_VIOLATIONS
    },
    "monitoring": {
      "active": $MONITORING_ACTIVE,
      "interval": $MONITOR_INTERVAL,
      "pid": "$MONITOR_PID"
    }
  }
}
EOF
    
    log_success "Resource report generated: $report_file" "RESOURCE_MONITOR"
    echo "$report_file"
}

# Show current resource status
show_resource_status() {
    log_info "Current Resource Status" "RESOURCE_MONITOR"
    
    local cpu_usage memory_usage disk_usage
    local container_count network_count volume_count
    
    cpu_usage=$(get_cpu_usage)
    memory_usage=$(get_memory_usage)
    disk_usage=$(get_disk_usage)
    container_count=$(get_container_count)
    network_count=$(get_network_count)
    volume_count=$(get_volume_count)
    
    echo "=== System Resources ==="
    echo "CPU Usage: ${cpu_usage}% (limit: ${CPU_LIMIT}%)"
    echo "Memory Usage: ${memory_usage}% (limit: ${MEMORY_LIMIT}%)"
    echo "Disk Usage: ${disk_usage}% (limit: ${DISK_LIMIT}%)"
    
    echo ""
    echo "=== Docker Resources ==="
    echo "Containers: $container_count (limit: $CONTAINER_LIMIT)"
    echo "Networks: $network_count (limit: $NETWORK_LIMIT)"
    echo "Volumes: $volume_count (limit: $VOLUME_LIMIT)"
    
    echo ""
    echo "=== Monitoring Status ==="
    echo "Active: $MONITORING_ACTIVE"
    echo "PID: ${MONITOR_PID:-N/A}"
    echo "Interval: ${MONITOR_INTERVAL}s"
    echo "Violations: $RESOURCE_VIOLATIONS/$MAX_VIOLATIONS"
}

# Cleanup monitoring resources
cleanup_monitoring() {
    log_info "Cleaning up monitoring resources" "RESOURCE_MONITOR"
    
    stop_monitoring
    
    # Clean up old monitoring files
    find "$PROJECT_ROOT/docker-tests/monitoring" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    find "$PROJECT_ROOT/docker-tests/monitoring" -name "*.json" -type f -mtime +7 -delete 2>/dev/null || true
    
    log_success "Monitoring cleanup completed" "RESOURCE_MONITOR"
}

# Signal handler for monitoring process
monitoring_signal_handler() {
    local signal="$1"
    log_info "Monitoring received signal: $signal" "RESOURCE_MONITOR"
    
    case "$signal" in
        "USR1")
            # Reduce resource usage
            log_info "Reducing resource usage on signal" "RESOURCE_MONITOR"
            apply_resource_management "100" "100" "100" "100"
            ;;
        "USR2")
            # Generate report
            generate_resource_report
            ;;
        *)
            # Cleanup and exit
            cleanup_monitoring
            exit 0
            ;;
    esac
}

# Main function
main() {
    case "${1:-status}" in
        "start")
            init_resource_monitoring
            start_monitoring
            ;;
        "stop")
            stop_monitoring
            ;;
        "status")
            show_resource_status
            ;;
        "report")
            generate_resource_report
            ;;
        "cleanup")
            cleanup_monitoring
            ;;
        "monitor")
            # Run monitoring in foreground
            init_resource_monitoring
            trap 'monitoring_signal_handler USR1' USR1
            trap 'monitoring_signal_handler USR2' USR2
            trap 'monitoring_signal_handler TERM' TERM INT
            monitor_resources
            ;;
        *)
            echo "Usage: $0 {start|stop|status|report|cleanup|monitor}"
            echo ""
            echo "Commands:"
            echo "  start    Start resource monitoring in background"
            echo "  stop     Stop resource monitoring"
            echo "  status   Show current resource status"
            echo "  report   Generate resource usage report"
            echo "  cleanup  Clean up monitoring resources"
            echo "  monitor  Run monitoring in foreground"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"