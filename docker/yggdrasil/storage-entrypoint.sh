#!/bin/sh
set -e

CONFIG=/etc/yggdrasil/yggdrasil.conf

if [ -z "$COORDINATOR_PEER" ]; then
  echo "[yggdrasil] ERROR: COORDINATOR_PEER is required."
  echo "[yggdrasil] Example: COORDINATOR_PEER=tcp://1.2.3.4:12345"
  exit 1
fi

if [ -z "$COORDINATOR_PUBLIC_KEY" ]; then
  echo "[yggdrasil] ERROR: COORDINATOR_PUBLIC_KEY is required."
  echo "[yggdrasil] Get this from the coordinator's startup log."
  exit 1
fi

# Generate config on first run — keys persist via bind-mounted volume
if [ ! -f "$CONFIG" ]; then
  echo "[yggdrasil] Generating new storage node config..."
  yggdrasil -genconf > "$CONFIG"

  # Peer to coordinator and restrict inbound connections to coordinator only
  jq --arg peer "$COORDINATOR_PEER" \
     --arg key  "$COORDINATOR_PUBLIC_KEY" \
     '.Peers = [$peer] | .AllowedPublicKeys = [$key]' \
     "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

  echo "[yggdrasil] Config written."
  echo "[yggdrasil] Peer        : ${COORDINATOR_PEER}"
  echo "[yggdrasil] Allowed key : ${COORDINATOR_PUBLIC_KEY}"
fi

# Start yggdrasil in background
yggdrasil -useconffile "$CONFIG" &
YGG_PID=$!

# Wait for daemon
echo "[yggdrasil] Waiting for daemon..."
for i in $(seq 1 30); do
  SELF=$(yggdrasilctl getself 2>/dev/null || true)
  if [ -n "$SELF" ]; then break; fi
  sleep 1
done

ADDR=$(echo "$SELF" | jq -r '.address // "unknown"')
PUBKEY=$(echo "$SELF" | jq -r '.key // "unknown"')

echo ""
echo "============================================================"
echo " Yggdrasil Storage Node"
echo " Address   : ${ADDR}"
echo " Public key: ${PUBKEY}"
echo " Coordinator peer: ${COORDINATOR_PEER}"
echo ""
echo " Share your Address and Public key with the coordinator"
echo " operator so they can register this node:"
echo ""
echo "   ./scripts/add-storage-node.sh \\"
echo "     ${ADDR} <node-name> <db-password> \\"
echo "     <from-ts> <to-ts> \\"
echo "     --pubkey ${PUBKEY}"
echo "============================================================"
echo ""

wait $YGG_PID
