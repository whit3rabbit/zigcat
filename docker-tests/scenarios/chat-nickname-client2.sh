#!/bin/bash
# Chat Mode Test - Client 2 (Bob)
set -e

SERVER_IP=172.28.3.10
SERVER_PORT=9003
RESULT_FILE=/results/chat-nickname-client2.txt

echo "Bob: Connecting to chat server at $SERVER_IP:$SERVER_PORT..."

sleep 2  # Let alice connect first

# Connect to chat and set nickname
{
    sleep 1
    echo "bob"
    sleep 2
} | zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
CLIENT_PID=$!

sleep 4
kill $CLIENT_PID 2>/dev/null || true

echo "Bob: Disconnected"
exit 0
