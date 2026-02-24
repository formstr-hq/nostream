-- Run on the storage node's PostgreSQL instance.
-- Creates the table that the coordinator's foreign partition maps to.
-- This is executed automatically by the storage-init service in docker-compose.storage.yml.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- The actual storage table. Schema mirrors events on the coordinator
-- but without the partitioning machinery or unique constraints
-- (uniqueness is enforced at the coordinator level by the protocol).
CREATE TABLE IF NOT EXISTS events_data (
  id                   uuid          NOT NULL DEFAULT uuid_generate_v4(),
  event_id             bytea         NOT NULL,
  event_pubkey         bytea         NOT NULL,
  event_kind           integer       NOT NULL,
  event_created_at     integer       NOT NULL,
  event_content        text          NOT NULL,
  event_tags           jsonb,
  event_signature      bytea         NOT NULL,
  first_seen           timestamp     DEFAULT now(),
  deleted_at           timestamp,
  remote_address       text,
  expires_at           integer,
  event_deduplication  jsonb
);

-- Unique constraint on event_id — required for INSERT ... ON CONFLICT DO NOTHING
-- to work through postgres_fdw during archival.
CREATE UNIQUE INDEX IF NOT EXISTS events_data_event_id_uidx ON events_data (event_id);

-- Indexes matching the coordinator for query pushdown performance
CREATE INDEX IF NOT EXISTS events_data_pubkey_idx      ON events_data (event_pubkey);
CREATE INDEX IF NOT EXISTS events_data_kind_idx        ON events_data (event_kind);
CREATE INDEX IF NOT EXISTS events_data_created_at_idx  ON events_data (event_created_at);
CREATE INDEX IF NOT EXISTS events_data_tags_idx        ON events_data USING GIN (event_tags);
