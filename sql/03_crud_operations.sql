-- ============================================================
-- File   : 03_crud_operations.sql
-- Purpose: INSERT / SELECT / UPDATE / DELETE with referential
--          integrity kept intact, plus transaction handling.
--
-- This script is self cleaning. Everything it creates uses ids in
-- the 9000 range and is removed at the end, so the analytics files
-- that follow always see the original seed data.
-- ============================================================


-- ------------------------------------------------------------
-- C1. INSERT - a new customer places their first order
--
-- Order of inserts follows the foreign keys: customer -> order ->
-- order_items -> payment. Doing it in a single transaction means a
-- half written order can never be left behind.
-- ------------------------------------------------------------
BEGIN;

INSERT INTO customers (customer_id, name, email, phone, city, state, signup_date)
VALUES (9001, 'Ritika Malhotra', 'ritika.malhotra@example.com', '9812345670',
        'Bengaluru', 'Karnataka', DATE '2026-09-01');

INSERT INTO orders (order_id, customer_id, order_date, status, channel, total_amount)
VALUES (9001, 9001, DATE '2026-09-02', 'PLACED', 'MOBILE_APP', 0);

INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price, discount_pct)
VALUES (9001, 9001,  3, 1, 6499.00, 0.10),
       (9002, 9001, 30, 2,  899.00, 0.00),
       (9003, 9001, 35, 3,  449.00, 0.05);

-- total_amount is a stored roll up, so it has to be refreshed from
-- the lines instead of being typed in by hand. Rounding is applied
-- per line and then summed - see the note on the header_vs_lines
-- check at the bottom of this file.
UPDATE orders o
SET total_amount = (
        SELECT SUM(ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct), 2))
        FROM order_items oi
        WHERE oi.order_id = o.order_id)
WHERE o.order_id = 9001;

INSERT INTO payments (payment_id, order_id, payment_date, amount, method, payment_status)
SELECT 9001, o.order_id, DATE '2026-09-02', o.total_amount, 'UPI', 'PAID'
FROM orders o
WHERE o.order_id = 9001;

COMMIT;


-- ------------------------------------------------------------
-- R1. SELECT - read the order back across all four tables
-- ------------------------------------------------------------
SELECT c.name,
       o.order_id,
       o.order_date,
       o.status,
       p.product_name,
       oi.quantity,
       oi.unit_price,
       oi.discount_pct,
       ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct), 2) AS line_total,
       o.total_amount,
       pay.payment_status
FROM orders o
JOIN customers   c   ON c.customer_id = o.customer_id
JOIN order_items oi  ON oi.order_id   = o.order_id
JOIN products    p   ON p.product_id  = oi.product_id
LEFT JOIN payments pay ON pay.order_id = o.order_id
WHERE o.order_id = 9001
ORDER BY p.product_name;


-- ------------------------------------------------------------
-- R2. SELECT with filtering, aliasing and derived columns
-- ------------------------------------------------------------
SELECT product_id,
       product_name,
       category,
       price,
       cost_price,
       price - cost_price                              AS margin_value,
       ROUND(100.0 * (price - cost_price) / price, 1)  AS margin_pct,
       CASE WHEN stock = 0            THEN 'OUT_OF_STOCK'
            WHEN stock < 20           THEN 'LOW'
            WHEN stock < 100          THEN 'HEALTHY'
            ELSE                           'OVERSTOCKED'
       END                                             AS stock_band
FROM products
WHERE is_active = TRUE
  AND category IN ('Electronics', 'Home & Kitchen')
ORDER BY margin_pct DESC, price DESC;


-- ------------------------------------------------------------
-- U1. UPDATE - fulfil the order and move stock
-- ------------------------------------------------------------
UPDATE orders
SET status = 'COMPLETED'
WHERE order_id = 9001;

UPDATE products p
SET stock = p.stock - oi.quantity
FROM order_items oi
WHERE oi.product_id = p.product_id
  AND oi.order_id   = 9001
  AND p.stock >= oi.quantity;   -- guard so the CHECK (stock >= 0) can never fire


-- ------------------------------------------------------------
-- U2. Conditional bulk UPDATE - a 10% price rise on slow moving
--     stock, applied only where it does not break the margin rule.
--     Wrapped in a transaction and rolled back: this is here to
--     show the pattern, not to change the dataset.
-- ------------------------------------------------------------
BEGIN;

UPDATE products
SET price = ROUND(price * 1.10, 2)
WHERE stock > 100
  AND product_id NOT IN (SELECT DISTINCT product_id FROM order_items);

ROLLBACK;


-- ------------------------------------------------------------
-- D1. DELETE - remove the demo order, children first.
--
-- The schema has no ON DELETE CASCADE (kept portable on purpose),
-- so the child rows are deleted explicitly, deepest first.
--
-- Portability note: on PostgreSQL all four DELETEs belong in a
-- single transaction. DuckDB, which is what this project is tested
-- on, cannot drop a parent row in the same transaction that
-- removed its children, so the child deletes are committed first.
-- ------------------------------------------------------------
BEGIN;
DELETE FROM payments    WHERE order_id = 9001;
DELETE FROM order_items WHERE order_id = 9001;
COMMIT;

BEGIN;
DELETE FROM orders      WHERE order_id = 9001;
COMMIT;

BEGIN;
DELETE FROM customers   WHERE customer_id = 9001;
COMMIT;


-- ------------------------------------------------------------
-- D2. Restore the stock that U1 consumed, so the file leaves the
--     database exactly as it found it.
-- ------------------------------------------------------------
UPDATE products SET stock = stock + 1 WHERE product_id = 3  AND stock + 1 >= 0;
UPDATE products SET stock = stock + 2 WHERE product_id = 30 AND stock + 2 >= 0;
UPDATE products SET stock = stock + 3 WHERE product_id = 35 AND stock + 3 >= 0;


-- ------------------------------------------------------------
-- Integrity checks - all four must report bad_rows = 0.
-- ------------------------------------------------------------
-- orphaned order items
SELECT 'orphan_order_items' AS check_name, COUNT(*) AS bad_rows
FROM order_items oi
LEFT JOIN orders o ON o.order_id = oi.order_id
WHERE o.order_id IS NULL;

-- payments pointing at a missing order
SELECT 'orphan_payments' AS check_name, COUNT(*) AS bad_rows
FROM payments p
LEFT JOIN orders o ON o.order_id = p.order_id
WHERE o.order_id IS NULL;

-- Order header that disagrees with its own lines.
--
-- Note the rounding: each line is rounded to paise first and the
-- rounded values are then summed, which is how an invoice is
-- actually printed and how v_order_lines.line_revenue is defined.
-- Summing first and rounding once at the end gives a different
-- answer - on a three line order the drift is already 2 paise -
-- and would make this check fail on correct data.
SELECT 'header_vs_lines' AS check_name, COUNT(*) AS bad_rows
FROM orders o
JOIN (SELECT order_id,
             SUM(ROUND(quantity * unit_price * (1 - discount_pct), 2)) AS line_sum
      FROM order_items
      GROUP BY order_id) l ON l.order_id = o.order_id
WHERE ABS(o.total_amount - l.line_sum) > 0.01;

-- orders with no lines at all
SELECT 'orders_without_lines' AS check_name, COUNT(*) AS bad_rows
FROM orders o
LEFT JOIN order_items oi ON oi.order_id = o.order_id
WHERE oi.order_item_id IS NULL;
