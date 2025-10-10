#!/bin/bash
# Maximum Client Limit Test (Broker Mode)
set -e

SERVER_IP=172.28.6.10
SERVER_PORT=9006
RESULT_FILE=/results/maxclients-broker-test.txt

echo "Testing max clients limit (3) on broker server..."

# Connect 3 clients (at limit)
zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID1=$!
sleep 0.5

zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID2=$!
sleep 0.5

zigcat $SERVER_IP $SERVER_PORT > /dev/null 2>&1 &
PID3=$!
sleep 1

# Try to connect 4th client (should be rejected)
timeout 2 zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
PID4=$!
sleep 2

# Check if 4th connection was rejected
if ps -p $PID4 > /dev/null 2>&1; then
    echo "❌ FAIL: 4th client was not rejected (limit not enforced)"
    kill $PID1 $PID2 $PID3 $PID4 2>/dev/null || true
    echo "FAIL" > /results/maxclients-broker-result.txt
    exit 1
else
    echo "✅ PASS: 4th client was rejected (limit enforced)"
    kill $PID1 $PID2 $PID3 2>/dev/null || true
    echo "PASS" > /results/maxclients-broker-result.txt
    exit 0
fi
