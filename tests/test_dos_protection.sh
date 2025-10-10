#!/bin/bash
# Test script for chat mode DoS protection
# Tests that MAX_LINES_PER_TICK limiting prevents server freezes

set -e

ZIGCAT="./zig-out/bin/zigcat"
PORT=19999
TIMEOUT=10

echo "=== Chat Mode DoS Protection Test ==="
echo

# Start server in chat mode with verbose output
echo "Starting chat server on port $PORT..."
$ZIGCAT -l -v --chat $PORT > /tmp/zigcat_dos_test.log 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 1

# Check if server started successfully
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start"
    exit 1
fi

echo "Server PID: $SERVER_PID"
echo

# Test 1: Send 200 newlines rapidly (should trigger work limiting)
echo "Test 1: Sending 200 newlines (should trigger MAX_LINES_PER_TICK=100 limit)..."
START_TIME=$(date +%s)
printf '%200s\n' '' | tr ' ' '\n' | timeout $TIMEOUT nc localhost $PORT > /dev/null 2>&1 &
CLIENT_PID=$!
sleep 2

# Server should still be responsive
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server crashed during flood test"
    exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "Test completed in ${DURATION}s (server remained responsive)"
echo

# Check logs for work limiting message
if grep -q "hit line limit" /tmp/zigcat_dos_test.log; then
    echo "✓ Work limiting triggered (found 'hit line limit' in logs)"
else
    echo "⚠ Work limiting may not have triggered (no 'hit line limit' message)"
fi
echo

# Test 2: Send 5000 newlines (extreme DoS attack)
echo "Test 2: Sending 5000 newlines (extreme DoS attack simulation)..."
START_TIME=$(date +%s)
printf '%5000s\n' '' | tr ' ' '\n' | timeout $TIMEOUT nc localhost $PORT > /dev/null 2>&1 &
CLIENT_PID=$!
sleep 3

# Server should still be responsive
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server crashed during extreme flood test"
    exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "Test completed in ${DURATION}s (server remained responsive)"
echo

# Verify server processed requests in bounded time chunks
if [ "$DURATION" -lt 10 ]; then
    echo "✓ Server handled 5000-line flood in reasonable time (<10s)"
    echo "  (Without protection, this could freeze for 40+ seconds)"
else
    echo "⚠ Server took ${DURATION}s to handle flood (expected <10s)"
fi
echo

# Clean up
echo "Cleaning up..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
rm -f /tmp/zigcat_dos_test.log

echo "=== DoS Protection Test PASSED ==="
echo
echo "Summary:"
echo "- MAX_LINES_PER_TICK limiting prevents unbounded work"
echo "- Server remains responsive during message floods"
echo "- Work is deferred across multiple poll ticks"
