-- ============================================================
-- File   : 04_joins.sql
-- Purpose: INNER / LEFT / FULL OUTER / self / cross joins used to
--          answer real questions rather than to demo syntax.
-- ============================================================


-- ------------------------------------------------------------
-- J1. INNER JOIN - orders with the customer behind them
-- ------------------------------------------------------------
SELECT o.order_id,
       o.order_date,
       c.name        AS customer_name,
       c.city,
       o.channel,
       o.status,
       o.total_amount
FROM orders o
INNER JOIN customers c ON c.customer_id = o.customer_id
WHERE o.order_date >= DATE '2026-08-01'
ORDER BY o.order_date DESC, o.order_id DESC
LIMIT 20;


-- ------------------------------------------------------------
-- J2. LEFT JOIN + IS NULL - registered customers who never bought
--
-- An INNER JOIN can never answer this. The anti-join pattern is
-- the standard way to find "exists on one side only".
-- ------------------------------------------------------------
SELECT c.customer_id,
       c.name,
       c.city,
       c.signup_date,
       CURRENT_DATE - c.signup_date AS days_since_signup
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
WHERE o.order_id IS NULL
ORDER BY c.signup_date;


-- ------------------------------------------------------------
-- J3. Four table join - the fully denormalised order line
--
-- customers -> orders -> order_items -> products, with payments
-- attached on the left because an order may not be paid yet.
-- ------------------------------------------------------------
SELECT o.order_id,
       o.order_date,
       c.name                                                          AS customer_name,
       c.city,
       p.category,
       p.product_name,
       oi.quantity,
       oi.unit_price,
       oi.discount_pct,
       ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct), 2)   AS line_revenue,
       o.status                                                        AS order_status,
       COALESCE(pay.payment_status, 'NO_PAYMENT')                      AS payment_status
FROM orders o
JOIN customers   c  ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
JOIN products    p  ON p.product_id  = oi.product_id
LEFT JOIN payments pay
       ON pay.order_id = o.order_id
      AND pay.payment_status = 'PAID'
WHERE o.order_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
ORDER BY o.order_id, p.product_name
LIMIT 40;


-- ------------------------------------------------------------
-- J4. Anti-join on the catalogue - products that never sold
--
-- Useful for deciding what to delist. Active products with stock
-- sitting on the shelf and zero demand are the expensive ones.
-- ------------------------------------------------------------
SELECT p.product_id,
       p.product_name,
       p.category,
       p.price,
       p.stock,
       p.is_active,
       ROUND(p.stock * p.cost_price, 2) AS capital_tied_up
FROM products p
LEFT JOIN order_items oi ON oi.product_id = p.product_id
WHERE oi.order_item_id IS NULL
ORDER BY capital_tied_up DESC;


-- ------------------------------------------------------------
-- J5. LEFT JOIN to find revenue that was never collected
--
-- Orders that are not cancelled but have no successful payment.
-- This is the leakage report finance actually cares about.
-- ------------------------------------------------------------
SELECT o.order_id,
       o.order_date,
       c.name AS customer_name,
       o.status,
       o.total_amount,
       COUNT(pay.payment_id)                                           AS payment_attempts,
       COUNT(pay.payment_id) FILTER (WHERE pay.payment_status = 'FAILED')  AS failed_attempts,
       MAX(pay.payment_status)                                          AS last_status_seen
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
LEFT JOIN payments pay ON pay.order_id = o.order_id
WHERE o.status NOT IN ('CANCELLED')
GROUP BY o.order_id, o.order_date, c.name, o.status, o.total_amount
HAVING COUNT(pay.payment_id) FILTER (WHERE pay.payment_status = 'PAID') = 0
ORDER BY o.total_amount DESC;


-- ------------------------------------------------------------
-- J6. FULL OUTER JOIN - reconciling booked revenue against cash
--
-- Left side is what the order book says, right side is what the
-- payment gateway settled. A FULL OUTER keeps months that exist on
-- only one of the two sides.
-- ------------------------------------------------------------
WITH booked AS (
    SELECT CAST(DATE_TRUNC('month', order_date) AS DATE) AS month,
           SUM(total_amount)                             AS booked_amount
    FROM orders
    WHERE status IN ('COMPLETED', 'SHIPPED')
    GROUP BY 1
),
settled AS (
    SELECT CAST(DATE_TRUNC('month', payment_date) AS DATE) AS month,
           SUM(CASE WHEN payment_status = 'PAID'     THEN amount
                    WHEN payment_status = 'REFUNDED' THEN -amount
                    ELSE 0 END)                            AS net_cash
    FROM payments
    GROUP BY 1
)
SELECT COALESCE(b.month, s.month)                AS month,
       COALESCE(b.booked_amount, 0)              AS booked_amount,
       COALESCE(s.net_cash, 0)                   AS net_cash_collected,
       COALESCE(s.net_cash, 0) - COALESCE(b.booked_amount, 0) AS variance
FROM booked b
FULL OUTER JOIN settled s ON s.month = b.month
ORDER BY 1;


-- ------------------------------------------------------------
-- J7. Self join - products bought together in the same order
--
-- The oi1.product_id < oi2.product_id predicate stops each pair
-- from appearing twice and removes the product-with-itself rows.
-- ------------------------------------------------------------
SELECT p1.product_name                AS product_a,
       p2.product_name                AS product_b,
       COUNT(*)                       AS times_bought_together
FROM order_items oi1
JOIN order_items oi2
       ON oi2.order_id   = oi1.order_id
      AND oi2.product_id > oi1.product_id
JOIN products p1 ON p1.product_id = oi1.product_id
JOIN products p2 ON p2.product_id = oi2.product_id
GROUP BY p1.product_name, p2.product_name
HAVING COUNT(*) >= 4
ORDER BY times_bought_together DESC, product_a
LIMIT 15;


-- ------------------------------------------------------------
-- J8. CROSS JOIN - a dense category x month grid
--
-- A plain GROUP BY hides months where a category sold nothing.
-- Cross joining every category against every month and LEFT
-- joining the facts back gives explicit zeros instead of gaps.
-- ------------------------------------------------------------
WITH months AS (
    SELECT DISTINCT CAST(DATE_TRUNC('month', order_date) AS DATE) AS month
    FROM orders
    WHERE order_date >= DATE '2026-01-01'
),
cats AS (
    SELECT DISTINCT category FROM products
),
sales AS (
    SELECT CAST(DATE_TRUNC('month', o.order_date) AS DATE)                  AS month,
           p.category,
           SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))         AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id  = o.order_id
    JOIN products    p  ON p.product_id = oi.product_id
    WHERE o.status = 'COMPLETED'
      AND o.order_date >= DATE '2026-01-01'
    GROUP BY 1, 2
)
SELECT m.month,
       c.category,
       ROUND(COALESCE(s.revenue, 0), 2) AS revenue
FROM months m
CROSS JOIN cats c
LEFT JOIN sales s ON s.month = m.month AND s.category = c.category
ORDER BY m.month, c.category;
