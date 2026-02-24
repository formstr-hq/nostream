#!/bin/bash
# Add a new storage node to the nostream coordinator.
#
# Usage:
#   ./scripts/add-storage-node.sh <yggdrasil-addr> <node-name> <db-password> \
#       <from-timestamp> <to-timestamp> [--pubkey <yggdrasil-public-key>]
#
# Arguments:
#   yggdrasil-addr   Storage node's Yggdrasil IPv6 address
#   node-name        Short identifier, e.g. "node1" or "alice-storage"
#   db-password      Password for nostr_ts_relay on the storage node
#   from-timestamp   Unix timestamp — start of partition range (or MINVALUE)
#   to-timestamp     Unix timestamp — end of range (or MAXVALUE)
#   --pubkey KEY     Storage node's Yggdrasil public key.
#                    When provided: added to coordinator's AllowedPublicKeys
#                    whitelist and coordinator yggdrasil is reloaded.
#                    Omit only if you intentionally want an open coordinator.
#
# Examples:
#   # Archive everything before Jan 1 2024 to node1, with whitelist:
#   ./scripts/add-storage-node.sh 200:abcd::1 node1 'securepass' \
#       0 1704067200 --pubkey aabbccddeeff...
#
#   # Open-ended partition (node holds all future data beyond a cutoff):
#   ./scripts/add-storage-node.sh 200:ef01::1 node2 'securepass2' \
#       1704067200 MAXVALUE --pubkey 112233445566...

set -euo pipefail

YGG_ADDR="${1:?Usage: $0 <yggdrasil-addr> <node-name> <db-password> <from-ts> <to-ts> [--pubkey KEY]}"
NODE_NAME="${2:?node-name required}"
DB_PASSWORD="${3:?db-password required}"
FROM_TS="${4:?from-timestamp required}"
TO_TS="${5:?to-timestamp required}"

# Parse optional --pubkey flag
STORAGE_PUBKEY=""
shift 5
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) STORAGE_PUBKEY="${2:?--pubkey requires a value}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

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
# 1. Yggdrasil whitelist update (if pubkey provided)
# ------------------------------------------------------------------ #
if [ -n "$STORAGE_PUBKEY" ]; then
  if [ ! -f "$YGG_CONFIG" ]; then
    echo "ERROR: Yggdrasil config not found at ${YGG_CONFIG}"
    echo "Has the coordinator started at least once?"
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for whitelist management (apt install jq)"
    exit 1
  fi

  echo "Adding ${NODE_NAME} (${STORAGE_PUBKEY}) to Yggdrasil whitelist..."

  # Check for duplicate
  EXISTING=$(jq --arg k "$STORAGE_PUBKEY" '.AllowedPublicKeys | index($k)' "$YGG_CONFIG")
  if [ "$EXISTING" != "null" ]; then
    echo "Key already in whitelist — skipping Yggdrasil update."
  else
    jq --arg k "$STORAGE_PUBKEY" \
      '.AllowedPublicKeys += [$k]' \
      "$YGG_CONFIG" > "${YGG_CONFIG}.tmp" && mv "${YGG_CONFIG}.tmp" "$YGG_CONFIG"

    # Record name→key mapping for removal later
    jq --arg name "$NODE_NAME" --arg key "$STORAGE_PUBKEY" \
      '.[$name] = $key' \
      "$YGG_NODES" > "${YGG_NODES}.tmp" && mv "${YGG_NODES}.tmp" "$YGG_NODES"

    echo "Reloading Yggdrasil coordinator..."
    docker restart "$YGG_CONTAINER"
    echo "Yggdrasil reloaded. Whitelist now has $(jq '.AllowedPublicKeys | length' "$YGG_CONFIG") key(s)."
  fi
else
  echo "WARNING: --pubkey not provided. ${NODE_NAME} can peer without whitelist restriction."
fi

# ------------------------------------------------------------------ #
# 2. Register node in PostgreSQL via FDW + attach as partition
# ------------------------------------------------------------------ #
sql_from=$([ "$FROM_TS" = "MINVALUE" ] && echo "MINVALUE" || echo "$FROM_TS")
sql_to=$([ "$TO_TS"   = "MAXVALUE" ] && echo "MAXVALUE" || echo "$TO_TS")

echo ""
echo "Registering storage node in PostgreSQL..."

export PGPASSWORD="$DB_PASS"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<SQL
CREATE SERVER IF NOT EXISTS storage_${NODE_NAME}
  FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (
    host '${YGG_ADDR}',
    port '5432',
    dbname 'nostr_ts_relay',
    -- Allows PostgreSQL to query this node in parallel with other partitions.
    -- Without this, multi-partition REQ queries are sequential (additive latency).
    async_capable 'true',
    -- How many rows to fetch per round-trip from the remote.
    -- 1000 suits relay workloads where REQ can return many events.
    fetch_size '1000'
  );

CREATE USER MAPPING IF NOT EXISTS FOR ${DB_USER}
  SERVER storage_${NODE_NAME}
  OPTIONS (user 'nostr_ts_relay', password '${DB_PASSWORD}');

CREATE FOREIGN TABLE IF NOT EXISTS events_archive_${NODE_NAME} (
  id                   uuid,
  event_id             bytea         NOT NULL,
  event_pubkey         bytea         NOT NULL,
  event_kind           integer       NOT NULL,
  event_created_at     integer       NOT NULL,
  event_content        text          NOT NULL,
  event_tags           jsonb,
  event_signature      bytea         NOT NULL,
  first_seen           timestamp,
  deleted_at           timestamp,
  remote_address       text,
  expires_at           integer,
  event_deduplication  jsonb
)
  SERVER storage_${NODE_NAME}
  OPTIONS (table_name 'events_data');

ALTER TABLE events
  ATTACH PARTITION events_archive_${NODE_NAME}
  FOR VALUES FROM (${sql_from}) TO (${sql_to});

SELECT 'Storage node ${NODE_NAME} attached.' AS result;
SQL

echo ""
echo "Done. Verify partitions:"
echo "  psql -h $DB_HOST -U $DB_USER -d $DB_NAME \\"
echo "    -c \"SELECT inhrelid::regclass, pg_get_expr(c.relpartbound, c.oid) FROM pg_inherits JOIN pg_class c ON inhrelid=c.oid WHERE inhparent='events'::regclass;\""
