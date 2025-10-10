#!/bin/bash

# Comprehensive Binary Validation Runner for ZigCat Docker Test System
# Orchestrates binary validation, cross-platform integration, and security testing

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_TESTS_DIR="$PROJECT_ROOT/docker-tests"
ARTIFACTS_DIR="$DOCKER_TESTS_DIR/artifacts"
RESULTS_DIR="$DOCKER_TESTS_DIR/results"

# Default values
PLATFORMS="linux,alpine"
ARCHITECTURES="amd64"
TEST_SUITES="basic,protocols"
TIMEOUT=300
VERBOSE=false
KEEP_LOGS=false
PARALLEL=false
OUTPUT_DIR=""

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
Usage: $0 [OPTIONS]

Comprehensive binary validation testing for ZigCat across multiple platforms.

Options:
  --platforms PLATFORMS      Comma-separated list of platforms (linux,alpine,freebsd) [default: linux,alpine]
  --architectures ARCHS      Comma-separated list of architectures (amd64,arm64) [default: amd64]
  --test-suites SUITES       Test suites to run (basic,protocols,advanced) [default: basic,protocols]
  --timeout SECONDS          Global timeout for all tests [default: 300]
  --output-dir DIR           Directory for test results [default: docker-tests/results]
  --parallel                 Run tests in parallel where possible
  --keep-logs                Keep test logs after completion
  --verbose                  Enable verbose output
  --help                     Show this help message

Test Components:
  1. Binary Validation       - Basic functionality, dependencies, compatibility
  2. Cross-Platform Tests    - TCP/UDP communication, TLS, proxy protocols
  3. Security & Exec Tests   - Command execution, access control, timeout handling

Examples:
  $0                                           # Run basic tests on Linux and Alpine (amd64)
  $0 --platforms linux,alpine,freebsd --verbose
  $0 --architectures amd64,arm64 --test-suites basic,protocols,advanced
  $0 --parallel --keep-logs --output-dir ./validation-results

EOF
}

# Parse command line arguments
parse_args() {
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
            --test-suites)
                TEST_SUITES="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL=true
                shift
                ;;
            --keep-logs)
                KEEP_LOGS=true
                shift
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

    # Set default output directory if not specified
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$RESULTS_DIR"
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
}

# Check if binary exists for platform/architecture
check_binary_exists() {
    local platform="$1"
    local arch="$2"
    local binary_path="$ARTIFACTS_DIR/$platform-$arch/zigcat"
    
    if [[ -f "$binary_path" ]]; then
        echo "$binary_path"
        return 0
    else
        log_warning "Binary not found: $binary_path"
        return 1
    fi
}

# Run binary validation for a single platform/architecture
run_binary_validation() {
    local platform="$1"
    local arch="$2"
    local binary_path="$3"
    local output_file="$4"
    
    log_info "Running binary validation for $platform-$arch..."
    
    local validation_args=(
        --platform "$platform"
        --architecture "$arch"
        --binary "$binary_path"
        --output "$output_file"
    )
    
    if [[ "$VERBOSE" == "true" ]]; then
        validation_args+=(--verbose)
    fi
    
    if "$SCRIPT_DIR/binary-validation.sh" "${validation_args[@]}"; then
        log_success "Binary validation passed for $platform-$arch"
        return 0
    else
        log_error "Binary validation failed for $platform-$arch"
        return 1
    fi
}

# Run cross-platform integration tests
run_cross_platform_tests() {
    local server_platform="$1"
    local server_arch="$2"
    local server_binary="$3"
    local client_platform="$4"
    local client_arch="$5"
    local client_binary="$6"
    local output_file="$7"
    
    log_info "Running cross-platform tests: $server_platform-$server_arch <-> $client_platform-$client_arch..."
    
    local integration_args=(
        --server-platform "$server_platform"
        --client-platform "$client_platform"
        --server-arch "$server_arch"
        --client-arch "$client_arch"
        --server-binary "$server_binary"
        --client-binary "$client_binary"
        --test-suites "$TEST_SUITES"
        --timeout $((TIMEOUT / 4))
        --output "$output_file"
    )
    
    if [[ "$VERBOSE" == "true" ]]; then
        integration_args+=(--verbose)
    fi
    
    if [[ "$KEEP_LOGS" == "true" ]]; then
        integration_args+=(--keep-logs)
    fi
    
    if "$SCRIPT_DIR/cross-platform-integration.sh" "${integration_args[@]}"; then
        log_success "Cross-platform tests passed: $server_platform-$server_arch <-> $client_platform-$client_arch"
        return 0
    else
        log_error "Cross-platform tests failed: $server_platform-$server_arch <-> $client_platform-$client_arch"
        return 1
    fi
}

