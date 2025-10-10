#!/bin/bash
# CI/CD Integration Script for ZigCat Docker Test Suite
# Provides standardized CI/CD pipeline integration with proper exit codes,
# artifact preservation, and result caching

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default configuration
RESULTS_DIR="${RESULTS_DIR:-docker-tests/results}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-docker-tests/artifacts}"
REPORTS_DIR="${REPORTS_DIR:-docker-tests/reports}"
CI_ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-ci-artifacts}"
CACHE_DIR="${CACHE_DIR:-docker-tests/cache}"
JUNIT_OUTPUT="${JUNIT_OUTPUT:-test-results.xml}"
ENABLE_CACHING="${ENABLE_CACHING:-true}"
PRESERVE_ARTIFACTS="${PRESERVE_ARTIFACTS:-true}"
FAIL_FAST="${FAIL_FAST:-false}"
VERBOSE="${VERBOSE:-false}"

# CI/CD specific settings
CI_SYSTEM="${CI_SYSTEM:-generic}"  # github, gitlab, jenkins, generic
BUILD_ID="${BUILD_ID:-$(date +%Y%m%d-%H%M%S)}"
BRANCH_NAME="${BRANCH_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
COMMIT_SHA="${COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo 'unknown')}"

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
Usage: $0 [OPTIONS] [COMMAND]

CI/CD integration script for ZigCat Docker test suite.

COMMANDS:
    run                     Run tests with CI/CD integration (default)
    cache-check            Check if cached results are available
    cache-save             Save current results to cache
    cache-restore          Restore results from cache
    artifacts-collect      Collect and preserve test artifacts
    junit-generate         Generate JUnit XML report
    exit-code-check        Check and return appropriate exit code

OPTIONS:
    --results-dir DIR       Results directory (default: docker-tests/results)
    --artifacts-dir DIR     Artifacts directory (default: docker-tests/artifacts)
    --reports-dir DIR       Reports directory (default: docker-tests/reports)
    --ci-artifacts-dir DIR  CI artifacts output directory (default: ci-artifacts)
    --cache-dir DIR         Cache directory (default: docker-tests/cache)
    --junit-output FILE     JUnit XML output file (default: test-results.xml)
    --ci-system SYSTEM      CI system type: github, gitlab, jenkins, generic (default: generic)
    --build-id ID           Build identifier (default: timestamp)
    --branch-name NAME      Branch name (default: from git)
    --commit-sha SHA        Commit SHA (default: from git)
    --enable-caching        Enable result caching (default: true)
    --disable-caching       Disable result caching
    --preserve-artifacts    Preserve test artifacts (default: true)
    --no-preserve-artifacts Don't preserve test artifacts
    --fail-fast             Exit immediately on first failure
    --verbose               Enable verbose output
    --help                  Show this help message

ENVIRONMENT VARIABLES:
    CI                      Set to 'true' if running in CI environment
    GITHUB_ACTIONS          Set to 'true' if running in GitHub Actions
    GITLAB_CI               Set to 'true' if running in GitLab CI
    JENKINS_URL             Set if running in Jenkins
    BUILD_NUMBER            Build number from CI system
    JOB_NAME                Job name from CI system

EXAMPLES:
    # Run tests with CI integration
    $0 run

    # Generate only JUnit XML report
    $0 junit-generate --junit-output results.xml

    # Check cache and run tests if needed
    $0 cache-check && echo "Using cached results" || $0 run

    # Collect artifacts for CI system
    $0 artifacts-collect --ci-artifacts-dir /tmp/artifacts

EOF
}

# Detect CI system automatically
detect_ci_system() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        CI_SYSTEM="github"
        BUILD_ID="${GITHUB_RUN_ID:-$BUILD_ID}"
        BRANCH_NAME="${GITHUB_REF_NAME:-$BRANCH_NAME}"
        COMMIT_SHA="${GITHUB_SHA:-$COMMIT_SHA}"
    elif [[ "${GITLAB_CI:-}" == "true" ]]; then
        CI_SYSTEM="gitlab"
        BUILD_ID="${CI_PIPELINE_ID:-$BUILD_ID}"
        BRANCH_NAME="${CI_COMMIT_REF_NAME:-$BRANCH_NAME}"
        COMMIT_SHA="${CI_COMMIT_SHA:-$COMMIT_SHA}"
    elif [[ -n "${JENKINS_URL:-}" ]]; then
        CI_SYSTEM="jenkins"
        BUILD_ID="${BUILD_NUMBER:-$BUILD_ID}"
        BRANCH_NAME="${GIT_BRANCH:-$BRANCH_NAME}"
        COMMIT_SHA="${GIT_COMMIT:-$COMMIT_SHA}"
    fi
    
    log "Detected CI system: $CI_SYSTEM"
    log "Build ID: $BUILD_ID"
    log "Branch: $BRANCH_NAME"
    log "Commit: ${COMMIT_SHA:0:8}"
}

