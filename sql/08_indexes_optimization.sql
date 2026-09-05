-- ============================================================
-- File   : 08_indexes_optimization.sql
-- Purpose: Indexing strategy and query rewrites.
--
-- Indexes are not free: every one of them slows writes down and
-- takes space. The rule applied here is to index only columns that
-- are actually used to filter, join or sort in the reports written
-- in 04-07, and nothing else.
-- ============================================================


-- ------------------------------------------------------------
-- Step 1 - what the query workload actually touches
--
--   orders.customer_id   joined on in almost every customer report
--   orders.order_date    range filtered in every trend report
--   orders.status        filtered in every revenue report
--   order_items.order_id joined on for every basket/line query
--   order_items.product_id joined on for every product report
--   payments.order_id    joined on for reconciliation
--   customers.city       grouped/filtered in the geography report
--   products.category    grouped/filtered in the catalogue report
--
-- Primary keys already give us a unique index on every *_id PK, so
-- those are not repeated below.
-- ------------------------------------------------------------

DROP INDEX IF EXISTS idx_orders_customer;
DROP INDEX IF EXISTS idx_orders_date;
DROP INDEX IF EXISTS idx_orders_status_date;
DROP INDEX IF EXISTS idx_items_order;
DROP INDEX IF EXISTS idx_items_product;
DROP INDEX IF EXISTS idx_payments_order;
DROP INDEX IF EXISTS idx_payments_status_date;
DROP INDEX IF EXISTS idx_customers_city;
DROP INDEX IF EXISTS idx_products_category;


-- Foreign key columns. A foreign key does not create an index by
-- itself, and an unindexed FK makes both joins and parent-row
-- deletes slow.
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_items_order       ON order_items(order_id);
CREATE INDEX idx_items_product     ON order_items(product_id);
CREATE INDEX idx_payments_order    ON payments(order_id);

-- Date range scans on the order book.
CREATE INDEX idx_orders_date       ON orders(order_date);

-- Composite index for the single most common access pattern:
-- "COMPLETED orders in a date window". Column order matters -
-- status is an equality predicate so it goes first, order_date is
-- a range predicate so it goes second. The reverse order would not
-- let the range be used.
CREATE INDEX idx_orders_status_date ON orders(status, order_date);

-- Payment reconciliation scans by status and settlement date.
CREATE INDEX idx_payments_status_date ON payments(payment_status, payment_date);

-- Grouping keys used by the geography and catalogue reports.
CREATE INDEX idx_customers_city     ON customers(city);
CREATE INDEX idx_products_category  ON products(category);

-- Refresh the planner's statistics after bulk loading, otherwise
-- it is costing queries against stale (or absent) row counts.
ANALYZE;


-- ------------------------------------------------------------
-- Step 2 - read the plans
--
-- Run each EXPLAIN and check that the composite index is being
-- used for the filter, and that joins are hash joins on the
-- indexed keys rather than nested loops over full scans.
-- On PostgreSQL swap EXPLAIN for EXPLAIN (ANALYZE, BUFFERS) to get
-- real timings and page counts.
-- ------------------------------------------------------------

-- Q1: date-ranged revenue - should use idx_orders_status_date
EXPLAIN
SELECT SUM(total_amount)
FROM orders
WHERE status = 'COMPLETED'
  AND order_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-30';

-- Q2: customer order history - should use idx_orders_customer
EXPLAIN
SELECT order_id, order_date, total_amount
FROM orders
WHERE customer_id = 17
ORDER BY order_date DESC;

-- Q3: the four table report join
EXPLAIN
SELECT p.category, SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))
FROM orders o
JOIN order_items oi ON oi.order_id  = o.order_id
JOIN products    p  ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY p.category;


-- ------------------------------------------------------------
-- Step 3 - rewrites that matter more than indexes
-- ------------------------------------------------------------

-- 3a. SLOW: a correlated subquery in the SELECT list runs once per
--     outer row, so it scans orders N times.
SELECT c.customer_id,
       c.name,
       (SELECT COUNT(*)  FROM orders o
         WHERE o.customer_id = c.customer_id AND o.status = 'COMPLETED') AS orders,
       (SELECT SUM(o.total_amount) FROM orders o
         WHERE o.customer_id = c.customer_id AND o.status = 'COMPLETED') AS revenue
FROM customers c
ORDER BY revenue DESC NULLS LAST
LIMIT 10;

-- 3b. FASTER: aggregate once, join once. Same answer, one pass over
--     orders instead of two per customer.
SELECT c.customer_id,
       c.name,
       COALESCE(agg.orders, 0)  AS orders,
       agg.revenue
FROM customers c
LEFT JOIN (
    SELECT customer_id, COUNT(*) AS orders, SUM(total_amount) AS revenue
    FROM orders
    WHERE status = 'COMPLETED'
    GROUP BY customer_id
) agg ON agg.customer_id = c.customer_id
ORDER BY agg.revenue DESC NULLS LAST
LIMIT 10;


-- 3c. SLOW: wrapping the indexed column in a function makes the
--     predicate non-sargable, so the index on order_date is
--     unusable and the planner falls back to a full scan.
EXPLAIN
SELECT COUNT(*)
FROM orders
WHERE EXTRACT(YEAR FROM order_date) = 2026;

-- 3d. FASTER: express the same thing as a half-open range on the
--     bare column, and the index range scan comes back.
EXPLAIN
SELECT COUNT(*)
FROM orders
WHERE order_date >= DATE '2026-01-01'
  AND order_date <  DATE '2027-01-01';


-- 3e. SLOW: DISTINCT used to paper over a fan-out caused by the
--     join. The engine still materialises every duplicated row
--     before deduplicating it.
SELECT DISTINCT c.customer_id, c.name
FROM customers c
JOIN orders      o  ON o.customer_id = c.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
WHERE oi.product_id = 3
ORDER BY c.customer_id
LIMIT 10;

-- 3f. FASTER: EXISTS stops at the first match per customer and
--     never produces the duplicate rows in the first place.
SELECT c.customer_id, c.name
FROM customers c
WHERE EXISTS (
    SELECT 1
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.customer_id = c.customer_id
      AND oi.product_id = 3
)
ORDER BY c.customer_id
LIMIT 10;


-- 3g. SLOW: OR across two columns often defeats index usage.
EXPLAIN
SELECT order_id FROM orders
WHERE status = 'CANCELLED' OR order_date = DATE '2026-08-15';

-- 3h. FASTER: UNION ALL lets each branch use its own index. The
--     small duplicate risk is handled by UNION instead of ALL when
--     correctness demands it.
EXPLAIN
SELECT order_id FROM orders WHERE status = 'CANCELLED'
UNION
SELECT order_id FROM orders WHERE order_date = DATE '2026-08-15';


-- ------------------------------------------------------------
-- Step 4 - confirm the indexes exist
--
-- PostgreSQL:  SELECT indexname, indexdef FROM pg_indexes
--              WHERE schemaname = 'public' ORDER BY tablename;
-- DuckDB:      the query below.
-- ------------------------------------------------------------
SELECT index_name, table_name, is_unique
FROM duckdb_indexes()
ORDER BY table_name, index_name;
