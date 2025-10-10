#!/bin/bash
# Generate comprehensive test reports for ZigCat Docker test suite

set -euo pipefail

# Default configuration
RESULTS_DIR="${RESULTS_DIR:-docker-tests/results}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-docker-tests/artifacts}"
OUTPUT_DIR="${OUTPUT_DIR:-docker-tests/reports}"
FORMATS="${FORMATS:-json html text}"
VERBOSE="${VERBOSE:-false}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
Usage: $0 [OPTIONS]

Generate comprehensive test reports for ZigCat Docker test suite.

OPTIONS:
    --results-dir DIR       Directory containing test results (default: docker-tests/results)
    --artifacts-dir DIR     Directory containing build artifacts (default: docker-tests/artifacts)
    --output-dir DIR        Output directory for reports (default: docker-tests/reports)
    --formats LIST          Space-separated list of formats: json html junit text (default: json html text)
    --verbose               Enable verbose output
    --help                  Show this help message

EXAMPLES:
    # Generate all default reports
    $0

    # Generate only JSON and HTML reports
    $0 --formats "json html"

    # Use custom directories
    $0 --results-dir /tmp/test-results --output-dir /tmp/reports

    # Generate JUnit XML for CI integration
    $0 --formats "junit" --output-dir ci-reports

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --results-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --artifacts-dir)
            ARTIFACTS_DIR="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --formats)
            FORMATS="$2"
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
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate directories
if [[ ! -d "$RESULTS_DIR" ]]; then
    log_error "Results directory does not exist: $RESULTS_DIR"
    exit 1
fi

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
    log_warning "Artifacts directory does not exist: $ARTIFACTS_DIR"
    log_warning "Some report features may be limited"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for Python
if ! command -v python3 &> /dev/null; then
    log_error "Python 3 is required but not installed"
    exit 1
fi

# Change to project root for relative paths
cd "$PROJECT_ROOT"

log "Starting report generation..."
log "Results directory: $RESULTS_DIR"
log "Artifacts directory: $ARTIFACTS_DIR"
log "Output directory: $OUTPUT_DIR"
log "Formats: $FORMATS"

# Run the Python aggregator
PYTHON_ARGS=(
    --results-dir "$RESULTS_DIR"
    --artifacts-dir "$ARTIFACTS_DIR"
    --output-dir "$OUTPUT_DIR"
    --formats $FORMATS
)

if [[ "$VERBOSE" == "true" ]]; then
    log "Running: python3 $SCRIPT_DIR/result-aggregator.py ${PYTHON_ARGS[*]}"
fi

if python3 "$SCRIPT_DIR/result-aggregator.py" "${PYTHON_ARGS[@]}"; then
    log_success "Report generation completed successfully"
    
    # List generated files
    log "Generated reports:"
    find "$OUTPUT_DIR" -name "*$(date +%Y%m%d)*" -type f | while read -r file; do
        size=$(du -h "$file" | cut -f1)
        log_success "  $(basename "$file") ($size)"
    done
    
    # Show quick summary if text report was generated
    LATEST_TEXT_REPORT=$(find "$OUTPUT_DIR" -name "test-summary-*.txt" -type f | sort | tail -1)
    if [[ -n "$LATEST_TEXT_REPORT" && -f "$LATEST_TEXT_REPORT" ]]; then
        log ""
        log "Quick Summary:"
        log "=============="
        head -20 "$LATEST_TEXT_REPORT" | tail -n +3
    fi
    
else
    log_error "Report generation failed"
    exit 1
fi

# Generate historical comparison if previous reports exist
HISTORICAL_REPORTS=$(find "$OUTPUT_DIR" -name "test-report-*.json" -type f | wc -l)
if [[ $HISTORICAL_REPORTS -gt 1 ]]; then
    log ""
    log "Historical data available ($HISTORICAL_REPORTS reports)"
    log "Consider running trend analysis for performance tracking"
fi

log_success "Report generation process completed"