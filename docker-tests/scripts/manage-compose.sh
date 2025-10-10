#!/bin/bash
# Docker Compose management script for ZigCat testing

set -e

COMPOSE_FILE="docker-compose.test.yml"
PROJECT_NAME="zigcat-test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check Docker and Docker Compose availability
check_requirements() {
    log "Checking requirements..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! docker compose version &> /dev/null; then
        error "Docker Compose is not available"
        exit 1
    fi
    
    if ! docker buildx version &> /dev/null; then
        warning "Docker Buildx is not available - multi-arch builds may not work"
    fi
    
    success "Requirements check passed"
}

# Function to setup the test environment
setup() {
    log "Setting up Docker Compose test environment..."
    
    # Ensure buildx is set up
    if [[ -f "docker-tests/scripts/setup-buildx.sh" ]]; then
        log "Setting up Docker Buildx..."
        bash docker-tests/scripts/setup-buildx.sh
    fi
    
    # Create necessary directories
    mkdir -p docker-tests/{scripts,configs,logs,results}
    
    success "Test environment setup complete"
}

# Function to build all services
build() {
    log "Building all test services..."
    
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" build \
        --parallel \
        --progress plain
    
    success "All services built successfully"
}

# Function to start the test environment
start() {
    log "Starting test environment..."
    
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d
    
    # Wait for services to be ready
    log "Waiting for services to be ready..."
    sleep 10
    
    # Check service status
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" ps
    
    success "Test environment started"
}

# Function to stop the test environment
stop() {
    log "Stopping test environment..."
    
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    
    success "Test environment stopped"
}

# Function to clean up everything
cleanup() {
    log "Cleaning up test environment..."
    
    # Stop and remove containers, networks, and volumes
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down \
        --volumes \
        --remove-orphans
    
    # Remove any dangling images
    docker image prune -f --filter "label=com.docker.compose.project=$PROJECT_NAME"
    
    success "Cleanup complete"
}

# Function to show logs
logs() {
    local service="${1:-}"
    
    if [[ -n "$service" ]]; then
        log "Showing logs for service: $service"
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs -f "$service"
    else
        log "Showing logs for all services"
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs -f
    fi
}

# Function to show status
status() {
    log "Test environment status:"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" ps
    
    log "Volume usage:"
    docker volume ls --filter "name=${PROJECT_NAME}"
    
    log "Network status:"
    docker network ls --filter "name=${PROJECT_NAME}"
}

# Function to execute command in a service
exec_service() {
    local service="$1"
    shift
    local cmd=("$@")
    
    if [[ -z "$service" ]]; then
        error "Service name required"
        exit 1
    fi
    
    log "Executing command in service: $service"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec "$service" "${cmd[@]}"
}

# Function to run a one-off command
run_service() {
    local service="$1"
    shift
    local cmd=("$@")
    
    if [[ -z "$service" ]]; then
        error "Service name required"
        exit 1
    fi
    
    log "Running one-off command in service: $service"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" run --rm "$service" "${cmd[@]}"
}

# Main command dispatcher
case "${1:-}" in
    "check")
        check_requirements
        ;;
    "setup")
        check_requirements
        setup
        ;;
    "build")
        check_requirements
        build
        ;;
    "start")
        check_requirements
        start
        ;;
    "stop")
        stop
        ;;
    "restart")
        stop
        start
        ;;
    "cleanup")
        cleanup
        ;;
    "logs")
        logs "$2"
        ;;
    "status")
        status
        ;;
    "exec")
        exec_service "$2" "${@:3}"
        ;;
    "run")
        run_service "$2" "${@:3}"
        ;;
    "full-cycle")
        check_requirements
        setup
        build
        start
        status
        ;;
    *)
        echo "Usage: $0 {check|setup|build|start|stop|restart|cleanup|logs|status|exec|run|full-cycle}"
        echo ""
        echo "Commands:"
        echo "  check       - Check system requirements"
        echo "  setup       - Set up test environment"
        echo "  build       - Build all Docker services"
        echo "  start       - Start test environment"
        echo "  stop        - Stop test environment"
        echo "  restart     - Restart test environment"
        echo "  cleanup     - Clean up all resources"
        echo "  logs [svc]  - Show logs (optionally for specific service)"
        echo "  status      - Show environment status"
        echo "  exec <svc> <cmd> - Execute command in running service"
        echo "  run <svc> <cmd>  - Run one-off command in service"
        echo "  full-cycle  - Run complete setup and start cycle"
        echo ""
        echo "Examples:"
        echo "  $0 full-cycle"
        echo "  $0 exec test-runner-linux /bin/bash"
        echo "  $0 logs builder-linux-amd64"
        exit 1
        ;;
esac