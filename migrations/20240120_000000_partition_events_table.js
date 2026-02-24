/**
 * Converts the flat `events` table into a range-partitioned table (by event_created_at)
 * and enables postgres_fdw for attaching remote storage nodes.
 *
 * Partition strategy:
 *   events_hot  — local, covers MINVALUE to MAXVALUE initially (all existing + new data).
 *                 When a storage node is added, a new time-range partition is created
 *                 there, and events_hot is narrowed to cover only recent data.
 *
 * Replaceable events (kinds 0, 3, 41, 10000-19999, 30000-39999):
 *   The replaceable_events_idx partial unique index lives only on events_hot.
 *   Because replaceable events are always inserted with a current timestamp,
 *   they naturally land in events_hot. The ON CONFLICT upsert continues to work
 *   without any application changes.
 *
 * event_tags:
 *   Remains a flat local table. The process_event_tags trigger fires on events_hot
 *   inserts (local partition). When old events are migrated to a remote partition
 *   by an operator, the corresponding event_tags rows are already present locally
 *   and continue to serve tag-based REQ queries without cross-network lookups.
 */

exports.up = async function (knex) {
  await knex.raw('BEGIN')

  try {
    // ------------------------------------------------------------------ //
    // 1. Enable postgres_fdw for remote storage nodes
    // ------------------------------------------------------------------ //
    await knex.raw('CREATE EXTENSION IF NOT EXISTS postgres_fdw')

    // ------------------------------------------------------------------ //
    // 2. Rename current flat table out of the way
    // ------------------------------------------------------------------ //
    await knex.raw('ALTER TABLE events RENAME TO events_old')

    // Also rename the existing trigger so it doesn't conflict
    await knex.raw(`
      ALTER TRIGGER insert_event_tags ON events_old
        RENAME TO insert_event_tags_old
    `)

    // ------------------------------------------------------------------ //
    // 3. Create the new partitioned parent table
    //    PK is (id, event_created_at) — partition key must be in PK.
    //    event_id uniqueness is protocol-guaranteed; per-partition unique
    //    index on events_hot enforces it for the hot tier.
    // ------------------------------------------------------------------ //
    await knex.raw(`
      CREATE TABLE events (
        id                   uuid          NOT NULL DEFAULT uuid_generate_v4(),
        event_id             bytea         NOT NULL,
        event_pubkey         bytea         NOT NULL,
        event_kind           integer       NOT NULL,
        event_created_at     integer       NOT NULL,
        event_content        text          NOT NULL,
        event_tags           jsonb,
        event_signature      bytea         NOT NULL,
        first_seen           timestamp     NOT NULL DEFAULT now(),
        deleted_at           timestamp,
        remote_address       text,
        expires_at           integer,
        event_deduplication  jsonb,
        PRIMARY KEY (id, event_created_at)
      ) PARTITION BY RANGE (event_created_at)
    `)

    // ------------------------------------------------------------------ //
    // 4. Create the hot (local) partition — covers everything initially
    // ------------------------------------------------------------------ //
    await knex.raw(`
      CREATE TABLE events_hot
        PARTITION OF events
        FOR VALUES FROM (MINVALUE) TO (MAXVALUE)
    `)

    // ------------------------------------------------------------------ //
    // 5. Recreate indexes on events_hot
    // ------------------------------------------------------------------ //
    await knex.raw('CREATE INDEX events_hot_pubkey_idx     ON events_hot (event_pubkey)')
    await knex.raw('CREATE INDEX events_hot_kind_idx       ON events_hot (event_kind)')
    await knex.raw('CREATE INDEX events_hot_created_at_idx ON events_hot (event_created_at)')
    await knex.raw('CREATE UNIQUE INDEX events_hot_event_id_idx ON events_hot (event_id)')
    await knex.raw('CREATE INDEX events_hot_tags_gin_idx   ON events_hot USING GIN (event_tags)')

    // btree_gin composite index used by REQ filters combining kind + tags + time
    await knex.raw(`
      CREATE INDEX events_hot_kind_tags_time_idx
        ON events_hot
        USING GIN (event_kind, event_tags, event_created_at)
    `)

    // Partial unique index for replaceable events — only needed on events_hot
    // because replaceable events always carry a current timestamp.
    await knex.raw(`
      CREATE UNIQUE INDEX replaceable_events_idx
        ON events_hot (event_pubkey, event_kind, event_deduplication)
        WHERE (
          event_kind = 0
          OR event_kind = 3
          OR event_kind = 41
          OR (event_kind >= 10000 AND event_kind < 20000)
          OR (event_kind >= 30000 AND event_kind < 40000)
        )
    `)

    // ------------------------------------------------------------------ //
    // 6. Recreate the event_tags trigger on the partitioned parent.
    //    PostgreSQL 13+ fires row-level triggers defined on the parent
    //    for each matching row on local partitions.
    //    Note: triggers do NOT fire for foreign (FDW) partitions —
    //    event_tags for archived rows is populated when rows are migrated
    //    (the rows already have event_tags entries from when they were hot).
    // ------------------------------------------------------------------ //
    await knex.raw(`
      CREATE OR REPLACE FUNCTION process_event_tags() RETURNS TRIGGER AS $$
      DECLARE
        tag_element jsonb;
        tag_name text;
        tag_value text;
      BEGIN
        DELETE FROM event_tags WHERE event_id = OLD.event_id;

        IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
          FOR tag_element IN SELECT jsonb_array_elements(NEW.event_tags)
          LOOP
            tag_name := trim((tag_element->0)::text, '"');
            tag_value := trim((tag_element->1)::text, '"');
            IF length(tag_name) = 1 AND tag_value IS NOT NULL AND tag_value <> '' THEN
              INSERT INTO event_tags (event_id, tag_name, tag_value)
                VALUES (NEW.event_id, tag_name, tag_value);
            END IF;
          END LOOP;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    `)

    await knex.raw(`
      CREATE TRIGGER insert_event_tags
        AFTER INSERT OR UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION process_event_tags()
    `)

    // ------------------------------------------------------------------ //
    // 7. Migrate data from events_old into the partitioned events table.
    //    Disable the old trigger to avoid double-writes to event_tags.
    // ------------------------------------------------------------------ //
    await knex.raw(`
      ALTER TABLE events_old DISABLE TRIGGER insert_event_tags_old
    `)

    await knex.raw(`
      INSERT INTO events (
        id, event_id, event_pubkey, event_kind, event_created_at,
        event_content, event_tags, event_signature, first_seen,
        deleted_at, remote_address, expires_at, event_deduplication
      )
      SELECT
        id, event_id, event_pubkey, event_kind, event_created_at,
        event_content, event_tags, event_signature, first_seen,
        deleted_at, remote_address, expires_at, event_deduplication
      FROM events_old
      ON CONFLICT DO NOTHING
    `)

    // ------------------------------------------------------------------ //
    // 8. Drop the old table
    // ------------------------------------------------------------------ //
    await knex.raw('DROP TABLE events_old')

    await knex.raw('COMMIT')
  } catch (err) {
    await knex.raw('ROLLBACK')
    throw err
  }
}

