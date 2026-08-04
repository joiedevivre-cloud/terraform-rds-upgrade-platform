\timing on

-- Approved representative-query deep dive only. First use
-- query-stats-snapshot.sql to identify high-impact or regressed SQL.

EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT customer_id, count(*), sum(total_amount)
FROM portfolio_orders
WHERE created_at >= now() - interval '30 days'
GROUP BY customer_id
ORDER BY sum(total_amount) DESC
LIMIT 100;

SELECT count(*) AS row_count,
       sum(order_id) AS id_checksum,
       sum(total_amount) AS amount_checksum
FROM portfolio_orders;
