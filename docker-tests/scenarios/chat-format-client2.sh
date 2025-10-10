#!/bin/bash
# Chat Mode Test - Message Formatting (Bob)
set -e

SERVER_IP=172.28.4.10
SERVER_PORT=9004

echo "Bob: Connecting to chat server for message formatting test..."

sleep 2  # Let alice connect first

# Connect, set nickname, and send formatted message
{
    sleep 1
    echo "bob"
    sleep 2
    echo "Hi Alice!"
    sleep 2
} | zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
CLIENT_PID=$!

sleep 6
kill $CLIENT_PID 2>/dev/null || true

echo "Bob: Sent formatted message"
exit 0
