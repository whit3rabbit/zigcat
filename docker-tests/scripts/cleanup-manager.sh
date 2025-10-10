#!/bin/bash

# ZigCat Docker Test System - Cleanup and Resource Management
# Implements robust cleanup with signal handling, timeout management, and resource monitoring

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_COMPOSE_FILE="$PROJECT_ROOT/docker-compose.test.yml"
RESULTS_DIR="$PROJECT_ROOT/docker-tests/results"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="zigcat-test"
CLEANUP_TIMEOUT=30
FORCE_CLEANUP=false
VERBOSE=false
DRY_RUN=false
PRESERVE_LOGS=true
PRESERVE_ARTIFACTS=false
EMERGENCY_MODE=false

# Process tracking
CLEANUP_PIDS=""
ACTIVE_CONTAINERS=""
STUCK_CONTAINERS=""
RESOURCE_LEAKS=""

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

ZigCat Docker Test System - Cleanup and Resource Management

COMMANDS:
    cleanup                     Perform standard cleanup
    emergency                   Emergency cleanup for stuck resources
    verify                      Verify cleanup completeness
    monitor                     Monitor resource usage
    status                      Show current resource status

OPTIONS:
    -t, --timeout SECONDS       Cleanup timeout in seconds (default: 30)
    -f, --force                 Force cleanup even if containers are running
    -v, --verbose               Enable verbose logging
    -n, --dry-run               Show what would be done without executing
    --preserve-logs             Keep log files (default: true)
    --preserve-artifacts        Keep build artifacts (default: false)
    --emergency                 Enable emergency cleanup mode
    -h, --help                  Show this help message

EXAMPLES:
    $0 cleanup                  # Standard cleanup
    $0 emergency                # Emergency cleanup for stuck resources
    $0 -f -t 60 cleanup         # Force cleanup with 60s timeout
    $0 --dry-run cleanup        # Show what would be cleaned up
    $0 monitor                  # Monitor current resource usage

EOF
}

# Parse command-line arguments
parse_args() {
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--timeout)
                CLEANUP_TIMEOUT="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_CLEANUP=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --preserve-logs)
                PRESERVE_LOGS=true
                shift
                ;;
            --preserve-artifacts)
                PRESERVE_ARTIFACTS=true
                shift
                ;;
            --emergency)
                EMERGENCY_MODE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            cleanup|emergency|verify|monitor|status)
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
    
    # Default to cleanup if no command specified
    if [[ -z "$command" ]]; then
        command="cleanup"
    fi
    
    echo "$command"
}

