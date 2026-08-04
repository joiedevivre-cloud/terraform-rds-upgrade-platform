\set ON_ERROR_STOP on

-- Run separately in every application database after the engine upgrade.
SELECT current_database() AS database_name,
       current_setting('server_version') AS server_version,
       clock_timestamp() AS captured_at;

-- An engine upgrade does not upgrade extension SQL objects. Review each row and run
-- ALTER EXTENSION <quoted_extension_name> UPDATE under the owning/approved role.
SELECT installed.extname,
       installed.extversion AS installed_version,
       available.default_version,
       installed.extversion IS DISTINCT FROM available.default_version AS update_review_required
FROM pg_extension AS installed
LEFT JOIN pg_available_extensions AS available
  ON available.name = installed.extname
ORDER BY installed.extname;

-- Verify sequence values and ownership before and after switchover. Reading
-- last_value is non-mutating; do not call nextval merely as a check in production.
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

-- Partitioned parents need their own optimizer statistics after the upgrade.
SELECT n.nspname AS schema_name,
       c.relname AS partitioned_parent,
       stats.last_analyze,
       stats.last_autoanalyze
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_all_tables AS stats ON stats.relid = c.oid
WHERE c.relkind = 'p'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;