# Generate cache key based on relevant factors
generate_cache_key() {
    local cache_inputs=""
    
    # Include source code hash
    if command -v git &> /dev/null; then
        local src_hash
        src_hash=$(git ls-tree -r HEAD src/ | git hash-object --stdin 2>/dev/null || echo "no-git")
        cache_inputs="${cache_inputs}src:${src_hash},"
    fi
    
    # Include build configuration
    if [[ -f "$PROJECT_ROOT/build.zig" ]]; then
        local build_hash
        build_hash=$(sha256sum "$PROJECT_ROOT/build.zig" | cut -d' ' -f1)
        cache_inputs="${cache_inputs}build:${build_hash},"
    fi
    
    # Include test configuration
    if [[ -f "$PROJECT_ROOT/docker-tests/configs/test-config.yml" ]]; then
        local config_hash
        config_hash=$(sha256sum "$PROJECT_ROOT/docker-tests/configs/test-config.yml" | cut -d' ' -f1)
        cache_inputs="${cache_inputs}config:${config_hash},"
    fi
    
    # Include Docker files
    local docker_hash=""
    for dockerfile in "$PROJECT_ROOT/docker-tests/dockerfiles"/*; do
        if [[ -f "$dockerfile" ]]; then
            local file_hash
            file_hash=$(sha256sum "$dockerfile" | cut -d' ' -f1)
            docker_hash="${docker_hash}${file_hash}"
        fi
    done
    if [[ -n "$docker_hash" ]]; then
        docker_hash=$(echo -n "$docker_hash" | sha256sum | cut -d' ' -f1)
        cache_inputs="${cache_inputs}docker:${docker_hash},"
    fi
    
    # Generate final cache key
    echo -n "$cache_inputs" | sha256sum | cut -d' ' -f1
}

# Check if cached results are available and valid
cache_check() {
    if [[ "$ENABLE_CACHING" != "true" ]]; then
        log "Caching disabled, skipping cache check"
        return 1
    fi
    
    local cache_key
    cache_key=$(generate_cache_key)
    local cache_file="$CACHE_DIR/results-${cache_key}.tar.gz"
    
    log "Checking cache with key: $cache_key"
    
    if [[ -f "$cache_file" ]]; then
        log_success "Cache hit: $cache_file"
        return 0
    else
        log "Cache miss: $cache_file"
        return 1
    fi
}

# Restore results from cache
cache_restore() {
    if [[ "$ENABLE_CACHING" != "true" ]]; then
        log "Caching disabled, skipping cache restore"
        return 1
    fi
    
    local cache_key
    cache_key=$(generate_cache_key)
    local cache_file="$CACHE_DIR/results-${cache_key}.tar.gz"
    
    if [[ ! -f "$cache_file" ]]; then
        log_error "Cache file not found: $cache_file"
        return 1
    fi
    
    log "Restoring results from cache: $cache_file"
    
    # Create directories
    mkdir -p "$RESULTS_DIR" "$ARTIFACTS_DIR" "$REPORTS_DIR"
    
    # Extract cached results
    if tar -xzf "$cache_file" -C "$PROJECT_ROOT"; then
        log_success "Results restored from cache"
        return 0
    else
        log_error "Failed to restore results from cache"
        return 1
    fi
}

# Save current results to cache
cache_save() {
    if [[ "$ENABLE_CACHING" != "true" ]]; then
        log "Caching disabled, skipping cache save"
        return 0
    fi
    
    local cache_key
    cache_key=$(generate_cache_key)
    local cache_file="$CACHE_DIR/results-${cache_key}.tar.gz"
    
    log "Saving results to cache: $cache_file"
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
    
    # Create temporary directory for cache contents
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Copy results to temporary directory
    if [[ -d "$RESULTS_DIR" ]]; then
        cp -r "$RESULTS_DIR" "$temp_dir/"
    fi
    if [[ -d "$ARTIFACTS_DIR" ]]; then
        cp -r "$ARTIFACTS_DIR" "$temp_dir/"
    fi
    if [[ -d "$REPORTS_DIR" ]]; then
        cp -r "$REPORTS_DIR" "$temp_dir/"
    fi
    
    # Create cache archive
    if tar -czf "$cache_file" -C "$temp_dir" .; then
        log_success "Results saved to cache"
        
        # Clean up old cache files (keep last 10)
        find "$CACHE_DIR" -name "results-*.tar.gz" -type f | sort -r | tail -n +11 | xargs -r rm -f
        
        rm -rf "$temp_dir"
        return 0
    else
        log_error "Failed to save results to cache"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Generate JUnit XML report
junit_generate() {
    log "Generating JUnit XML report: $JUNIT_OUTPUT"
    
    # Use the Python result aggregator to generate JUnit XML
    if [[ -f "$SCRIPT_DIR/result-aggregator.py" ]]; then
        if python3 "$SCRIPT_DIR/result-aggregator.py" \
            --results-dir "$RESULTS_DIR" \
            --artifacts-dir "$ARTIFACTS_DIR" \
            --output-dir "$(dirname "$JUNIT_OUTPUT")" \
            --formats junit; then
            
            # Find the generated JUnit file and rename it
            local generated_junit
            generated_junit=$(find "$(dirname "$JUNIT_OUTPUT")" -name "test-results-*.xml" -type f | sort | tail -1)
            
            if [[ -n "$generated_junit" && -f "$generated_junit" ]]; then
                mv "$generated_junit" "$JUNIT_OUTPUT"
                log_success "JUnit XML report generated: $JUNIT_OUTPUT"
                return 0
            else
                log_error "Generated JUnit file not found"
                return 1
            fi
        else
            log_error "Failed to generate JUnit XML report"
            return 1
        fi
    else
        log_error "Result aggregator not found"
        return 1
    fi
}

# Collect and preserve test artifacts
artifacts_collect() {
    log "Collecting test artifacts to: $CI_ARTIFACTS_DIR"
    
    # Create CI artifacts directory
    mkdir -p "$CI_ARTIFACTS_DIR"
    
    # Copy test results
    if [[ -d "$RESULTS_DIR" ]]; then
        cp -r "$RESULTS_DIR" "$CI_ARTIFACTS_DIR/"
        log "Copied test results"
    fi
    
    # Copy build artifacts
    if [[ -d "$ARTIFACTS_DIR" ]]; then
        cp -r "$ARTIFACTS_DIR" "$CI_ARTIFACTS_DIR/"
        log "Copied build artifacts"
    fi
    
    # Copy reports
    if [[ -d "$REPORTS_DIR" ]]; then
        cp -r "$REPORTS_DIR" "$CI_ARTIFACTS_DIR/"
        log "Copied test reports"
    fi
    
    # Copy logs
    if [[ -d "docker-tests/logs" ]]; then
        cp -r "docker-tests/logs" "$CI_ARTIFACTS_DIR/"
        log "Copied test logs"
    fi
    
    # Create artifact summary
    cat > "$CI_ARTIFACTS_DIR/artifact-summary.txt" << EOF
ZigCat Docker Test Artifacts
============================

Build ID: $BUILD_ID
Branch: $BRANCH_NAME
Commit: $COMMIT_SHA
CI System: $CI_SYSTEM
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Contents:
- results/: Test execution results and metrics
- artifacts/: Built binaries and build logs
- reports/: Generated test reports (JSON, HTML, text)
- logs/: Detailed test execution logs

For more information, see the test reports in the reports/ directory.
EOF
    
    # Generate file listing
    find "$CI_ARTIFACTS_DIR" -type f | sort > "$CI_ARTIFACTS_DIR/file-listing.txt"
    
    log_success "Test artifacts collected successfully"
    
    # Show artifact summary
    local total_size
    total_size=$(du -sh "$CI_ARTIFACTS_DIR" | cut -f1)
    local file_count
    file_count=$(find "$CI_ARTIFACTS_DIR" -type f | wc -l)
    
    log "Artifact summary: $file_count files, $total_size total"
}

# Check test results and return appropriate exit code
exit_code_check() {
    local exit_code=0
    
    # Check if test results exist
    if [[ ! -d "$RESULTS_DIR" ]]; then
        log_error "No test results found"
        return 2
    fi
    
    # Check main test report
    local main_report="$RESULTS_DIR/test-report.json"
    if [[ -f "$main_report" ]] && command -v jq &> /dev/null; then
        local failed_tests
        failed_tests=$(jq -r '.test_report.summary.failed_tests // 0' "$main_report" 2>/dev/null || echo "0")
        
        if [[ "$failed_tests" -gt 0 ]]; then
            log_error "Found $failed_tests failed tests"
            exit_code=1
        fi
    fi
    
    # Check build results
    local build_report="$ARTIFACTS_DIR/build-report.json"
    if [[ -f "$build_report" ]] && command -v jq &> /dev/null; then
        local failed_builds
        failed_builds=$(jq -r '[.build_report.artifacts[] | select(.build_success == false)] | length' "$build_report" 2>/dev/null || echo "0")
        
        if [[ "$failed_builds" -gt 0 ]]; then
            log_error "Found $failed_builds failed builds"
            exit_code=2
        fi
    fi
    
    # Check for individual platform results
    for result_file in "$RESULTS_DIR"/test-metrics-*.json; do
        if [[ -f "$result_file" ]] && command -v jq &> /dev/null; then
            local platform_exit_code
            platform_exit_code=$(jq -r '.test_run.metrics.exit_code // 0' "$result_file" 2>/dev/null || echo "0")
            
            if [[ "$platform_exit_code" -ne 0 ]]; then
                local platform_key
                platform_key=$(jq -r '.test_run.platform_key // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
                log_error "Platform $platform_key failed with exit code $platform_exit_code"
                exit_code=1
            fi
        fi
    done
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "All tests passed"
    else
        log_error "Tests failed with exit code $exit_code"
    fi
    
    return $exit_code
}

# Run complete CI/CD integration
run_ci_integration() {
    log "Starting CI/CD integration for ZigCat Docker tests"
    
    # Detect CI system
    detect_ci_system
    
    # Check cache first
    if cache_check && cache_restore; then
        log_success "Using cached test results"
    else
        log "Running fresh tests"
        
        # Run the main test suite
        if [[ -f "$SCRIPT_DIR/run-tests.sh" ]]; then
            local test_args=()
            
            if [[ "$VERBOSE" == "true" ]]; then
                test_args+=(--verbose)
            fi
            
            if [[ "$FAIL_FAST" == "true" ]]; then
                test_args+=(--fail-fast)
            fi
            
            if "$SCRIPT_DIR/run-tests.sh" "${test_args[@]}"; then
                log_success "Test execution completed"
                
                # Save results to cache
                cache_save
            else
                log_error "Test execution failed"
                
                # Still collect artifacts for debugging
                if [[ "$PRESERVE_ARTIFACTS" == "true" ]]; then
                    artifacts_collect
                fi
                
                return 1
            fi
        else
            log_error "Main test runner not found: $SCRIPT_DIR/run-tests.sh"
            return 2
        fi
    fi
    
    # Generate JUnit XML report
    junit_generate
    
    # Collect artifacts if requested
    if [[ "$PRESERVE_ARTIFACTS" == "true" ]]; then
        artifacts_collect
    fi
    
    # Check final exit code
    exit_code_check
}

# Parse command line arguments
COMMAND="run"

while [[ $# -gt 0 ]]; do
    case $1 in
        run|cache-check|cache-save|cache-restore|artifacts-collect|junit-generate|exit-code-check)
            COMMAND="$1"
            shift
            ;;
        --results-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --artifacts-dir)
            ARTIFACTS_DIR="$2"
            shift 2
            ;;
        --reports-dir)
            REPORTS_DIR="$2"
            shift 2
            ;;
        --ci-artifacts-dir)
            CI_ARTIFACTS_DIR="$2"
            shift 2
            ;;
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --junit-output)
            JUNIT_OUTPUT="$2"
            shift 2
            ;;
        --ci-system)
            CI_SYSTEM="$2"
            shift 2
            ;;
        --build-id)
            BUILD_ID="$2"
            shift 2
            ;;
        --branch-name)
            BRANCH_NAME="$2"
            shift 2
            ;;
        --commit-sha)
            COMMIT_SHA="$2"
            shift 2
            ;;
        --enable-caching)
            ENABLE_CACHING=true
            shift
            ;;
        --disable-caching)
            ENABLE_CACHING=false
            shift
            ;;
        --preserve-artifacts)
            PRESERVE_ARTIFACTS=true
            shift
            ;;
        --no-preserve-artifacts)
            PRESERVE_ARTIFACTS=false
            shift
            ;;
        --fail-fast)
            FAIL_FAST=true
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
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Change to project root
cd "$PROJECT_ROOT"

# Execute the requested command
case $COMMAND in
    run)
        run_ci_integration
        ;;
    cache-check)
        cache_check
        ;;
    cache-save)
        cache_save
        ;;
    cache-restore)
        cache_restore
        ;;
    artifacts-collect)
        artifacts_collect
        ;;
    junit-generate)
        junit_generate
        ;;
    exit-code-check)
        exit_code_check
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac