#!/bin/bash
# Maximum Client Limit Test (Chat Mode)
set -e

SERVER_IP=172.28.7.10
SERVER_PORT=9007
RESULT_FILE=/results/maxclients-chat-test.txt

echo "Testing max clients limit (2) on chat server..."

# Connect 2 clients (at limit) with nicknames
{
    sleep 1
    echo "alice"
    sleep 10
} | zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID1=$!
sleep 1

{
    sleep 1
    echo "bob"
    sleep 10
} | zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID2=$!
sleep 2

# Try to connect 3rd client (should be rejected)
{
    sleep 1
    echo "charlie"
    sleep 5
} | timeout 3 zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
PID3=$!
sleep 3

# Check if 3rd connection was rejected
if ps -p $PID3 > /dev/null 2>&1; then
    echo "❌ FAIL: 3rd client was not rejected (limit not enforced)"
    kill $PID1 $PID2 $PID3 2>/dev/null || true
    echo "FAIL" > /results/maxclients-chat-result.txt
    exit 1
else
    echo "✅ PASS: 3rd client was rejected (limit enforced)"
    kill $PID1 $PID2 2>/dev/null || true
    echo "PASS" > /results/maxclients-chat-result.txt
    exit 0
fi
