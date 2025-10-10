#!/usr/bin/env bash
#
# Debug Script for TCP Hang Issue (BUG-1)
# Runs incremental tests with verbose logging to identify where execution stops
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TCP Hang Debug Test Suite (BUG-1)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Build the debug tests directly (since they can't be in module easily)
echo -e "${YELLOW}Compiling debug tests...${NC}"
cd "$PROJECT_ROOT"

# Compile debug tests as standalone test file
zig test tests/debug_tcp_hang_test.zig \
    -I src \
    --main-pkg-path . \
    2>&1 | tee /tmp/zigcat_debug_build.log

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo -e "${RED}Test compilation failed! See /tmp/zigcat_debug_build.log${NC}"
    echo ""
    echo -e "${YELLOW}This is expected - the debug tests need proper module setup.${NC}"
    echo -e "${YELLOW}Running alternate approach...${NC}"
    echo ""
    # Fall back to building main project
    zig build 2>&1 | tee /tmp/zigcat_build.log
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "${RED}Build failed! See /tmp/zigcat_build.log${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}Build successful${NC}"
echo ""

# Test runner function
run_test() {
    local test_name="$1"
    local test_filter="$2"

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Running: $test_name${NC}"
    echo -e "${BLUE}========================================${NC}"

    local log_file="/tmp/zigcat_debug_${test_filter}.log"

    # Run with timeout to catch hangs
    # Try standalone test first
    if timeout 30s zig test tests/debug_tcp_hang_test.zig --main-pkg-path . 2>&1 | grep -A 100 "$test_filter" | tee "$log_file"; then
        if grep -q "All 1 tests passed" "$log_file" 2>/dev/null || grep -q "PASS" "$log_file" 2>/dev/null; then
            echo -e "${GREEN}✓ PASS: $test_name${NC}"
            return 0
        fi
    fi

    local exit_code="${PIPESTATUS[0]}"
    if [ "$exit_code" -eq 124 ]; then
        echo -e "${RED}✗ TIMEOUT: $test_name (hung after 30s)${NC}"
        echo -e "${YELLOW}Last 50 lines of output:${NC}"
        tail -n 50 "$log_file"
    elif [ "$exit_code" -ne 0 ]; then
        echo -e "${RED}✗ FAIL/SKIP: $test_name (exit code: $exit_code)${NC}"
        echo -e "${YELLOW}Note: Tests may not compile due to module dependencies${NC}"
    fi
    return $exit_code
    echo ""
}

# Run tests incrementally
echo -e "${YELLOW}Running incremental debug tests...${NC}"
echo ""

# Test 1: Connect only
run_test "Test 1: Connect Only (No Data)" "debug-1: connect only"
TEST1_RESULT=$?

# Test 2: Send one byte
run_test "Test 2: Send One Byte and Close" "debug-2: send one byte"
TEST2_RESULT=$?

# Test 3: Simple echo
run_test "Test 3: Simple Echo (Send + Receive)" "debug-3: simple echo"
TEST3_RESULT=$?

# Test 4: Bidirectional (the problematic one)
run_test "Test 4: Bidirectional Echo (Poll-Based)" "debug-4: bidirectional"
TEST4_RESULT=$?

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

print_result() {
    local name="$1"
    local result=$2

    if [ $result -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} $name"
    elif [ $result -eq 124 ]; then
        echo -e "  ${RED}⏱ TIMEOUT${NC} $name"
    else
        echo -e "  ${RED}✗ FAIL${NC} $name"
    fi
}

print_result "Test 1: Connect Only" $TEST1_RESULT
print_result "Test 2: Send One Byte" $TEST2_RESULT
print_result "Test 3: Simple Echo" $TEST3_RESULT
print_result "Test 4: Bidirectional Echo" $TEST4_RESULT

echo ""

# Determine which test failed/hung first
if [ $TEST1_RESULT -ne 0 ]; then
    echo -e "${RED}Issue detected at: Test 1 (Connect Only)${NC}"
    echo -e "${YELLOW}Problem: Basic TCP connection establishment${NC}"
elif [ $TEST2_RESULT -ne 0 ]; then
    echo -e "${RED}Issue detected at: Test 2 (Send One Byte)${NC}"
    echo -e "${YELLOW}Problem: Socket send operation${NC}"
elif [ $TEST3_RESULT -ne 0 ]; then
    echo -e "${RED}Issue detected at: Test 3 (Simple Echo)${NC}"
    echo -e "${YELLOW}Problem: Bidirectional communication or socket recv${NC}"
elif [ $TEST4_RESULT -ne 0 ]; then
    echo -e "${RED}Issue detected at: Test 4 (Bidirectional Echo)${NC}"
    echo -e "${YELLOW}Problem: Poll-based bidirectional transfer logic${NC}"
else
    echo -e "${GREEN}All tests passed! Issue may be intermittent or environment-specific${NC}"
fi

echo ""
echo -e "${BLUE}Log files saved to:${NC}"
echo "  /tmp/zigcat_build.log"
echo "  /tmp/zigcat_debug_*.log"
echo ""

# Additional diagnostics
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}System Diagnostics${NC}"
echo -e "${BLUE}========================================${NC}"

echo "OS: $(uname -s) $(uname -r)"
echo "Zig version: $(zig version)"
echo "Poll mechanism: $(uname -s | grep -q Darwin && echo 'kqueue (macOS)' || echo 'epoll (Linux)')"
echo ""

# Check for any zombie processes
if pgrep -f "zigcat|zig-cache" > /dev/null; then
    echo -e "${YELLOW}Warning: zigcat processes still running:${NC}"
    pgrep -af "zigcat|zig-cache"
    echo ""
fi

# Memory analysis hint
echo -e "${YELLOW}For detailed analysis:${NC}"
echo "  1. Run with strace/dtrace: strace -f zig build test 2>&1 | grep -A5 -B5 poll"
echo "  2. Check file descriptors: lsof -p \$(pgrep -f zigcat)"
echo "  3. Analyze with lldb: lldb -- zig build test"
echo ""

exit $(( TEST1_RESULT + TEST2_RESULT + TEST3_RESULT + TEST4_RESULT ))