exports.down = async function (knex) {
  await knex.raw('BEGIN')

  try {
    // Move data out of the partitioned table back to a flat table
    await knex.raw(`
      CREATE TABLE events_restore AS
        SELECT * FROM events
    `)

    // Drop the partitioned table (and all its partitions + foreign tables if any)
    await knex.raw('DROP TABLE events CASCADE')
    await knex.raw('DROP EXTENSION IF EXISTS postgres_fdw CASCADE')

    // Recreate original flat table
    await knex.schema.createTable('events', (table) => {
      table.uuid('id').primary().defaultTo(knex.raw('uuid_generate_v4()'))
      table.binary('event_id').unique().notNullable().index()
      table.binary('event_pubkey').notNullable().index()
      table.integer('event_kind').unsigned().notNullable().index()
      table.integer('event_created_at').unsigned().notNullable().index()
      table.text('event_content').notNullable()
      table.jsonb('event_tags')
      table.binary('event_signature').notNullable()
      table.timestamp('first_seen', { useTz: false }).defaultTo(knex.fn.now())
      table.timestamp('deleted_at', { useTz: false }).nullable()
      table.text('remote_address').nullable()
      table.integer('expires_at').nullable()
      table.jsonb('event_deduplication').nullable()
    })

    await knex.raw(`
      INSERT INTO events SELECT * FROM events_restore ON CONFLICT DO NOTHING
    `)
    await knex.raw('DROP TABLE events_restore')

    // Restore indexes
    await knex.raw(`
      CREATE INDEX event_tags_idx ON events USING GIN (event_tags)
    `)
    await knex.raw(`
      CREATE EXTENSION IF NOT EXISTS btree_gin
    `)
    await knex.raw(`
      CREATE INDEX kind_tags_created_at_idx
        ON events USING GIN (event_kind, event_tags, event_created_at)
    `)
    await knex.raw(`
      CREATE UNIQUE INDEX replaceable_events_idx
        ON events (event_pubkey, event_kind, event_deduplication)
        WHERE (
          event_kind = 0 OR event_kind = 3
          OR (event_kind >= 10000 AND event_kind < 20000)
          OR (event_kind >= 30000 AND event_kind < 40000)
        )
    `)

    // Restore trigger
    await knex.raw(`
      CREATE TRIGGER insert_event_tags
        AFTER INSERT OR UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION process_event_tags()
    `)

    await knex.raw('COMMIT')
  } catch (err) {
    await knex.raw('ROLLBACK')
    throw err
  }
}
