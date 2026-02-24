#!/bin/bash
# Detach a storage node from the coordinator.
# Data on the remote node is NOT deleted — the node just stops being queried.
# Re-attach anytime with add-storage-node.sh.
#
# Usage:
#   ./scripts/remove-storage-node.sh <node-name>

set -euo pipefail

NODE_NAME="${1:?Usage: $0 <node-name>}"

if ! echo "$NODE_NAME" | grep -qE '^[a-zA-Z0-9_]+$'; then
  echo "ERROR: node-name must contain only letters, numbers, and underscores"
  exit 1
fi

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-nostr_ts_relay}"
DB_NAME="${DB_NAME:-nostr_ts_relay}"
DB_PASS="${DB_COORDINATOR_PASSWORD:-nostr_ts_relay}"

YGG_CONFIG="${YGG_CONFIG:-./yggdrasil-config/yggdrasil.conf}"
YGG_NODES="${YGG_NODES:-./yggdrasil-config/nodes.json}"
YGG_CONTAINER="${YGG_CONTAINER:-nostream-yggdrasil}"

# ------------------------------------------------------------------ #
# 1. Remove from Yggdrasil whitelist if key is recorded
# ------------------------------------------------------------------ #
if [ -f "$YGG_NODES" ] && [ -f "$YGG_CONFIG" ]; then
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required (apt install jq)"
    exit 1
  fi

  STORED_KEY=$(jq -r --arg name "$NODE_NAME" '.[$name] // empty' "$YGG_NODES")

  if [ -n "$STORED_KEY" ]; then
    echo "Removing ${NODE_NAME} (${STORED_KEY}) from Yggdrasil whitelist..."

    jq --arg k "$STORED_KEY" \
      '.AllowedPublicKeys -= [$k]' \
      "$YGG_CONFIG" > "${YGG_CONFIG}.tmp" && mv "${YGG_CONFIG}.tmp" "$YGG_CONFIG"

    jq --arg name "$NODE_NAME" \
      'del(.[$name])' \
      "$YGG_NODES" > "${YGG_NODES}.tmp" && mv "${YGG_NODES}.tmp" "$YGG_NODES"

    REMAINING=$(jq '.AllowedPublicKeys | length' "$YGG_CONFIG")
    echo "Reloading Yggdrasil coordinator..."
    docker restart "$YGG_CONTAINER"
    echo "Yggdrasil reloaded. Whitelist now has ${REMAINING} key(s)."

    if [ "$REMAINING" -eq 0 ]; then
      echo "WARNING: Whitelist is now empty — any Yggdrasil node can peer."
    fi
  else
    echo "No Yggdrasil key recorded for ${NODE_NAME} — skipping whitelist update."
  fi
fi

# ------------------------------------------------------------------ #
# 2. Detach partition and remove FDW objects
# ------------------------------------------------------------------ #
echo ""
echo "Detaching storage node from PostgreSQL..."

export PGPASSWORD="$DB_PASS"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<SQL
ALTER TABLE events
  DETACH PARTITION events_archive_${NODE_NAME} CONCURRENTLY;

DROP FOREIGN TABLE IF EXISTS events_archive_${NODE_NAME};
DROP USER MAPPING IF EXISTS FOR ${DB_USER} SERVER storage_${NODE_NAME};
DROP SERVER IF EXISTS storage_${NODE_NAME};

SELECT 'Storage node ${NODE_NAME} detached.' AS result;
SQL
