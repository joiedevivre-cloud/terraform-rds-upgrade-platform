\set ON_ERROR_STOP on

SELECT current_database() AS database_name,
       current_setting('server_version') AS server_version,
       pg_size_pretty(pg_database_size(current_database())) AS database_size;

SELECT extname, extversion
FROM pg_extension
ORDER BY extname;

DO $$
BEGIN
  IF coalesce(current_setting('rds.logical_replication', true), 'off') NOT IN ('on', '1') THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: rds.logical_replication is not enabled at runtime';
  END IF;

  -- Target-16 policy for this portfolio. Any additional extension must be reviewed
  -- against the Aurora PostgreSQL 16 supported-extension list before being added.
  IF EXISTS (
    SELECT 1 FROM pg_extension
    WHERE extname NOT IN ('plpgsql', 'pg_stat_statements')
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: extension outside the approved PostgreSQL 16 allowlist detected';
  END IF;
END $$;

SELECT pid, usename, state, xact_start, query_start, left(query, 200) AS query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND backend_type = 'client backend'
  AND (
    (state = 'active' AND query ~* '^\s*(ALTER|CREATE|DROP|TRUNCATE|REINDEX|CLUSTER|VACUUM\s+FULL|REFRESH\s+MATERIALIZED)(\s|;|$)')
    OR (xact_start IS NOT NULL AND clock_timestamp() - xact_start > interval '5 minutes')
  )
ORDER BY coalesce(xact_start, query_start);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND state = 'active'
      AND query ~* '^\s*(ALTER|CREATE|DROP|TRUNCATE|REINDEX|CLUSTER|VACUUM\s+FULL|REFRESH\s+MATERIALIZED)(\s|;|$)'
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: active DDL statement detected';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND xact_start IS NOT NULL
      AND clock_timestamp() - xact_start > interval '5 minutes'
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: transaction older than 5 minutes detected';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND c.relreplident <> 'f'
      AND NOT EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.oid AND i.indisprimary
      )
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: table exists without a primary key or REPLICA IDENTITY FULL';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication)
     OR EXISTS (SELECT 1 FROM pg_subscription) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: existing logical publication or subscription detected';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_largeobject_metadata) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: PostgreSQL large objects are present';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u' AND c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: unlogged application table detected';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal AND t.tgenabled IN ('R', 'A')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: ENABLE REPLICA or ENABLE ALWAYS trigger detected';
  END IF;
END $$;

SELECT count(*) AS sequence_count FROM pg_class WHERE relkind = 'S';
SELECT seq_ns.nspname AS sequence_schema,
       seq.relname AS sequence_name,
       pg_get_userbyid(seq.relowner) AS sequence_owner,
       table_ns.nspname AS owned_by_schema,
       table_rel.relname AS owned_by_table,
       table_att.attname AS owned_by_column,
       sequence_state.last_value
FROM pg_class AS seq
JOIN pg_namespace AS seq_ns ON seq_ns.oid = seq.relnamespace
LEFT JOIN pg_depend AS dependency
  ON dependency.classid = 'pg_class'::regclass
 AND dependency.objid = seq.oid
 AND dependency.refclassid = 'pg_class'::regclass
 AND dependency.deptype IN ('a', 'i')
LEFT JOIN pg_class AS table_rel ON table_rel.oid = dependency.refobjid
LEFT JOIN pg_namespace AS table_ns ON table_ns.oid = table_rel.relnamespace
LEFT JOIN pg_attribute AS table_att
  ON table_att.attrelid = table_rel.oid
 AND table_att.attnum = dependency.refobjsubid
LEFT JOIN pg_sequences AS sequence_state
  ON sequence_state.schemaname = seq_ns.nspname
 AND sequence_state.sequencename = seq.relname
WHERE seq.relkind = 'S'
  AND seq_ns.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;
SELECT schemaname, matviewname FROM pg_matviews ORDER BY 1, 2;

SELECT schemaname, indexrelname
FROM pg_stat_user_indexes
WHERE indexrelid IN (SELECT indexrelid FROM pg_index WHERE NOT indisvalid);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_index WHERE NOT indisvalid) THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: invalid index detected';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_type = 'logical') THEN
    RAISE EXCEPTION 'PRECHECK_FAIL: pre-existing logical replication slot detected';
  END IF;
END $$;

SELECT slot_name, plugin, slot_type, active
FROM pg_replication_slots;

SELECT datname, numbackends, xact_commit, xact_rollback,
       blks_read, blks_hit, deadlocks
FROM pg_stat_database
WHERE datname = current_database();

SELECT 'PRECHECK_JSON=' || jsonb_build_object(
  'result', 'PASS',
  'checked_at_utc', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'database', current_database(),
  'server_version', current_setting('server_version'),
  'rds_logical_replication', current_setting('rds.logical_replication', true),
  'database_size_bytes', pg_database_size(current_database()),
  'baseline_row_count', CASE WHEN to_regclass('public.portfolio_orders') IS NULL THEN NULL
    ELSE (SELECT count(*) FROM portfolio_orders) END,
  'replica_identity_failures', (
    SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND c.relreplident <> 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
  ),
  'invalid_indexes', (SELECT count(*) FROM pg_index WHERE NOT indisvalid),
  'logical_slots', (SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical'),
  'publications', (SELECT count(*) FROM pg_publication),
  'subscriptions', (SELECT count(*) FROM pg_subscription),
  'large_objects', (SELECT count(*) FROM pg_largeobject_metadata),
  'unlogged_tables', (
    SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u' AND c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ),
  'unsafe_triggers', (
    SELECT count(*) FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal AND t.tgenabled IN ('R', 'A')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ),
  'sequences', (SELECT count(*) FROM pg_class WHERE relkind = 'S'),
  'unowned_sequences', (
    SELECT count(*)
    FROM pg_class AS seq
    JOIN pg_namespace AS n ON n.oid = seq.relnamespace
    WHERE seq.relkind = 'S'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend AS d
        WHERE d.classid = 'pg_class'::regclass
          AND d.objid = seq.oid
          AND d.refclassid = 'pg_class'::regclass
          AND d.deptype IN ('a', 'i')
      )
  ),
  'materialized_views', (SELECT count(*) FROM pg_matviews),
  'active_ddl', (
    SELECT count(*) FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND state = 'active'
      AND query ~* '^\s*(ALTER|CREATE|DROP|TRUNCATE|REINDEX|CLUSTER|VACUUM\s+FULL|REFRESH\s+MATERIALIZED)(\s|;|$)'
  ),
  'transactions_over_5_minutes', (
    SELECT count(*) FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND xact_start IS NOT NULL
      AND clock_timestamp() - xact_start > interval '5 minutes'
  ),
  'unapproved_extensions', (
    SELECT count(*) FROM pg_extension
    WHERE extname NOT IN ('plpgsql', 'pg_stat_statements')
  ),
  'extensions', (
    SELECT coalesce(jsonb_object_agg(extname, extversion ORDER BY extname), '{}'::jsonb)
    FROM pg_extension
  )
)::text AS precheck_machine_report;
