CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE IF NOT EXISTS portfolio_orders (
  order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  status text NOT NULL CHECK (status IN ('new', 'paid', 'shipped', 'cancelled')),
  total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS portfolio_orders_customer_created_idx
  ON portfolio_orders (customer_id, created_at DESC);

-- Keep the lab repeatable and safe to re-run: generate the same distribution only
-- when the baseline table is empty instead of silently appending another 100k rows.
SELECT setseed(0.4242);

INSERT INTO portfolio_orders (customer_id, status, total_amount, created_at)
SELECT
  1 + (random() * 9999)::bigint,
  (ARRAY['new','paid','shipped','cancelled'])[1 + (random() * 3)::int],
  round((random() * 1000)::numeric, 2),
  now() - (random() * interval '90 days')
FROM generate_series(1, 100000)
WHERE NOT EXISTS (SELECT 1 FROM portfolio_orders);

ANALYZE portfolio_orders;

SELECT count(*) AS baseline_row_count FROM portfolio_orders;
