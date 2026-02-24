# Distributed Storage for nostream

This guide covers running nostream with remote storage nodes — PostgreSQL instances on other machines, connected over an encrypted [Yggdrasil](https://yggdrasil-network.github.io/) mesh network. Events are distributed across nodes using PostgreSQL's native table partitioning and Foreign Data Wrappers (FDW). No extensions or third-party tools are required.

```
[Nostr clients]
      │ WebSocket
      ▼
[nostream relay]
      │
      ▼
[nostream-db] ── events (partitioned)
  local         ├── events_hot       → local disk   (recent data, write buffer)
                ├── events_archive_node1 → Yggdrasil → storage node 1 (remote)
                └── events_archive_node2 → Yggdrasil → storage node 2 (remote)
```

REQ queries fan out to all relevant partitions automatically — no application changes, no schema changes visible to the relay.

---

## How it works

| Concept | Implementation |
|---|---|
| Network mesh | Yggdrasil — each node gets a stable IPv6 address derived from its public key |
| NAT traversal | Storage nodes make outbound TCP connections to coordinator; no inbound port forwarding needed on storage side |
| Data distribution | PostgreSQL `RANGE PARTITION BY event_created_at` with remote partitions via `postgres_fdw` |
| Whitelist | Yggdrasil `AllowedPublicKeys` — unlisted nodes cannot peer at the network layer |
| Coordinator | The existing `nostream-db` instance — stays local, routes queries, holds hot data |
| Storage node | Plain `postgres` container — no extensions, no special config |

---

## Standard relay startup (unchanged)

If you only want to run the relay without distributed storage, nothing has changed:

```bash
./scripts/start
```

The Yggdrasil container (`nostream-yggdrasil`) starts alongside the relay. Until you register storage nodes, all data stays in `events_hot` on the local disk.

---

## Coordinator setup

### 1. Prerequisites

- Docker v20.10+ and Docker Compose v2.10+ installed from the [official guide](https://docs.docker.com/engine/install/)
- Linux host with `/dev/net/tun` available (standard on all modern kernels)
- `jq` installed on the host (used by the management scripts)

```bash
# Debian/Ubuntu
sudo apt install jq

# Arch
sudo pacman -S jq
```

### 2. Enable IPv6 in the Docker daemon (one-time)

This allows the `nostream-db` container to make outbound FDW connections to storage nodes over their Yggdrasil IPv6 addresses.

Edit `/etc/docker/daemon.json` (create it if it does not exist):

```json
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
```

Restart Docker:

```bash
sudo systemctl restart docker
```

### 3. Start the relay

```bash
./scripts/start
```

On first start, Yggdrasil generates a private key (stored in `yggdrasil-config/yggdrasil.conf`) and prints the coordinator's identity:

```
============================================================
 Yggdrasil Coordinator
 Address   : 200:abcd:1234::1
 Public key: aabbccddeeff00112233...
 Peer addr : tcp://YOUR_PUBLIC_IP:12345
============================================================
```

**Write down the public key and peer address.** Storage node operators need both.

The `yggdrasil-config/` directory is bind-mounted — keys persist across restarts. It is excluded from git.

### 4. Open the Yggdrasil peer port

Storage nodes connect to your coordinator over TCP. Open port `12345` (or whatever `YGGDRASIL_LISTEN_PORT` is set to) in your firewall:

```bash
# ufw
sudo ufw allow 12345/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 12345 -j ACCEPT
```

Storage nodes do **not** need any inbound ports open — they connect outbound to you.

---

## Storage node setup

Run these steps on the remote machine that will provide storage.

### 1. Prerequisites

- Docker v20.10+ and Docker Compose v2.10+
- Linux host with `/dev/net/tun`
- The coordinator's **public key** and **TCP peer address** (from the coordinator startup log)

### 2. Get the files

Copy `docker-compose.storage.yml`, `docker/`, `storage/`, and `scripts/storage-init.sql` from the nostream repository onto the storage machine. Or clone the full repo — only those files are used.

### 3. Create a `.env` file

```bash
# .env on the storage node machine

# TCP address of the coordinator's Yggdrasil node
COORDINATOR_PEER=tcp://COORDINATOR_PUBLIC_IP:12345

# Coordinator's Yggdrasil public key (from coordinator startup log)
COORDINATOR_PUBLIC_KEY=aabbccddeeff00112233...

# Password for the nostr_ts_relay PostgreSQL user on this node.
# Choose a strong password — share it with the coordinator operator.
STORAGE_DB_PASSWORD=choose-a-strong-password
```

### 4. Start the storage node

```bash
docker compose -f docker-compose.storage.yml up -d
```

On first start, Yggdrasil generates keys and prints the storage node's identity:

```
============================================================
 Yggdrasil Storage Node
 Address   : 200:ef01:5678::1
 Public key: 998877665544332211...

 Give the coordinator operator this address to register this node:
   ./scripts/add-storage-node.sh \
     200:ef01:5678::1 <node-name> <db-password> \
     <from-ts> <to-ts> \
     --pubkey 998877665544332211...
============================================================
```

**Send the coordinator operator:**
- Your Yggdrasil address (`200:ef01:5678::1`)
- Your Yggdrasil public key (`998877665544332211...`)
- Your DB password (`STORAGE_DB_PASSWORD`)
- The time range of events you want to store (see below)

---

## Registering a storage node (run on coordinator machine)

### Understanding partition ranges

Each storage node holds a specific time range of events, defined by Unix timestamps. The coordinator routes inserts and queries to the correct node automatically.

Common patterns:

| Pattern | from | to | Use case |
|---|---|---|---|
| All future events | `$(date +%s)` | `MAXVALUE` | New node handles all events going forward |
| Historical archive | `0` | `1704067200` | Node stores everything before Jan 2024 |
| Specific year | `1704067200` | `1735689600` | Node stores 2024 events |

**Important**: ranges must not overlap with `events_hot` or other registered nodes. When you add a node with a range that overlaps `events_hot`, the script automatically narrows `events_hot` first.

### Register the node

```bash
./scripts/add-storage-node.sh \
  200:ef01:5678::1 \    # storage node Yggdrasil address
  node1 \               # short name (letters, numbers, underscores only)
  'strong-password' \   # STORAGE_DB_PASSWORD from the storage node's .env
  0 \                   # from timestamp (MINVALUE also accepted)
  1704067200 \          # to timestamp (MAXVALUE also accepted)
  --pubkey 998877665544332211...
```

What this does:
1. Adds the storage node's public key to `yggdrasil-config/yggdrasil.conf` under `AllowedPublicKeys`
2. Restarts the coordinator's Yggdrasil container (brief ~2 second interruption to the mesh)
3. Creates a foreign server, user mapping, and foreign table in PostgreSQL
4. Attaches the foreign table as a partition of `events`

From this point, any query to `events` that touches the registered time range is automatically routed to the storage node.

### Verify

```bash
psql -h 127.0.0.1 -U nostr_ts_relay -d nostr_ts_relay -c "
  SELECT
    inhrelid::regclass AS partition,
    pg_get_expr(c.relpartbound, c.oid) AS range
  FROM pg_inherits
  JOIN pg_class c ON inhrelid = c.oid
  WHERE inhparent = 'events'::regclass;"
```

Expected output:
```
        partition         |              range
--------------------------+----------------------------------
 events_hot               | FOR VALUES FROM (1704067200) TO (MAXVALUE)
 events_archive_node1     | FOR VALUES FROM (0) TO (1704067200)
```

Test a query that spans both:
```bash
psql -h 127.0.0.1 -U nostr_ts_relay -d nostr_ts_relay -c "
  EXPLAIN SELECT COUNT(*) FROM events WHERE event_created_at > 0;"
```

You should see both `events_hot` and `events_archive_node1` in the query plan.

---

## Archiving events from events_hot

`scripts/archive-events.sh` moves events older than a cutoff from `events_hot` to a registered storage node. It is safe to interrupt and resume — data is never deleted locally until it is confirmed present on the remote.

```bash
# Archive everything older than 90 days to node1
./scripts/archive-events.sh --node node1 --older-than 90

# Archive everything before a specific timestamp
./scripts/archive-events.sh --node node1 --cutoff 1704067200

# Preview without making changes
./scripts/archive-events.sh --node node1 --older-than 90 --dry-run
```

Options:

| Flag | Default | Description |
|---|---|---|
| `--node` | required | Storage node name (from `add-storage-node.sh`) |
| `--cutoff` | — | Archive events with `event_created_at` below this Unix timestamp |
| `--older-than` | — | Archive events older than N days (alternative to `--cutoff`) |
| `--batch-window` | 86400 | Seconds of `event_created_at` range processed per outer batch (1 day) |
| `--batch-size` | 5000 | Rows per inner transaction |
| `--dry-run` | false | Print the plan without making changes |

### How long does it take?

Two phases happen for each batch: **INSERT to remote** then **DELETE locally**.

| Phase | Typical rate | Bottleneck |
|---|---|---|
| INSERT to remote (FDW over Yggdrasil) | 10 000 – 30 000 rows/min | Network round-trip latency |
| DELETE from events_hot | 5 000 – 15 000 rows/min | Local index updates (7 indexes) |

Combined estimate: **5 000 – 10 000 rows/min**. The script prints a live rate and ETA.

| Events to archive | Estimated time |
|---|---|
| 1 million | 2 – 3 minutes |
| 10 million | 17 – 33 minutes |
| 100 million | 3 – 5 hours |

Run during low-traffic hours. The job does not lock the table — inserts and queries continue during archival. Individual batch transactions hold row-level locks for milliseconds.

### What does NOT get archived

`archive-events.sh` only touches `events_hot`. It does not move:
- Replaceable events — these should stay in `events_hot` permanently because their `ON CONFLICT` upsert relies on the local `replaceable_events_idx`. Filter them out with a cutoff that doesn't cover active replaceable event kinds, or handle them separately.
- `event_tags` — this table stays local always and is unaffected.

### After archival

Run the narrowing procedure below to permanently shrink `events_hot`'s partition range so newly inserted events in the archived range cannot land locally. Until you do, any event inserted with an `event_created_at` in the archived range will go back into `events_hot` (correct by PostgreSQL routing rules but not what you want long-term).

### Scheduling

To archive automatically, add a cron job on the coordinator machine:

```bash
# crontab -e
# Archive events older than 60 days to node1, every Sunday at 02:00
0 2 * * 0 /path/to/nostream/scripts/archive-events.sh --node node1 --older-than 60 --batch-size 5000
```

## Narrowing events_hot (moving historical data to a storage node)

When you register a storage node with a range that overlaps the current `events_hot` partition, you need to split `events_hot` first. Run this SQL on the coordinator's PostgreSQL:

```sql
-- Example: move everything before Jan 1 2024 to node1
-- events_hot currently covers MINVALUE to MAXVALUE

BEGIN;

-- 1. Detach the current hot partition (becomes a standalone table)
ALTER TABLE events DETACH PARTITION events_hot CONCURRENTLY;

-- 2. Rename it temporarily
ALTER TABLE events_hot RENAME TO events_hot_old;

-- 3. Create a new events_hot covering only the range you want to keep local
CREATE TABLE events_hot PARTITION OF events
  FOR VALUES FROM (1704067200) TO (MAXVALUE);

-- Recreate indexes on new events_hot
CREATE INDEX events_hot_pubkey_idx     ON events_hot (event_pubkey);
CREATE INDEX events_hot_kind_idx       ON events_hot (event_kind);
CREATE INDEX events_hot_created_at_idx ON events_hot (event_created_at);
CREATE UNIQUE INDEX events_hot_event_id_idx ON events_hot (event_id);
CREATE INDEX events_hot_tags_gin_idx   ON events_hot USING GIN (event_tags);
CREATE INDEX events_hot_kind_tags_time_idx ON events_hot
  USING GIN (event_kind, event_tags, event_created_at);
CREATE UNIQUE INDEX replaceable_events_idx ON events_hot (event_pubkey, event_kind, event_deduplication)
  WHERE (event_kind = 0 OR event_kind = 3 OR event_kind = 41
    OR (event_kind >= 10000 AND event_kind < 20000)
    OR (event_kind >= 30000 AND event_kind < 40000));

-- 4. Copy historical data into the partitioned table
--    (PostgreSQL routes it to events_archive_node1 automatically)
INSERT INTO events
  SELECT * FROM events_hot_old
  WHERE event_created_at < 1704067200
  ON CONFLICT DO NOTHING;

-- 5. Copy recent data into new events_hot
INSERT INTO events
  SELECT * FROM events_hot_old
  WHERE event_created_at >= 1704067200
  ON CONFLICT DO NOTHING;

-- 6. Drop the old standalone table
DROP TABLE events_hot_old;

COMMIT;
```

Run this during a low-traffic window. For large datasets, run the INSERTs in batches:

```sql
-- Batched copy for large tables
DO $$
DECLARE
  batch_size INT := 10000;
  offset_val INT := 0;
  rows_copied INT;
BEGIN
  LOOP
    INSERT INTO events
      SELECT * FROM events_hot_old
      WHERE event_created_at < 1704067200
      ORDER BY event_created_at
      LIMIT batch_size OFFSET offset_val
      ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS rows_copied = ROW_COUNT;
    EXIT WHEN rows_copied < batch_size;
    offset_val := offset_val + batch_size;
    RAISE NOTICE 'Copied % rows so far', offset_val;
  END LOOP;
END $$;
```

---

## Removing a storage node

```bash
./scripts/remove-storage-node.sh node1
```

What this does:
1. Looks up the node's public key in `yggdrasil-config/nodes.json`
2. Removes it from `AllowedPublicKeys` and restarts Yggdrasil
3. Detaches the partition with `DETACH PARTITION ... CONCURRENTLY` (non-blocking)
4. Drops the foreign table, user mapping, and foreign server

**Data on the remote node is not deleted.** The rows are simply no longer reachable from the coordinator. Re-attach the node at any time with `add-storage-node.sh`.

If the removed node's time range needs to be covered by another node or reclaimed locally, re-run the narrowing procedure above in reverse.

---

## Adding a second storage node

Each node covers a non-overlapping time range. Example with two nodes:

```bash
# node1: events from 2023
./scripts/add-storage-node.sh 200:aaaa::1 node1 'pass1' 1672531200 1704067200 --pubkey key1...

# node2: events from 2024 onward
./scripts/add-storage-node.sh 200:bbbb::1 node2 'pass2' 1704067200 MAXVALUE --pubkey key2...
```

`events_hot` now covers only current-ish data or can be narrowed to a rolling window.

---

## Query fan-out behaviour

When a REQ arrives, PostgreSQL queries every partition that could contain matching rows.

**Partition pruning** eliminates remote nodes automatically when the filter includes `since` or `until`:

```
{"authors": ["abc"], "since": 1704067200}
→ event_created_at >= 1704067200 → only events_hot is queried
```

**Without a time filter**, all partitions are queried:

```
{"authors": ["abc"], "limit": 100}
→ events_hot + every archive partition
```

This is expected — the relay cannot know which nodes hold events for a given author without checking all of them.

### Parallel execution

`async_capable 'true'` is set on every foreign server by `add-storage-node.sh`. This instructs PostgreSQL to query all foreign partitions simultaneously rather than one after another. Total latency is the slowest single node, not the sum.

`fetch_size '1000'` is also set, reducing round-trips when a remote partition returns many rows.

Tag-based filters (`#p`, `#e`) look up matching `event_id`s in the local `event_tags` table first (always local, always fast), then fetch the full event rows from whichever partitions hold them. The local `event_tags` lookup does not require cross-network calls.

## Coordinator node capacity hint

If nodes have different storage capacities, this is metadata for your own planning — PostgreSQL routes by partition range, not by weight. Choose partition boundaries that reflect the available storage on each node.

---

## Troubleshooting

### Yggdrasil not connecting

Check coordinator logs:
```bash
docker logs nostream-yggdrasil
```

Check storage node logs:
```bash
docker compose -f docker-compose.storage.yml logs storage-yggdrasil
```

Confirm the coordinator's TCP port is reachable from the storage node:
```bash
# From the storage machine
nc -zv COORDINATOR_PUBLIC_IP 12345
```

### FDW connection failing

```bash
# Test the foreign server connection from inside nostream-db
docker exec -it nostream-db psql -U nostr_ts_relay -c "
  SELECT * FROM dblink('server=storage_node1', 'SELECT 1') AS t(x int);"
```

If that fails, check:
- Storage node's port 5432 is exposed on the host (`ports: "5432:5432"` in docker-compose.storage.yml)
- `storage/pg_hba.conf` allows connections from `200::/7`
- Yggdrasil on both sides is up and peered (`docker logs nostream-yggdrasil`)

### Checking the Yggdrasil whitelist

```bash
# On coordinator
cat yggdrasil-config/yggdrasil.conf | jq '.AllowedPublicKeys'

# Registered nodes
cat yggdrasil-config/nodes.json
```

### Partition not receiving inserts

Check that the new event's `event_created_at` falls within the partition's range:

```sql
SELECT inhrelid::regclass, pg_get_expr(c.relpartbound, c.oid)
FROM pg_inherits
JOIN pg_class c ON inhrelid = c.oid
WHERE inhparent = 'events'::regclass;
```

---

## File reference

| File | Purpose |
|---|---|
| `docker-compose.yml` | Coordinator: relay + nostream-db + Yggdrasil + Redis |
| `docker-compose.storage.yml` | Storage node: postgres + Yggdrasil |
| `docker/yggdrasil/Dockerfile` | Yggdrasil image (Alpine + yggdrasil binary) |
| `docker/yggdrasil/coordinator-entrypoint.sh` | Generates config, listens for peers, prints identity |
| `docker/yggdrasil/storage-entrypoint.sh` | Generates config, peers to coordinator, enforces whitelist |
| `yggdrasil-config/yggdrasil.conf` | Yggdrasil keys and config (gitignored, generated on first run) |
| `yggdrasil-config/nodes.json` | Name→pubkey registry for registered storage nodes |
| `pg_hba.conf` | Coordinator PostgreSQL auth rules (allows Yggdrasil range) |
| `storage/pg_hba.conf` | Storage node PostgreSQL auth rules |
| `storage/postgresql.conf` | Storage node PostgreSQL config (conservative defaults) |
| `scripts/storage-init.sql` | Creates `events_data` table on storage node (run automatically) |
| `scripts/add-storage-node.sh` | Register a storage node: whitelist + FDW + partition attach |
| `scripts/remove-storage-node.sh` | Deregister a storage node: whitelist + partition detach |
| `scripts/archive-events.sh` | Move old events from events_hot to a registered storage node |
| `migrations/20240120_000000_partition_events_table.js` | Converts `events` to a partitioned table, enables postgres_fdw |
