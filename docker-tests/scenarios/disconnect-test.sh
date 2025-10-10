#!/bin/bash
# Client Disconnection Cleanup Test
set -e

SERVER_IP=172.28.5.10
SERVER_PORT=9005
RESULT_FILE=/results/disconnect-test.txt

echo "Testing client disconnection cleanup..."

# Connect 3 clients
echo "Connecting client 1..."
echo "Client 1 data" | zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID1=$!
sleep 0.5

echo "Connecting client 2..."
zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
PID2=$!
sleep 0.5

echo "Connecting client 3..."
echo "Client 3 data" | zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID3=$!
sleep 1

# Disconnect client 1
echo "Disconnecting client 1..."
kill $PID1 2>/dev/null || true
sleep 1

# Send from client 3, should be received by client 2
echo "Test message after disconnect" | nc $SERVER_IP $SERVER_PORT
sleep 2

# Cleanup
kill $PID2 $PID3 2>/dev/null || true

# Verify client 2 received the message
if grep -q "Test message after disconnect" $RESULT_FILE; then
    echo "✅ PASS: Messages still relay after client disconnection"
    echo "PASS" > /results/disconnect-result.txt
    exit 0
else
    echo "❌ FAIL: Message relay broken after disconnection"
    echo "FAIL" > /results/disconnect-result.txt
    exit 1
fi
