\set ON_ERROR_STOP on

-- Capture a bounded, impact-based sample from the complete pg_stat_statements
-- population. This does not execute application SQL. It ranks statements already
-- observed during the measurement window and returns the union of each Top-N list.
WITH observed AS (
  SELECT
    queryid, query, calls, rows, total_plan_time, mean_plan_time,
    total_exec_time, mean_exec_time, min_exec_time, max_exec_time,
    stddev_exec_time, shared_blks_hit, shared_blks_read, temp_blks_read,
    temp_blks_written, wal_bytes,
    row_number() OVER (ORDER BY total_exec_time DESC) AS rank_total_exec,
    row_number() OVER (ORDER BY calls DESC) AS rank_calls,
    row_number() OVER (ORDER BY mean_exec_time DESC) AS rank_mean_exec,
    row_number() OVER (ORDER BY shared_blks_read DESC) AS rank_shared_reads,
    row_number() OVER (ORDER BY (temp_blks_read + temp_blks_written) DESC) AS rank_temp_io
  FROM pg_stat_statements
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND calls > 0
    AND query NOT ILIKE '%pg_stat_statements%'
), selected AS (
  SELECT *, concat_ws(',',
    CASE WHEN rank_total_exec <= :top_n THEN 'total_exec_time' END,
    CASE WHEN rank_calls <= :top_n THEN 'calls' END,
    CASE WHEN rank_mean_exec <= :top_n THEN 'mean_exec_time' END,
    CASE WHEN rank_shared_reads <= :top_n THEN 'shared_blks_read' END,
    CASE WHEN rank_temp_io <= :top_n THEN 'temp_io' END
  ) AS selected_by
  FROM observed
  WHERE rank_total_exec <= :top_n OR rank_calls <= :top_n
     OR rank_mean_exec <= :top_n OR rank_shared_reads <= :top_n
     OR rank_temp_io <= :top_n
)
SELECT current_setting('server_version') AS server_version, queryid, selected_by,
  calls, rows,
  round(total_plan_time::numeric, 3) AS total_plan_time_ms,
  round(mean_plan_time::numeric, 3) AS mean_plan_time_ms,
  round(total_exec_time::numeric, 3) AS total_exec_time_ms,
  round(mean_exec_time::numeric, 3) AS mean_exec_time_ms,
  round(min_exec_time::numeric, 3) AS min_exec_time_ms,
  round(max_exec_time::numeric, 3) AS max_exec_time_ms,
  round(stddev_exec_time::numeric, 3) AS stddev_exec_time_ms,
  shared_blks_hit, shared_blks_read, temp_blks_read, temp_blks_written, wal_bytes,
  regexp_replace(trim(trailing ';' FROM query), '[[:space:]]+', ' ', 'g') AS normalized_query
FROM selected
ORDER BY total_exec_time DESC, calls DESC;
