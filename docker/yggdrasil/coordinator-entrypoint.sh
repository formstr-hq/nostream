#!/bin/sh
set -e

CONFIG=/etc/yggdrasil/yggdrasil.conf
NODES_FILE=/etc/yggdrasil/nodes.json

# Generate config on first run — keys persist via bind-mounted volume
if [ ! -f "$CONFIG" ]; then
  echo "[yggdrasil] Generating new coordinator config..."
  yggdrasil -genconf > "$CONFIG"

  LISTEN_PORT="${YGGDRASIL_LISTEN_PORT:-12345}"
  jq --arg port "$LISTEN_PORT" \
    '.Listen = ["tcp://0.0.0.0:\($port)"]' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

  echo "[yggdrasil] Config written. Listen port: ${LISTEN_PORT}"
fi

# Initialise node registry if not present
if [ ! -f "$NODES_FILE" ]; then
  echo '{}' > "$NODES_FILE"
fi

# Start yggdrasil in background so we can query it
yggdrasil -useconffile "$CONFIG" &
YGG_PID=$!

# Wait for admin socket to be available
echo "[yggdrasil] Waiting for daemon..."
for i in $(seq 1 30); do
  SELF=$(yggdrasilctl getself 2>/dev/null || true)
  if [ -n "$SELF" ]; then break; fi
  sleep 1
done

ADDR=$(echo "$SELF" | jq -r '.address // "unknown"')
PUBKEY=$(echo "$SELF" | jq -r '.key // "unknown"')

WHITELIST_COUNT=$(jq '.AllowedPublicKeys | length' "$CONFIG")

echo ""
echo "============================================================"
echo " Yggdrasil Coordinator"
echo " Address   : ${ADDR}"
echo " Public key: ${PUBKEY}"
echo " Peer addr : tcp://YOUR_PUBLIC_IP:${YGGDRASIL_LISTEN_PORT:-12345}"
echo ""
echo " Share the public key + peer address with storage operators."
echo " They need both to configure COORDINATOR_PUBLIC_KEY and"
echo " COORDINATOR_PEER in their .env file."
echo ""
if [ "$WHITELIST_COUNT" -eq 0 ]; then
  echo " WARNING: AllowedPublicKeys is empty — any Yggdrasil node"
  echo " can currently peer with this coordinator."
  echo " Run add-storage-node.sh with --pubkey to enable the whitelist."
fi
echo "============================================================"
echo ""

wait $YGG_PID
