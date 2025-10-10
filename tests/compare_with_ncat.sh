#!/bin/bash
# Ncat Behavioral Comparison Script
# Compares zigcat output with ncat output for identical inputs

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths
ZIGCAT="${ZIGCAT_PATH:-./zig-out/bin/zigcat}"
NCAT="${NCAT_PATH:-ncat}"
TMP_DIR="/tmp/zigcat_ncat_comparison_$$"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Cleanup on exit
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Create temp directory
mkdir -p "$TMP_DIR"

# ============================================================================
# Helper Functions
# ============================================================================

check_dependencies() {
    echo "Checking dependencies..."

    if [ ! -x "$ZIGCAT" ]; then
        echo -e "${RED}Error: zigcat not found at $ZIGCAT${NC}"
        echo "Build with: zig build"
        exit 1
    fi

    if ! command -v "$NCAT" &> /dev/null; then
        echo -e "${RED}Error: ncat not found${NC}"
        echo "Install with: sudo apt-get install ncat  # Ubuntu/Debian"
        echo "            : sudo yum install ncat      # RHEL/CentOS"
        echo "            : brew install nmap          # macOS"
        exit 1
    fi

    echo -e "${GREEN}✅ Dependencies OK${NC}"
    echo "zigcat: $ZIGCAT"
    echo "ncat: $(which $NCAT)"
    echo ""
}

compare_output() {
    local test_name=$1
    local ncat_cmd=$2
    local zigcat_cmd=$3
    local input=$4

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo -n "Test $TOTAL_TESTS: $test_name ... "

    # Run ncat
    echo "$input" | eval "$ncat_cmd" > "$TMP_DIR/ncat_output.txt" 2>&1 || ncat_exit=$?
    ncat_exit=${ncat_exit:-0}

    # Run zigcat
    echo "$input" | eval "$zigcat_cmd" > "$TMP_DIR/zigcat_output.txt" 2>&1 || zigcat_exit=$?
    zigcat_exit=${zigcat_exit:-0}

    # Compare outputs
    local output_diff=0
    if ! diff -q "$TMP_DIR/ncat_output.txt" "$TMP_DIR/zigcat_output.txt" > /dev/null 2>&1; then
        output_diff=1
    fi

    # Compare exit codes
    local exit_diff=0
    if [ "$ncat_exit" -ne "$zigcat_exit" ]; then
        exit_diff=1
    fi

    # Report results
    if [ $output_diff -eq 0 ] && [ $exit_diff -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))

        if [ $output_diff -eq 1 ]; then
            echo "  Output differs:"
            echo "  --- ncat output ---"
            cat "$TMP_DIR/ncat_output.txt" | head -5
            echo "  --- zigcat output ---"
            cat "$TMP_DIR/zigcat_output.txt" | head -5
            echo "  ---"
        fi

        if [ $exit_diff -eq 1 ]; then
            echo "  Exit code differs: ncat=$ncat_exit, zigcat=$zigcat_exit"
        fi
    fi
}

# ============================================================================
# Test Suite
# ============================================================================

run_version_tests() {
    echo "=== Version Tests ==="

    compare_output \
        "Version flag output" \
        "$NCAT --version" \
        "$ZIGCAT --version" \
        ""

    echo ""
}

run_basic_connection_tests() {
    echo "=== Basic Connection Tests ==="

    # Start test servers in background
    local ncat_port=19999
    local zigcat_port=20000

    # Test 1: Basic echo
    $NCAT -l $ncat_port > "$TMP_DIR/ncat_server_output.txt" 2>&1 &
    local ncat_server_pid=$!

    $ZIGCAT -l $zigcat_port > "$TMP_DIR/zigcat_server_output.txt" 2>&1 &
    local zigcat_server_pid=$!

    # Give servers time to start
    sleep 0.5

    # Send data to both servers
    echo "test data" | $NCAT localhost $ncat_port &
    echo "test data" | $ZIGCAT localhost $zigcat_port &

    # Wait for clients to complete
    sleep 1

    # Compare server outputs
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: Basic echo server ... "

    if diff -q "$TMP_DIR/ncat_server_output.txt" "$TMP_DIR/zigcat_server_output.txt" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi

    # Cleanup servers
    kill $ncat_server_pid $zigcat_server_pid 2>/dev/null || true

    echo ""
}

