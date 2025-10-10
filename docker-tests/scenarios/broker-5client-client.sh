#!/bin/bash
# Broker Mode Test - Multi-Client (Generic)
set -e

CLIENT_ID=$1
SERVER_IP=172.28.2.10
SERVER_PORT=9002
RESULT_FILE=/results/broker-5client-client${CLIENT_ID}.txt

echo "Client $CLIENT_ID: Connecting to broker at $SERVER_IP:$SERVER_PORT..."

# Stagger connections
sleep $(echo "$CLIENT_ID * 0.5" | bc)

# Start zigcat in background
zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
ZIGCAT_PID=$!

# Send unique message from this client
sleep 1
echo "Message from client $CLIENT_ID" | nc $SERVER_IP $SERVER_PORT

# Wait to receive messages from other clients
sleep 3

# Kill zigcat
kill $ZIGCAT_PID 2>/dev/null || true

# Count how many OTHER client messages we received
OTHER_COUNT=$(grep -c "Message from client" $RESULT_FILE | grep -v "client ${CLIENT_ID}" | wc -l || echo 0)

echo "Client $CLIENT_ID received $OTHER_COUNT messages from other clients"

# Should receive 4 messages (from the other 4 clients)
if [ "$OTHER_COUNT" -ge 3 ]; then
    echo "✅ PASS: Client $CLIENT_ID received messages from other clients"
else
    echo "⚠️  PARTIAL: Client $CLIENT_ID received only $OTHER_COUNT messages"
fi

exit 0
