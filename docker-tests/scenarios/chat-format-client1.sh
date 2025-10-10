#!/bin/bash
# Chat Mode Test - Message Formatting (Alice)
set -e

SERVER_IP=172.28.4.10
SERVER_PORT=9004
RESULT_FILE=/results/chat-format-client1.txt

echo "Alice: Connecting to chat server for message formatting test..."

# Connect and set nickname, then send message
{
    sleep 1
    echo "alice"
    sleep 2  # Wait for bob
    echo "Hello Bob!"
    sleep 2
} | zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
CLIENT_PID=$!

sleep 6
kill $CLIENT_PID 2>/dev/null || true

# Should see bob's formatted message: "[bob] Hi Alice!"
if grep -q "\[bob\]" $RESULT_FILE && grep -q "Hi Alice" $RESULT_FILE; then
    echo "✅ PASS: Alice received formatted message from Bob"
    echo "PASS" > /results/chat-format-result.txt
    exit 0
else
    echo "❌ FAIL: Message formatting not working"
    cat $RESULT_FILE
    echo "FAIL" > /results/chat-format-result.txt
    exit 1
fi
