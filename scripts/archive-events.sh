#!/bin/bash
# Move events older than a cutoff from events_hot to a registered storage node.
#
# Safe to interrupt and resume:
#   - Data is NEVER deleted from events_hot until it is confirmed present on the remote
#   - Each batch is committed independently; a crash loses at most one batch of inserts
#     (which will be skipped on resume due to ON CONFLICT DO NOTHING)
#
# Usage:
#   ./scripts/archive-events.sh --node <node-name> --cutoff <unix-timestamp>
#   ./scripts/archive-events.sh --node <node-name> --older-than <days>
#
# Options:
#   --node         Name of the registered storage node (from add-storage-node.sh)
#   --cutoff       Archive events with event_created_at < this Unix timestamp
#   --older-than   Archive events older than N days (alternative to --cutoff)
#   --batch-size   Rows per transaction (default: 5000)
#   --batch-window Seconds of event_created_at range per batch (default: 86400 = 1 day)
#   --dry-run      Print what would happen without making any changes
#
# Examples:
#   # Archive everything older than 90 days to node1
#   ./scripts/archive-events.sh --node node1 --older-than 90
#
#   # Archive everything before Jan 1 2024 to node1, in batches of 10 000
#   ./scripts/archive-events.sh --node node1 --cutoff 1704067200 --batch-size 10000

set -euo pipefail

# ------------------------------------------------------------------ #
# Argument parsing
# ------------------------------------------------------------------ #
NODE_NAME=""
CUTOFF=""
OLDER_THAN=""
BATCH_SIZE=5000
BATCH_WINDOW=86400   # 1 day in seconds — width of each time-range batch
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --node)         NODE_NAME="${2:?--node requires a value}";    shift 2 ;;
    --cutoff)       CUTOFF="${2:?--cutoff requires a value}";     shift 2 ;;
    --older-than)   OLDER_THAN="${2:?--older-than requires N days}"; shift 2 ;;
    --batch-size)   BATCH_SIZE="${2:?--batch-size requires a value}"; shift 2 ;;
    --batch-window) BATCH_WINDOW="${2:?--batch-window requires a value}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[ -z "$NODE_NAME" ] && { echo "ERROR: --node is required"; exit 1; }

if [ -n "$OLDER_THAN" ]; then
  CUTOFF=$(date -d "-${OLDER_THAN} days" +%s 2>/dev/null || \
           date -v "-${OLDER_THAN}d" +%s 2>/dev/null || \
           { echo "ERROR: Could not compute date. Use --cutoff with an explicit timestamp."; exit 1; })
fi

[ -z "$CUTOFF" ] && { echo "ERROR: --cutoff or --older-than is required"; exit 1; }

if ! echo "$NODE_NAME" | grep -qE '^[a-zA-Z0-9_]+$'; then
  echo "ERROR: node-name must contain only letters, numbers, and underscores"
  exit 1
fi

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-nostr_ts_relay}"
DB_NAME="${DB_NAME:-nostr_ts_relay}"
DB_PASS="${DB_COORDINATOR_PASSWORD:-nostr_ts_relay}"

export PGPASSWORD="$DB_PASS"

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A"