# Run security and exec tests
run_security_exec_tests() {
    local platform="$1"
    local arch="$2"
    local binary_path="$3"
    local output_file="$4"
    
    log_info "Running security and exec tests for $platform-$arch..."
    
    local security_args=(
        --platform "$platform"
        --architecture "$arch"
        --binary "$binary_path"
        --test-suites "exec,security,timeout"
        --timeout $((TIMEOUT / 4))
        --output "$output_file"
    )
    
    if [[ "$VERBOSE" == "true" ]]; then
        security_args+=(--verbose)
    fi
    
    if [[ "$KEEP_LOGS" == "true" ]]; then
        security_args+=(--keep-logs)
    fi
    
    if "$SCRIPT_DIR/security-exec-tests.sh" "${security_args[@]}"; then
        log_success "Security and exec tests passed for $platform-$arch"
        return 0
    else
        log_error "Security and exec tests failed for $platform-$arch"
        return 1
    fi
}

# Generate comprehensive summary report
generate_comprehensive_summary() {
    local session_id="$1"
    local summary_file="$OUTPUT_DIR/comprehensive-summary-$session_id.json"
    
    log_info "Generating comprehensive summary report..."
    
    # Initialize summary structure
    cat > "$summary_file" << EOF
{
  "session_id": "$session_id",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "configuration": {
    "platforms": "$PLATFORMS",
    "architectures": "$ARCHITECTURES",
    "test_suites": "$TEST_SUITES",
    "timeout": $TIMEOUT,
    "parallel": $PARALLEL
  },
  "results": {
    "binary_validation": {},
    "cross_platform_tests": {},
    "security_exec_tests": {}
  },
  "summary": {
    "total_platforms": 0,
    "successful_platforms": 0,
    "failed_platforms": 0,
    "total_tests": 0,
    "passed_tests": 0,
    "failed_tests": 0,
    "skipped_tests": 0
  }
}
EOF
    
    # Aggregate results from individual test files
    python3 << EOF
import json
import glob
import os

summary_file = "$summary_file"
output_dir = "$OUTPUT_DIR"
session_id = "$session_id"

try:
    with open(summary_file, 'r') as f:
        summary = json.load(f)
    
    # Find all result files for this session
    result_files = glob.glob(os.path.join(output_dir, f"*{session_id}*.json"))
    
    total_tests = 0
    passed_tests = 0
    failed_tests = 0
    skipped_tests = 0
    
    for result_file in result_files:
        if result_file == summary_file:
            continue
            
        try:
            with open(result_file, 'r') as f:
                data = json.load(f)
            
            # Extract test counts
            if 'summary' in data:
                total_tests += data['summary'].get('total_tests', 0)
                passed_tests += data['summary'].get('passed', 0)
                failed_tests += data['summary'].get('failed', 0)
                skipped_tests += data['summary'].get('skipped', 0)
            
            # Store individual results
            filename = os.path.basename(result_file)
            if 'binary-validation' in filename:
                summary['results']['binary_validation'][filename] = data
            elif 'cross-platform' in filename:
                summary['results']['cross_platform_tests'][filename] = data
            elif 'security-exec' in filename:
                summary['results']['security_exec_tests'][filename] = data
                
        except Exception as e:
            print(f"Error processing {result_file}: {e}")
    
    # Update summary totals
    summary['summary']['total_tests'] = total_tests
    summary['summary']['passed_tests'] = passed_tests
    summary['summary']['failed_tests'] = failed_tests
    summary['summary']['skipped_tests'] = skipped_tests
    
    # Write updated summary
    with open(summary_file, 'w') as f:
        json.dump(summary, f, indent=2)
        
    print(f"Summary written to: {summary_file}")
    
except Exception as e:
    print(f"Error generating summary: {e}")
    exit(1)
EOF
    
    # Display summary
    echo
    log_info "=== Comprehensive Binary Validation Summary ==="
    
    local total_tests passed_tests failed_tests skipped_tests
    total_tests=$(python3 -c "import json; data=json.load(open('$summary_file')); print(data['summary']['total_tests'])" 2>/dev/null || echo "0")
    passed_tests=$(python3 -c "import json; data=json.load(open('$summary_file')); print(data['summary']['passed_tests'])" 2>/dev/null || echo "0")
    failed_tests=$(python3 -c "import json; data=json.load(open('$summary_file')); print(data['summary']['failed_tests'])" 2>/dev/null || echo "0")
    skipped_tests=$(python3 -c "import json; data=json.load(open('$summary_file')); print(data['summary']['skipped_tests'])" 2>/dev/null || echo "0")
    
    log_info "Platforms: $PLATFORMS"
    log_info "Architectures: $ARCHITECTURES"
    log_info "Test Suites: $TEST_SUITES"
    echo
    log_info "Overall Test Results:"
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
    log_info "Detailed results available in: $OUTPUT_DIR"
    log_info "Summary report: $summary_file"
    
    if [[ "$failed_tests" -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# Main execution
main() {
    local start_time=$(date +%s)
    local session_id="validation-$(date +%s)-$(head -c 4 /dev/urandom | base64 | tr -d '/' | tr -d '+' | tr -d '=')"
    
    log_info "Starting comprehensive binary validation..."
    log_info "Session ID: $session_id"
    log_info "Platforms: $PLATFORMS"
    log_info "Architectures: $ARCHITECTURES"
    log_info "Test Suites: $TEST_SUITES"
    log_info "Output Directory: $OUTPUT_DIR"
    
    # Parse platform and architecture lists
    IFS=',' read -ra PLATFORM_LIST <<< "$PLATFORMS"
    IFS=',' read -ra ARCH_LIST <<< "$ARCHITECTURES"
    
    local overall_success=true
    local platform_combinations=()
    
    # Build list of platform/architecture combinations
    for platform in "${PLATFORM_LIST[@]}"; do
        platform=$(echo "$platform" | xargs) # trim whitespace
        for arch in "${ARCH_LIST[@]}"; do
            arch=$(echo "$arch" | xargs) # trim whitespace
            
            if binary_path=$(check_binary_exists "$platform" "$arch"); then
                platform_combinations+=("$platform:$arch:$binary_path")
                log_verbose "Found binary: $platform-$arch -> $binary_path"
            else
                log_warning "Skipping $platform-$arch (binary not found)"
                overall_success=false
            fi
        done
    done
    
    if [[ ${#platform_combinations[@]} -eq 0 ]]; then
        log_error "No valid platform/architecture combinations found"
        exit 1
    fi
    
    log_info "Testing ${#platform_combinations[@]} platform/architecture combinations"
    
    # Phase 1: Binary Validation
    log_info "=== Phase 1: Binary Validation ==="
    for combo in "${platform_combinations[@]}"; do
        IFS=':' read -ra COMBO_PARTS <<< "$combo"
        local platform="${COMBO_PARTS[0]}"
        local arch="${COMBO_PARTS[1]}"
        local binary_path="${COMBO_PARTS[2]}"
        
        local output_file="$OUTPUT_DIR/binary-validation-$platform-$arch-$session_id.json"
        
        if ! run_binary_validation "$platform" "$arch" "$binary_path" "$output_file"; then
            overall_success=false
        fi
    done
    
    # Phase 2: Cross-Platform Integration Tests
    log_info "=== Phase 2: Cross-Platform Integration Tests ==="
    if [[ ${#platform_combinations[@]} -gt 1 ]]; then
        # Test different platform combinations
        for i in "${!platform_combinations[@]}"; do
            for j in "${!platform_combinations[@]}"; do
                if [[ $i -ne $j ]]; then
                    IFS=':' read -ra SERVER_COMBO <<< "${platform_combinations[$i]}"
                    IFS=':' read -ra CLIENT_COMBO <<< "${platform_combinations[$j]}"
                    
                    local server_platform="${SERVER_COMBO[0]}"
                    local server_arch="${SERVER_COMBO[1]}"
                    local server_binary="${SERVER_COMBO[2]}"
                    local client_platform="${CLIENT_COMBO[0]}"
                    local client_arch="${CLIENT_COMBO[1]}"
                    local client_binary="${CLIENT_COMBO[2]}"
                    
                    local output_file="$OUTPUT_DIR/cross-platform-$server_platform$server_arch-$client_platform$client_arch-$session_id.json"
                    
                    if ! run_cross_platform_tests "$server_platform" "$server_arch" "$server_binary" \
                                                  "$client_platform" "$client_arch" "$client_binary" \
                                                  "$output_file"; then
                        overall_success=false
                    fi
                fi
            done
        done
    else
        log_info "Only one platform/architecture combination available, skipping cross-platform tests"
    fi
    
    # Phase 3: Security and Exec Tests
    log_info "=== Phase 3: Security and Exec Tests ==="
    for combo in "${platform_combinations[@]}"; do
        IFS=':' read -ra COMBO_PARTS <<< "$combo"
        local platform="${COMBO_PARTS[0]}"
        local arch="${COMBO_PARTS[1]}"
        local binary_path="${COMBO_PARTS[2]}"
        
        local output_file="$OUTPUT_DIR/security-exec-$platform-$arch-$session_id.json"
        
        if ! run_security_exec_tests "$platform" "$arch" "$binary_path" "$output_file"; then
            overall_success=false
        fi
    done
    
    # Generate comprehensive summary
    if ! generate_comprehensive_summary "$session_id"; then
        overall_success=false
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo
    log_info "Binary validation completed in ${duration} seconds"
    
    if [[ "$overall_success" == "true" ]]; then
        log_success "All binary validation tests passed!"
        exit 0
    else
        log_error "Some binary validation tests failed"
        exit 1
    fi
}

# Parse arguments and run main function
parse_args "$@"
main