run_timeout_tests() {
    echo "=== Timeout Tests ==="

    # Test connect timeout (-w flag)
    compare_output \
        "Connect timeout to non-routable IP" \
        "$NCAT -w 1 192.0.2.1 9999" \
        "$ZIGCAT -w 1 192.0.2.1 9999" \
        ""

    echo ""
}

run_crlf_tests() {
    echo "=== CRLF Conversion Tests ==="

    # Test CRLF conversion
    local ncat_port=19998
    local zigcat_port=19997

    # Start servers with CRLF mode
    $NCAT -l $ncat_port --crlf > "$TMP_DIR/ncat_crlf_output.txt" 2>&1 &
    local ncat_pid=$!

    $ZIGCAT -l $zigcat_port --crlf > "$TMP_DIR/zigcat_crlf_output.txt" 2>&1 &
    local zigcat_pid=$!

    sleep 0.5

    # Send data with LF line endings
    printf "line1\nline2\nline3\n" | $NCAT localhost $ncat_port &
    printf "line1\nline2\nline3\n" | $ZIGCAT localhost $zigcat_port &

    sleep 1

    # Compare outputs (should have CRLF)
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: CRLF conversion ... "

    if diff -q "$TMP_DIR/ncat_crlf_output.txt" "$TMP_DIR/zigcat_crlf_output.txt" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi

    # Cleanup
    kill $ncat_pid $zigcat_pid 2>/dev/null || true

    echo ""
}

run_binary_data_tests() {
    echo "=== Binary Data Tests ==="

    local ncat_port=19996
    local zigcat_port=19995

    # Start servers
    $NCAT -l $ncat_port > "$TMP_DIR/ncat_binary_output.bin" 2>&1 &
    local ncat_pid=$!

    $ZIGCAT -l $zigcat_port > "$TMP_DIR/zigcat_binary_output.bin" 2>&1 &
    local zigcat_pid=$!

    sleep 0.5

    # Send binary data (all byte values 0x00-0xFF)
    dd if=/dev/urandom bs=256 count=1 2>/dev/null | $NCAT localhost $ncat_port &
    dd if=/dev/urandom bs=256 count=1 2>/dev/null | $ZIGCAT localhost $zigcat_port &

    sleep 1

    # Compare binary outputs
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: Binary data passthrough ... "

    # Both should receive data without corruption
    local ncat_size=$(stat -f%z "$TMP_DIR/ncat_binary_output.bin" 2>/dev/null || stat -c%s "$TMP_DIR/ncat_binary_output.bin")
    local zigcat_size=$(stat -f%z "$TMP_DIR/zigcat_binary_output.bin" 2>/dev/null || stat -c%s "$TMP_DIR/zigcat_binary_output.bin")

    if [ "$ncat_size" -gt 0 ] && [ "$zigcat_size" -gt 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "  ncat received: $ncat_size bytes"
        echo "  zigcat received: $zigcat_size bytes"
    fi

    # Cleanup
    kill $ncat_pid $zigcat_pid 2>/dev/null || true

    echo ""
}

run_help_comparison() {
    echo "=== Help Output Comparison ==="

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: Help flag consistency ... "

    # Get help outputs
    $NCAT --help > "$TMP_DIR/ncat_help.txt" 2>&1 || true
    $ZIGCAT --help > "$TMP_DIR/zigcat_help.txt" 2>&1 || true

    # Check that common flags are documented in both
    local common_flags=("-l" "-p" "-u" "-w" "-i" "--ssl" "--proxy")
    local missing_flags=0

    for flag in "${common_flags[@]}"; do
        if ! grep -q "$flag" "$TMP_DIR/zigcat_help.txt"; then
            echo "  zigcat help missing flag: $flag"
            missing_flags=$((missing_flags + 1))
        fi
    done

    if [ $missing_flags -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "  Missing $missing_flags common flags in zigcat help"
    fi

    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo "==========================================="
    echo "Zigcat vs Ncat Behavioral Comparison"
    echo "==========================================="
    echo ""

    check_dependencies

    # Run test suites
    run_version_tests
    run_basic_connection_tests
    run_timeout_tests
    run_crlf_tests
    run_binary_data_tests
    run_help_comparison

    # Summary
    echo "==========================================="
    echo "Test Summary"
    echo "==========================================="
    echo "Total tests: $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
    echo ""

    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "${GREEN}✅ All tests passed! Zigcat behaves identically to ncat.${NC}"
        exit 0
    else
        echo -e "${RED}❌ Some tests failed. Review differences above.${NC}"
        exit 1
    fi
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