# ------------------------------------------------------------------ #
# Verify the target partition exists and is a foreign table
# ------------------------------------------------------------------ #
PARTITION_EXISTS=$($PSQL -c "
  SELECT COUNT(*) FROM pg_class c
  JOIN pg_inherits i ON i.inhrelid = c.oid
  WHERE i.inhparent = 'events'::regclass
    AND c.relname = 'events_archive_${NODE_NAME}';" 2>/dev/null || echo 0)

if [ "$PARTITION_EXISTS" -eq 0 ]; then
  echo "ERROR: Partition events_archive_${NODE_NAME} not found."
  echo "Run add-storage-node.sh first to register this node."
  exit 1
fi

# ------------------------------------------------------------------ #
# Count rows to archive
# ------------------------------------------------------------------ #
echo "Counting events in events_hot older than $(date -d @${CUTOFF} 2>/dev/null || date -r ${CUTOFF})..."

TOTAL=$($PSQL -c "
  SELECT COUNT(*) FROM events_hot
  WHERE event_created_at < ${CUTOFF};" 2>/dev/null)

if [ "$TOTAL" -eq 0 ]; then
  echo "No events older than cutoff found in events_hot. Nothing to do."
  exit 0
fi

MIN_TS=$($PSQL -c "SELECT MIN(event_created_at) FROM events_hot WHERE event_created_at < ${CUTOFF};")
MAX_TS=$($PSQL -c "SELECT MAX(event_created_at) FROM events_hot WHERE event_created_at < ${CUTOFF};")

echo ""
echo "Archive plan:"
echo "  Target node   : ${NODE_NAME}"
echo "  Partition      : events_archive_${NODE_NAME}"
echo "  Cutoff         : ${CUTOFF} ($(date -d @${CUTOFF} 2>/dev/null || date -r ${CUTOFF}))"
echo "  Events to move : ${TOTAL}"
echo "  Time range     : ${MIN_TS} → ${MAX_TS}"
echo "  Batch window   : ${BATCH_WINDOW}s of event_created_at per batch"
echo "  Batch size     : ${BATCH_SIZE} rows max per transaction"
echo "  Dry run        : ${DRY_RUN}"
echo ""

# Rough timing estimate
# INSERT over FDW: ~10 000-30 000 rows/min depending on network
# DELETE with index updates: ~5 000-15 000 rows/min
# Combined: ~5 000-10 000 rows/min (conservative)
ESTIMATE_MIN=$(( TOTAL / 7500 ))
ESTIMATE_MAX=$(( TOTAL / 3000 ))
echo "Estimated time: ${ESTIMATE_MIN}–${ESTIMATE_MAX} minutes"
echo "(varies by network latency to storage node and local disk speed)"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "Dry run — no changes made."
  exit 0
fi

read -r -p "Proceed? [y/N] " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ------------------------------------------------------------------ #
# Archival loop: iterate over time windows
# ------------------------------------------------------------------ #
BATCH_START=$MIN_TS
ARCHIVED=0
DELETED=0
START_TIME=$(date +%s)

echo ""
echo "Starting archival..."

while [ "$BATCH_START" -lt "$CUTOFF" ]; do
  BATCH_END=$(( BATCH_START + BATCH_WINDOW ))
  [ "$BATCH_END" -gt "$CUTOFF" ] && BATCH_END=$CUTOFF

  # Count rows in this time window
  WINDOW_COUNT=$($PSQL -c "
    SELECT COUNT(*) FROM events_hot
    WHERE event_created_at >= ${BATCH_START}
      AND event_created_at <  ${BATCH_END};" 2>/dev/null)

  if [ "$WINDOW_COUNT" -eq 0 ]; then
    BATCH_START=$BATCH_END
    continue
  fi

  # Copy window to remote in sub-batches if needed
  SUB_OFFSET=0
  WINDOW_COPIED=0

  while [ "$SUB_OFFSET" -lt "$WINDOW_COUNT" ]; do
    COPIED=$($PSQL -c "
      WITH batch AS (
        SELECT id, event_id, event_pubkey, event_kind, event_created_at,
               event_content, event_tags, event_signature, first_seen,
               deleted_at, remote_address, expires_at, event_deduplication
        FROM events_hot
        WHERE event_created_at >= ${BATCH_START}
          AND event_created_at <  ${BATCH_END}
        ORDER BY event_created_at
        LIMIT ${BATCH_SIZE} OFFSET ${SUB_OFFSET}
      )
      INSERT INTO events_archive_${NODE_NAME}
        SELECT * FROM batch
      ON CONFLICT (event_id) DO NOTHING;
      SELECT ${BATCH_SIZE};" 2>/dev/null || echo 0)

    WINDOW_COPIED=$(( WINDOW_COPIED + BATCH_SIZE ))
    ARCHIVED=$(( ARCHIVED + BATCH_SIZE ))
    SUB_OFFSET=$(( SUB_OFFSET + BATCH_SIZE ))

    # Progress
    ELAPSED=$(( $(date +%s) - START_TIME ))
    RATE=$(( ELAPSED > 0 ? ARCHIVED / ELAPSED : 0 ))
    REMAINING=$(( TOTAL - ARCHIVED ))
    ETA=$(( RATE > 0 ? REMAINING / RATE : 0 ))
    printf "\r  Copied: %d / %d  |  %.0f rows/s  |  ETA: %ds        " \
      "$ARCHIVED" "$TOTAL" "$RATE" "$ETA"
  done

  # Delete from events_hot only after remote copy is confirmed
  # Use the same window to ensure we only delete what was just copied
  REMOVED=$($PSQL -c "
    WITH removed AS (
      DELETE FROM events_hot
      WHERE event_created_at >= ${BATCH_START}
        AND event_created_at <  ${BATCH_END}
      RETURNING 1
    )
    SELECT COUNT(*) FROM removed;" 2>/dev/null || echo 0)

  DELETED=$(( DELETED + REMOVED ))

  BATCH_START=$BATCH_END
done

echo ""
echo ""
ELAPSED=$(( $(date +%s) - START_TIME ))
echo "Done."
echo "  Rows copied to remote : ${ARCHIVED}"
echo "  Rows deleted locally  : ${DELETED}"
echo "  Elapsed               : ${ELAPSED}s"
echo ""

if [ "$ARCHIVED" -ne "$DELETED" ]; then
  echo "WARNING: copied and deleted counts differ (${ARCHIVED} vs ${DELETED})."
  echo "This can happen if events_hot received new inserts in the archived range"
  echo "during the job (unlikely for old data). Verify with:"
  echo "  psql -h $DB_HOST -U $DB_USER -d $DB_NAME \\"
  echo "    -c \"SELECT COUNT(*) FROM events_hot WHERE event_created_at < ${CUTOFF};\""
fi

echo "Consider narrowing events_hot's lower bound to exclude the archived range."
echo "See DISTRIBUTED-STORAGE.md — 'Narrowing events_hot' section."
