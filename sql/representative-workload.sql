\set ON_ERROR_STOP on

-- Fixed predicates are deliberate: Blue and Green must receive identical SQL.
SELECT * FROM portfolio_orders WHERE order_id = 50000;
SELECT * FROM portfolio_orders WHERE customer_id = 4242 ORDER BY created_at DESC LIMIT 20;
SELECT count(*), sum(total_amount) FROM portfolio_orders WHERE created_at >= timestamptz '2026-07-01 00:00:00+00';
SELECT status, count(*), sum(total_amount) FROM portfolio_orders GROUP BY status ORDER BY status;
SELECT order_id, customer_id, total_amount FROM portfolio_orders ORDER BY total_amount DESC, order_id LIMIT 50;
SELECT customer_id, count(*) FROM portfolio_orders WHERE customer_id BETWEEN 4000 AND 4500 GROUP BY customer_id ORDER BY customer_id;
SELECT date_trunc('day', created_at) AS order_day, count(*) FROM portfolio_orders WHERE created_at >= timestamptz '2026-07-01 00:00:00+00' GROUP BY 1 ORDER BY 1;
SELECT order_id, customer_id, total_amount,
       row_number() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS customer_order_no
FROM portfolio_orders
WHERE customer_id BETWEEN 100 AND 120
ORDER BY customer_id, customer_order_no;
