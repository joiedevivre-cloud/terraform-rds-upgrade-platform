\set ON_ERROR_STOP on

-- Read-only, fixed-predicate representative SQL only. Markers let the local
-- PowerShell analyzer separate the raw JSON plans without hashing on the runner.
\echo PLAN_BEGIN=pk_lookup
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT * FROM portfolio_orders WHERE order_id = 50000;
\echo PLAN_END=pk_lookup
\echo PLAN_BEGIN=customer_recent
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT * FROM portfolio_orders WHERE customer_id = 4242 ORDER BY created_at DESC LIMIT 20;
\echo PLAN_END=customer_recent
\echo PLAN_BEGIN=date_aggregate
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT count(*), sum(total_amount) FROM portfolio_orders WHERE created_at >= timestamptz '2026-07-01 00:00:00+00';
\echo PLAN_END=date_aggregate
\echo PLAN_BEGIN=status_aggregate
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT status, count(*), sum(total_amount) FROM portfolio_orders GROUP BY status ORDER BY status;
\echo PLAN_END=status_aggregate
\echo PLAN_BEGIN=top_amounts
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT order_id, customer_id, total_amount FROM portfolio_orders ORDER BY total_amount DESC, order_id LIMIT 50;
\echo PLAN_END=top_amounts
\echo PLAN_BEGIN=customer_range
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT customer_id, count(*) FROM portfolio_orders WHERE customer_id BETWEEN 4000 AND 4500 GROUP BY customer_id ORDER BY customer_id;
\echo PLAN_END=customer_range
\echo PLAN_BEGIN=daily_counts
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT date_trunc('day', created_at), count(*) FROM portfolio_orders WHERE created_at >= timestamptz '2026-07-01 00:00:00+00' GROUP BY 1 ORDER BY 1;
\echo PLAN_END=daily_counts
\echo PLAN_BEGIN=customer_window
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) SELECT order_id, customer_id, total_amount, row_number() OVER (PARTITION BY customer_id ORDER BY created_at DESC) FROM portfolio_orders WHERE customer_id BETWEEN 100 AND 120 ORDER BY customer_id, 4;
\echo PLAN_END=customer_window
