#!/bin/bash
# Chat Mode Test - Client 1 (Alice)
set -e

SERVER_IP=172.28.3.10
SERVER_PORT=9003
RESULT_FILE=/results/chat-nickname-client1.txt

echo "Alice: Connecting to chat server at $SERVER_IP:$SERVER_PORT..."

# Connect to chat and set nickname
{
    sleep 1
    echo "alice"
    sleep 3  # Wait for bob to join
} | zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
CLIENT_PID=$!

sleep 5
kill $CLIENT_PID 2>/dev/null || true

# Verify we received join notification for bob
if grep -iq "bob" $RESULT_FILE && grep -iq "joined" $RESULT_FILE; then
    echo "✅ PASS: Alice received bob's join notification"
    echo "PASS" > /results/chat-nickname-result.txt
    exit 0
else
    echo "❌ FAIL: Alice did not receive join notification"
    cat $RESULT_FILE
    echo "FAIL" > /results/chat-nickname-result.txt
    exit 1
fi