# Signal handler for graceful shutdown
signal_handler() {
    local signal="$1"
    log_warn "Received signal $signal, initiating graceful cleanup shutdown..."
    
    # Kill any background cleanup processes
    if [[ ${#CLEANUP_PIDS[@]} -gt 0 ]]; then
        log_debug "Terminating ${#CLEANUP_PIDS[@]} background cleanup processes"
        for pid in "${CLEANUP_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
    fi
    
    # Perform emergency cleanup if needed
    if [[ "$EMERGENCY_MODE" == "true" ]]; then
        emergency_cleanup
    fi
    
    exit 130
}

# Timeout handler for cleanup operations
timeout_handler() {
    log_error "Cleanup timeout of ${CLEANUP_TIMEOUT}s exceeded"
    
    # Switch to emergency mode
    EMERGENCY_MODE=true
    FORCE_CLEANUP=true
    
    log_warn "Switching to emergency cleanup mode"
    emergency_cleanup
    
    exit 124
}

# Discover active containers related to zigcat testing
discover_active_containers() {
    log_debug "Discovering active containers..."
    
    ACTIVE_CONTAINERS=()
    
    # Find containers by project name
    while IFS= read -r container_id; do
        if [[ -n "$container_id" ]]; then
            ACTIVE_CONTAINERS+=("$container_id")
        fi
    done < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null || true)
    
    # Find containers by name pattern
    while IFS= read -r container_id; do
        if [[ -n "$container_id" ]]; then
            # Check if already in array
            local found=false
            for existing in "${ACTIVE_CONTAINERS[@]}"; do
                if [[ "$existing" == "$container_id" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                ACTIVE_CONTAINERS+=("$container_id")
            fi
        fi
    done < <(docker ps -q --filter "name=zigcat-test" 2>/dev/null || true)
    
    # Find containers by label
    while IFS= read -r container_id; do
        if [[ -n "$container_id" ]]; then
            # Check if already in array
            local found=false
            for existing in "${ACTIVE_CONTAINERS[@]}"; do
                if [[ "$existing" == "$container_id" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                ACTIVE_CONTAINERS+=("$container_id")
            fi
        fi
    done < <(docker ps -q --filter "label=zigcat-test" 2>/dev/null || true)
    
    log_debug "Found ${#ACTIVE_CONTAINERS[@]} active containers"
    
    if [[ "$VERBOSE" == "true" && ${#ACTIVE_CONTAINERS[@]} -gt 0 ]]; then
        log_debug "Active containers: ${ACTIVE_CONTAINERS[*]}"
    fi
}

# Check for stuck containers that won't respond to normal shutdown
detect_stuck_containers() {
    log_debug "Detecting stuck containers..."
    
    STUCK_CONTAINERS=()
    
    for container_id in "${ACTIVE_CONTAINERS[@]}"; do
        # Check if container is responsive
        if ! timeout 5 docker exec "$container_id" echo "health-check" >/dev/null 2>&1; then
            # Check if container is in a problematic state
            local state
            state=$(docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
            
            if [[ "$state" == "restarting" || "$state" == "dead" || "$state" == "unknown" ]]; then
                STUCK_CONTAINERS+=("$container_id")
                log_debug "Detected stuck container: $container_id (state: $state)"
            fi
        fi
    done
    
    if [[ ${#STUCK_CONTAINERS[@]} -gt 0 ]]; then
        log_warn "Found ${#STUCK_CONTAINERS[@]} stuck containers"
    fi
}

# Gracefully stop containers with timeout
graceful_container_stop() {
    local containers=("$@")
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        log_debug "No containers to stop"
        return 0
    fi
    
    log_info "Gracefully stopping ${#containers[@]} containers..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would stop containers: ${containers[*]}"
        return 0
    fi
    
    # Send SIGTERM to all containers
    for container_id in "${containers[@]}"; do
        log_debug "Sending SIGTERM to container: $container_id"
        docker stop --time=10 "$container_id" >/dev/null 2>&1 &
        CLEANUP_PIDS+=($!)
    done
    
    # Wait for graceful shutdown with timeout
    local wait_start
    wait_start=$(date +%s)
    local max_wait=$((CLEANUP_TIMEOUT / 2))
    
    while [[ ${#CLEANUP_PIDS[@]} -gt 0 ]]; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - wait_start))
        
        if [[ $elapsed -gt $max_wait ]]; then
            log_warn "Graceful stop timeout exceeded, proceeding to force stop"
            break
        fi
        
        # Check if any processes have completed
        local new_pids=()
        for pid in "${CLEANUP_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            fi
        done
        CLEANUP_PIDS=("${new_pids[@]}")
        
        if [[ ${#CLEANUP_PIDS[@]} -gt 0 ]]; then
            sleep 1
        fi
    done
    
    # Force stop any remaining containers
    local remaining_containers=()
    for container_id in "${containers[@]}"; do
        if docker ps -q --filter "id=$container_id" | grep -q "$container_id"; then
            remaining_containers+=("$container_id")
        fi
    done
    
    if [[ ${#remaining_containers[@]} -gt 0 ]]; then
        log_warn "Force stopping ${#remaining_containers[@]} remaining containers"
        for container_id in "${remaining_containers[@]}"; do
            docker kill "$container_id" >/dev/null 2>&1 || true
        done
    fi
    
    log_success "Container stop completed"
}

# Remove containers and associated resources
remove_containers() {
    local containers=("$@")
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        log_debug "No containers to remove"
        return 0
    fi
    
    log_info "Removing ${#containers[@]} containers..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would remove containers: ${containers[*]}"
        return 0
    fi
    
    for container_id in "${containers[@]}"; do
        log_debug "Removing container: $container_id"
        docker rm -f "$container_id" >/dev/null 2>&1 || true
    done
    
    log_success "Container removal completed"
}

# Clean up Docker Compose resources
cleanup_compose_resources() {
    log_info "Cleaning up Docker Compose resources..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would clean up Docker Compose resources"
        return 0
    fi
    
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        log_debug "Using Docker Compose file: $DOCKER_COMPOSE_FILE"
        
        # Try graceful compose down first
        if timeout "$CLEANUP_TIMEOUT" docker-compose -f "$DOCKER_COMPOSE_FILE" -p "$PROJECT_NAME" down --volumes --remove-orphans >/dev/null 2>&1; then
            log_success "Docker Compose cleanup completed successfully"
        else
            log_warn "Docker Compose cleanup timed out or failed, proceeding with manual cleanup"
            
            # Manual cleanup of compose resources
            docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker rm -f >/dev/null 2>&1 || true
            docker network ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
            docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
        fi
    else
        log_debug "Docker Compose file not found, skipping compose cleanup"
    fi
}

# Clean up networks
cleanup_networks() {
    log_info "Cleaning up test networks..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would clean up networks"
        return 0
    fi
    
    # Remove networks by name pattern
    docker network ls --filter "name=zigcat-test" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
    
    # Remove networks by project label
    docker network ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
    
    log_success "Network cleanup completed"
}

# Clean up volumes
cleanup_volumes() {
    log_info "Cleaning up test volumes..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would clean up volumes"
        return 0
    fi
    
    # Remove volumes by name pattern
    docker volume ls --filter "name=zigcat-test" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    
    # Remove volumes by project label
    docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    
    # Remove volumes by zigcat-test label
    docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    
    log_success "Volume cleanup completed"
}

# Clean up images
cleanup_images() {
    log_info "Cleaning up test images..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would clean up images"
        return 0
    fi
    
    # Remove images by project label
    docker image ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker image rm -f >/dev/null 2>&1 || true
    
    # Remove dangling images
    docker image prune -f --filter "label=zigcat-test" >/dev/null 2>&1 || true
    
    log_success "Image cleanup completed"
}

# Clean up file system resources
cleanup_filesystem() {
    log_info "Cleaning up file system resources..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would clean up file system resources"
        return 0
    fi
    
    # Clean up temporary files
    find /tmp -name "zigcat-test-*" -type f -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "docker-compose-*zigcat*" -type f -mtime +1 -delete 2>/dev/null || true
    
    # Clean up artifacts if not preserving
    if [[ "$PRESERVE_ARTIFACTS" == "false" && -d "$ARTIFACTS_DIR" ]]; then
        log_debug "Removing build artifacts directory: $ARTIFACTS_DIR"
        rm -rf "$ARTIFACTS_DIR"/*
    fi
    
    # Clean up old logs if not preserving
    if [[ "$PRESERVE_LOGS" == "false" && -d "$LOGS_DIR" ]]; then
        log_debug "Removing log files directory: $LOGS_DIR"
        rm -rf "$LOGS_DIR"/*
    else
        # Clean up old log files (older than 7 days)
        find "$LOGS_DIR" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    fi
    
    # Clean up old result files
    if [[ -d "$RESULTS_DIR" ]]; then
        find "$RESULTS_DIR" -name "test-report-*.json" -type f -mtime +7 -delete 2>/dev/null || true
    fi
    
    log_success "File system cleanup completed"
}

# Detect resource leaks
detect_resource_leaks() {
    log_debug "Detecting resource leaks..."
    
    RESOURCE_LEAKS=()
    
    # Check for orphaned containers
    local orphaned_containers
    orphaned_containers=$(docker ps -a --filter "label=zigcat-test" --filter "status=exited" --format "{{.ID}}" | wc -l)
    if [[ $orphaned_containers -gt 0 ]]; then
        RESOURCE_LEAKS+=("$orphaned_containers orphaned containers")
    fi
    
    # Check for unused networks
    local unused_networks
    unused_networks=$(docker network ls --filter "name=zigcat-test" --format "{{.ID}}" | wc -l)
    if [[ $unused_networks -gt 0 ]]; then
        RESOURCE_LEAKS+=("$unused_networks unused networks")
    fi
    
    # Check for unused volumes
    local unused_volumes
    unused_volumes=$(docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" | wc -l)
    if [[ $unused_volumes -gt 0 ]]; then
        RESOURCE_LEAKS+=("$unused_volumes unused volumes")
    fi
    
    # Check for large log files
    if [[ -d "$LOGS_DIR" ]]; then
        local large_logs
        large_logs=$(find "$LOGS_DIR" -name "*.log" -size +100M | wc -l)
        if [[ $large_logs -gt 0 ]]; then
            RESOURCE_LEAKS+=("$large_logs large log files (>100MB)")
        fi
    fi
    
    if [[ ${#RESOURCE_LEAKS[@]} -gt 0 ]]; then
        log_warn "Detected resource leaks: ${RESOURCE_LEAKS[*]}"
    else
        log_debug "No resource leaks detected"
    fi
}

# Emergency cleanup for stuck resources
emergency_cleanup() {
    log_warn "Initiating emergency cleanup procedures..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would perform emergency cleanup"
        return 0
    fi
    
    # Force kill all zigcat-related containers
    log_info "Force killing all zigcat-related containers..."
    docker ps -a --filter "name=zigcat" --format "{{.ID}}" | xargs -r docker kill >/dev/null 2>&1 || true
    docker ps -a --filter "label=zigcat-test" --format "{{.ID}}" | xargs -r docker kill >/dev/null 2>&1 || true
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker kill >/dev/null 2>&1 || true
    
    # Force remove all containers
    log_info "Force removing all zigcat-related containers..."
    docker ps -a --filter "name=zigcat" --format "{{.ID}}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -a --filter "label=zigcat-test" --format "{{.ID}}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    
    # Force remove networks
    log_info "Force removing all zigcat-related networks..."
    docker network ls --filter "name=zigcat" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
    docker network ls --filter "label=zigcat-test" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
    docker network ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.ID}}" | xargs -r docker network rm >/dev/null 2>&1 || true
    
    # Force remove volumes
    log_info "Force removing all zigcat-related volumes..."
    docker volume ls --filter "name=zigcat" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Name}}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    
    # System-wide Docker cleanup
    log_info "Performing system-wide Docker cleanup..."
    docker system prune -f --volumes >/dev/null 2>&1 || true
    
    log_success "Emergency cleanup completed"
}

# Verify cleanup completeness
verify_cleanup() {
    log_info "Verifying cleanup completeness..."
    
    local issues=()
    
    # Check for remaining containers
    local remaining_containers
    remaining_containers=$(docker ps -a --filter "label=zigcat-test" --format "{{.ID}}" | wc -l)
    if [[ $remaining_containers -gt 0 ]]; then
        issues+=("$remaining_containers containers still exist")
    fi
    
    # Check for remaining networks
    local remaining_networks
    remaining_networks=$(docker network ls --filter "name=zigcat-test" --format "{{.ID}}" | wc -l)
    if [[ $remaining_networks -gt 0 ]]; then
        issues+=("$remaining_networks networks still exist")
    fi
    
    # Check for remaining volumes
    local remaining_volumes
    remaining_volumes=$(docker volume ls --filter "label=zigcat-test" --format "{{.Name}}" | wc -l)
    if [[ $remaining_volumes -gt 0 ]]; then
        issues+=("$remaining_volumes volumes still exist")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_error "Cleanup verification failed: ${issues[*]}"
        return 1
    else
        log_success "Cleanup verification passed - all resources cleaned up"
        return 0
    fi
}

# Monitor resource usage
monitor_resources() {
    log_info "Monitoring Docker resource usage..."
    
    echo "=== Docker System Information ==="
    docker system df
    
    echo ""
    echo "=== ZigCat Test Containers ==="
    docker ps -a --filter "label=zigcat-test" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Size}}"
    
    echo ""
    echo "=== ZigCat Test Networks ==="
    docker network ls --filter "name=zigcat-test" --format "table {{.ID}}\t{{.Name}}\t{{.Driver}}\t{{.Scope}}"
    
    echo ""
    echo "=== ZigCat Test Volumes ==="
    docker volume ls --filter "label=zigcat-test" --format "table {{.Name}}\t{{.Driver}}\t{{.Size}}"
    
    echo ""
    echo "=== File System Usage ==="
    if [[ -d "$LOGS_DIR" ]]; then
        echo "Logs directory: $(du -sh "$LOGS_DIR" 2>/dev/null || echo "N/A")"
    fi
    if [[ -d "$ARTIFACTS_DIR" ]]; then
        echo "Artifacts directory: $(du -sh "$ARTIFACTS_DIR" 2>/dev/null || echo "N/A")"
    fi
    if [[ -d "$RESULTS_DIR" ]]; then
        echo "Results directory: $(du -sh "$RESULTS_DIR" 2>/dev/null || echo "N/A")"
    fi
}

# Show current status
show_status() {
    log_info "ZigCat Docker Test System Status"
    
    echo "=== Configuration ==="
    echo "Project Name: $PROJECT_NAME"
    echo "Cleanup Timeout: ${CLEANUP_TIMEOUT}s"
    echo "Force Cleanup: $FORCE_CLEANUP"
    echo "Emergency Mode: $EMERGENCY_MODE"
    echo "Preserve Logs: $PRESERVE_LOGS"
    echo "Preserve Artifacts: $PRESERVE_ARTIFACTS"
    
    echo ""
    discover_active_containers
    detect_stuck_containers
    detect_resource_leaks
    
    echo "=== Resource Summary ==="
    echo "Active Containers: ${#ACTIVE_CONTAINERS[@]}"
    echo "Stuck Containers: ${#STUCK_CONTAINERS[@]}"
    echo "Resource Leaks: ${#RESOURCE_LEAKS[@]}"
    
    if [[ ${#ACTIVE_CONTAINERS[@]} -gt 0 ]]; then
        echo ""
        echo "=== Active Containers ==="
        for container_id in "${ACTIVE_CONTAINERS[@]}"; do
            local name status
            name=$(docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || echo "unknown")
            status=$(docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
            echo "  $container_id ($name) - $status"
        done
    fi
    
    if [[ ${#RESOURCE_LEAKS[@]} -gt 0 ]]; then
        echo ""
        echo "=== Resource Leaks ==="
        for leak in "${RESOURCE_LEAKS[@]}"; do
            echo "  - $leak"
        done
    fi
}

# Standard cleanup procedure
standard_cleanup() {
    log_info "Starting standard cleanup procedure..."
    
    # Set up timeout handler
    (
        sleep "$CLEANUP_TIMEOUT"
        timeout_handler
    ) &
    local timeout_pid=$!
    CLEANUP_PIDS+=($timeout_pid)
    
    # Discover resources
    discover_active_containers
    detect_stuck_containers
    
    # Check if force cleanup is needed
    if [[ ${#ACTIVE_CONTAINERS[@]} -gt 0 && "$FORCE_CLEANUP" == "false" ]]; then
        log_error "Active containers found but force cleanup not enabled"
        log_info "Use --force to cleanup active containers"
        kill $timeout_pid 2>/dev/null || true
        return 1
    fi
    
    # Perform cleanup steps
    if [[ ${#STUCK_CONTAINERS[@]} -gt 0 ]]; then
        log_warn "Stuck containers detected, using emergency procedures"
        emergency_cleanup
    else
        # Standard cleanup sequence
        graceful_container_stop "${ACTIVE_CONTAINERS[@]}"
        remove_containers "${ACTIVE_CONTAINERS[@]}"
        cleanup_compose_resources
        cleanup_networks
        cleanup_volumes
        cleanup_images
        cleanup_filesystem
    fi
    
    # Kill timeout handler
    kill $timeout_pid 2>/dev/null || true
    
    # Verify cleanup
    if verify_cleanup; then
        log_success "Standard cleanup completed successfully"
        return 0
    else
        log_error "Standard cleanup verification failed"
        return 1
    fi
}

# Main function
main() {
    local command
    command=$(parse_args "$@")
    
    # Set up signal handlers
    trap 'signal_handler SIGINT' SIGINT
    trap 'signal_handler SIGTERM' SIGTERM
    
    log_info "ZigCat Docker Test System - Cleanup Manager"
    log_info "Command: $command"
    log_info "Timeout: ${CLEANUP_TIMEOUT}s"
    
    case "$command" in
        "cleanup")
            standard_cleanup
            ;;
        "emergency")
            EMERGENCY_MODE=true
            FORCE_CLEANUP=true
            emergency_cleanup
            verify_cleanup
            ;;
        "verify")
            verify_cleanup
            ;;
        "monitor")
            monitor_resources
            ;;
        "status")
            show_status
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