#!/bin/bash

# ZigCat Test Orchestration Script
# Orchestrates test execution across multiple platforms and architectures
# Manages Docker containers and collects results

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_TESTS_DIR="${PROJECT_ROOT}/docker-tests"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.test.yml"

# Default configuration
PLATFORMS="${PLATFORMS:-linux,alpine}"
ARCHITECTURES="${ARCHITECTURES:-amd64}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
PARALLEL="${PARALLEL:-false}"
VERBOSE="${VERBOSE:-false}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

# Test execution tracking
declare -A platform_results
declare -A platform_durations
total_platforms=0
passed_platforms=0
failed_platforms=0

# Cleanup function
cleanup() {
    local exit_code=$?
    
    log_info "Cleaning up test environment..."
    
    if [[ "${KEEP_CONTAINERS}" != "true" ]]; then
        # Stop and remove containers
        docker-compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans 2>/dev/null || true
        
        # Clean up any remaining containers
        docker ps -a --filter "label=com.docker.compose.project=zigcat-test" -q | xargs -r docker rm -f 2>/dev/null || true
        
        # Clean up networks
        docker network ls --filter "name=zigcat" -q | xargs -r docker network rm 2>/dev/null || true
    else
        log_info "Keeping containers for debugging (--keep-containers specified)"
    fi
    
    # Generate final report
    generate_final_report
    
    exit ${exit_code}
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Initialize test environment
init_test_environment() {
    log_info "Initializing Docker test environment..."
    
    # Verify Docker and Docker Compose are available
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1; then
        log_error "Docker Compose is not installed or not in PATH"
        return 1
    fi
    
    # Verify compose file exists
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        log_error "Docker Compose file not found: ${COMPOSE_FILE}"
        return 1
    fi
    
    # Create results directory
    mkdir -p "${DOCKER_TESTS_DIR}/results"
    
    # Clean up any existing containers
    docker-compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans 2>/dev/null || true
    
    log_success "Test environment initialized"
}

# Build containers for specified platforms
build_containers() {
    local platforms_array
    IFS=',' read -ra platforms_array <<< "${PLATFORMS}"
    
    log_info "Building containers for platforms: ${PLATFORMS}"
    
    for platform in "${platforms_array[@]}"; do
        local architectures_array
        IFS=',' read -ra architectures_array <<< "${ARCHITECTURES}"
        
        for arch in "${architectures_array[@]}"; do
            local service_name="builder-${platform}-${arch}"
            
            log_info "Building ${service_name}..."
            
            if docker-compose -f "${COMPOSE_FILE}" build "${service_name}"; then
                log_success "Built ${service_name}"
            else
                log_error "Failed to build ${service_name}"
                return 1
            fi
        done
    done
}

# Start test runtime containers
start_test_containers() {
    local platforms_array
    IFS=',' read -ra platforms_array <<< "${PLATFORMS}"
    
    log_info "Starting test runtime containers..."
    
    for platform in "${platforms_array[@]}"; do
        local service_name="test-runner-${platform}"
        
        log_info "Starting ${service_name}..."
        
        if docker-compose -f "${COMPOSE_FILE}" up -d "${service_name}"; then
            log_success "Started ${service_name}"
        else
            log_error "Failed to start ${service_name}"
            return 1
        fi
    done
    
    # Wait for containers to be ready
    log_info "Waiting for containers to be ready..."
    sleep 5
}

# Execute tests on a specific platform
execute_platform_tests() {
    local platform="$1"
    local arch="$2"
    local container_name="zigcat-test_test-runner-${platform}_1"
    local start_time
    local end_time
    local duration
    local exit_code
    
    log_info "Executing tests for ${platform}-${arch}..."
    
    start_time=$(date +%s.%N)
    
    # Execute tests in container using the platform test runner
    set +e
    if [[ "${VERBOSE}" == "true" ]]; then
        docker exec -e TEST_PLATFORM="${platform}" -e TEST_ARCH="${arch}" -e VERBOSE=true \
            "${container_name}" /test-scripts/run-platform-tests.sh
        exit_code=$?
    else
        docker exec -e TEST_PLATFORM="${platform}" -e TEST_ARCH="${arch}" \
            "${container_name}" /test-scripts/run-platform-tests.sh >/dev/null 2>&1
        exit_code=$?
    fi
    set -e
    
    end_time=$(date +%s.%N)
    duration=$(echo "${end_time} - ${start_time}" | bc -l)
    
    # Store results
    platform_results["${platform}-${arch}"]=${exit_code}
    platform_durations["${platform}-${arch}"]=${duration}
    
    ((total_platforms++))
    
    if [[ ${exit_code} -eq 0 ]]; then
        ((passed_platforms++))
        log_success "Tests passed for ${platform}-${arch} (${duration}s)"
    else
        ((failed_platforms++))
        log_error "Tests failed for ${platform}-${arch} with exit code ${exit_code}"
        
        # Copy test results for debugging
        docker cp "${container_name}:/test-results/" "${DOCKER_TESTS_DIR}/results/${platform}-${arch}-results" 2>/dev/null || true
        docker cp "${container_name}:/test-logs/" "${DOCKER_TESTS_DIR}/results/${platform}-${arch}-logs" 2>/dev/null || true
    fi
    
    return ${exit_code}
}

# Execute tests in parallel
execute_tests_parallel() {
    local platforms_array
    IFS=',' read -ra platforms_array <<< "${PLATFORMS}"
    local architectures_array
    IFS=',' read -ra architectures_array <<< "${ARCHITECTURES}"
    
    local pids=()
    
    log_info "Executing tests in parallel..."
    
    for platform in "${platforms_array[@]}"; do
        for arch in "${architectures_array[@]}"; do
            # Skip unsupported combinations
            if [[ "${platform}" == "freebsd" && "${arch}" == "arm64" ]]; then
                log_warn "Skipping unsupported combination: ${platform}-${arch}"
                continue
            fi
            
            execute_platform_tests "${platform}" "${arch}" &
            pids+=($!)
        done
    done
    
    # Wait for all tests to complete
    local overall_exit_code=0
    for pid in "${pids[@]}"; do
        if ! wait "${pid}"; then
            overall_exit_code=1
        fi
    done
    
    return ${overall_exit_code}
}

# Execute tests sequentially
execute_tests_sequential() {
    local platforms_array
    IFS=',' read -ra platforms_array <<< "${PLATFORMS}"
    local architectures_array
    IFS=',' read -ra architectures_array <<< "${ARCHITECTURES}"
    
    local overall_exit_code=0
    
    log_info "Executing tests sequentially..."
    
    for platform in "${platforms_array[@]}"; do
        for arch in "${architectures_array[@]}"; do
            # Skip unsupported combinations
            if [[ "${platform}" == "freebsd" && "${arch}" == "arm64" ]]; then
                log_warn "Skipping unsupported combination: ${platform}-${arch}"
                continue
            fi
            
            if ! execute_platform_tests "${platform}" "${arch}"; then
                overall_exit_code=1
            fi
        done
    done
    
    return ${overall_exit_code}
}

# Collect test results from all containers
collect_test_results() {
    local platforms_array
    IFS=',' read -ra platforms_array <<< "${PLATFORMS}"
    local architectures_array
    IFS=',' read -ra architectures_array <<< "${ARCHITECTURES}"
    
    log_info "Collecting test results..."
    
    for platform in "${platforms_array[@]}"; do
        for arch in "${architectures_array[@]}"; do
            local container_name="zigcat-test_test-runner-${platform}_1"
            local result_dir="${DOCKER_TESTS_DIR}/results/${platform}-${arch}"
            
            # Skip if combination wasn't tested
            if [[ "${platform}" == "freebsd" && "${arch}" == "arm64" ]]; then
                continue
            fi
            
            mkdir -p "${result_dir}"
            
            # Copy test results
            docker cp "${container_name}:/test-results/" "${result_dir}/" 2>/dev/null || {
                log_warn "Failed to copy test results from ${container_name}"
            }
            
            # Copy test logs
            docker cp "${container_name}:/test-logs/" "${result_dir}/" 2>/dev/null || {
                log_warn "Failed to copy test logs from ${container_name}"
            }
            
            # Copy build artifacts
            docker cp "${container_name}:/artifacts/" "${result_dir}/" 2>/dev/null || {
                log_warn "Failed to copy artifacts from ${container_name}"
            }
        done
    done
    
    log_success "Test results collected in ${DOCKER_TESTS_DIR}/results/"
}

# Generate final test report
generate_final_report() {
    local report_file="${DOCKER_TESTS_DIR}/results/final-report.json"
    local summary_file="${DOCKER_TESTS_DIR}/results/test-summary.txt"
    
    log_info "Generating final test report..."
    
    # JSON report
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"configuration\": {"
        echo "    \"platforms\": \"${PLATFORMS}\","
        echo "    \"architectures\": \"${ARCHITECTURES}\","
        echo "    \"parallel\": ${PARALLEL},"
        echo "    \"timeout\": ${TEST_TIMEOUT}"
        echo "  },"
        echo "  \"summary\": {"
        echo "    \"total_platforms\": ${total_platforms},"
        echo "    \"passed_platforms\": ${passed_platforms},"
        echo "    \"failed_platforms\": ${failed_platforms}"
        echo "  },"
        echo "  \"platform_results\": {"
        
        local first=true
        for platform_arch in "${!platform_results[@]}"; do
            if [[ "${first}" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            
            local status="failed"
            if [[ "${platform_results[${platform_arch}]}" -eq 0 ]]; then
                status="passed"
            fi
            
            echo -n "    \"${platform_arch}\": {"
            echo -n "\"status\": \"${status}\", "
            echo -n "\"exit_code\": ${platform_results[${platform_arch}]}, "
            echo -n "\"duration\": ${platform_durations[${platform_arch}]}"
            echo -n "}"
        done
        
        echo
        echo "  }"
        echo "}"
    } > "${report_file}"
    
    # Human-readable summary
    {
        echo "ZigCat Multi-Platform Test Results"
        echo "=================================="
        echo "Timestamp: $(date)"
        echo "Platforms: ${PLATFORMS}"
        echo "Architectures: ${ARCHITECTURES}"
        echo "Parallel execution: ${PARALLEL}"
        echo
        echo "Summary:"
        echo "  Total platform combinations: ${total_platforms}"
        echo "  Passed: ${passed_platforms}"
        echo "  Failed: ${failed_platforms}"
        echo
        
        if [[ ${failed_platforms} -gt 0 ]]; then
            echo "Failed platforms:"
            for platform_arch in "${!platform_results[@]}"; do
                if [[ "${platform_results[${platform_arch}]}" -ne 0 ]]; then
                    echo "  - ${platform_arch} (exit code: ${platform_results[${platform_arch}]})"
                fi
            done
            echo
        fi
        
        echo "Detailed results available in: ${DOCKER_TESTS_DIR}/results/"
        
    } > "${summary_file}"
    
    log_success "Final report generated: ${report_file}"
    log_success "Test summary generated: ${summary_file}"
}

# Print usage information
print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --platforms PLATFORMS      Comma-separated list of platforms (linux,alpine,freebsd)
  --architectures ARCHS      Comma-separated list of architectures (amd64,arm64)
  --timeout SECONDS          Test timeout per platform (default: 300)
  --parallel                 Execute tests in parallel
  --verbose                  Enable verbose output
  --keep-containers          Keep containers after tests for debugging
  --help                     Show this help

Examples:
  $0 --platforms linux,alpine --architectures amd64
  $0 --platforms linux --architectures amd64,arm64 --parallel
  $0 --platforms freebsd --verbose --keep-containers

EOF
}

# Run binary validation tests
run_binary_validation_tests() {
    log_info "Executing binary validation tests..."
    
    local validation_args=(
        --platforms "${PLATFORMS}"
        --architectures "${ARCHITECTURES}"
        --timeout "${TEST_TIMEOUT}"
        --output-dir "${DOCKER_TESTS_DIR}/results"
    )
    
    if [[ "${VERBOSE}" == "true" ]]; then
        validation_args+=(--verbose)
    fi
    
    if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
        validation_args+=(--keep-logs)
    fi
    
    if [[ "${PARALLEL}" == "true" ]]; then
        validation_args+=(--parallel)
    fi
    
    if "${SCRIPT_DIR}/run-binary-validation.sh" "${validation_args[@]}"; then
        log_success "Binary validation tests completed successfully"
        return 0
    else
        log_error "Binary validation tests failed"
        return 1
    fi
}

# Main execution function
main() {
    log_info "Starting ZigCat multi-platform test orchestration"
    log_info "Platforms: ${PLATFORMS}"
    log_info "Architectures: ${ARCHITECTURES}"
    log_info "Parallel execution: ${PARALLEL}"
    
    # Initialize environment
    if ! init_test_environment; then
        log_error "Failed to initialize test environment"
        exit 1
    fi
    
    # Build containers
    if ! build_containers; then
        log_error "Failed to build containers"
        exit 1
    fi
    
    # Run binary validation tests
    log_info "Running binary validation tests..."
    if ! run_binary_validation_tests; then
        log_error "Binary validation tests failed"
        exit 1
    fi
    
    # Start test containers
    if ! start_test_containers; then
        log_error "Failed to start test containers"
        exit 1
    fi
    
    # Execute tests
    local test_exit_code=0
    if [[ "${PARALLEL}" == "true" ]]; then
        if ! execute_tests_parallel; then
            test_exit_code=1
        fi
    else
        if ! execute_tests_sequential; then
            test_exit_code=1
        fi
    fi
    
    # Collect results
    collect_test_results
    
    # Print summary
    echo
    log_info "Test orchestration completed"
    log_info "Total platforms: ${total_platforms}, Passed: ${passed_platforms}, Failed: ${failed_platforms}"
    
    if [[ ${failed_platforms} -gt 0 ]]; then
        log_error "Some platform tests failed"
        exit 1
    else
        log_success "All platform tests passed"
        exit 0
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --platforms)
            PLATFORMS="$2"
            shift 2
            ;;
        --architectures)
            ARCHITECTURES="$2"
            shift 2
            ;;
        --timeout)
            TEST_TIMEOUT="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="true"
            shift
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --keep-containers)
            KEEP_CONTAINERS="true"
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"