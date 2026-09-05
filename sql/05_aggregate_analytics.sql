-- ============================================================
-- File   : 05_aggregate_analytics.sql
-- Purpose: Core business reporting with COUNT / SUM / AVG / MIN /
--          MAX, GROUP BY, HAVING and GROUPING SETS.
--
-- Convention used throughout: "revenue" means COMPLETED orders
-- only. PLACED and SHIPPED orders are not money in the bank yet,
-- and CANCELLED / RETURNED orders never will be.
-- ============================================================


-- ------------------------------------------------------------
-- A1. Headline KPIs - one row, the numbers a dashboard opens with
-- ------------------------------------------------------------
SELECT COUNT(*)                                    AS total_orders,
       COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_orders,
       COUNT(DISTINCT customer_id)                 AS buying_customers,
       ROUND(SUM(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS revenue,
       ROUND(AVG(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS avg_order_value,
       ROUND(MIN(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS smallest_order,
       ROUND(MAX(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS largest_order,
       MIN(order_date)                             AS first_order_date,
       MAX(order_date)                             AS last_order_date
FROM orders;


-- ------------------------------------------------------------
-- A2. Revenue by month
-- ------------------------------------------------------------
SELECT EXTRACT(YEAR  FROM order_date)  AS year,
       EXTRACT(MONTH FROM order_date)  AS month,
       COUNT(*)                        AS orders,
       COUNT(DISTINCT customer_id)     AS customers,
       ROUND(SUM(total_amount), 2)     AS revenue,
       ROUND(AVG(total_amount), 2)     AS avg_order_value
FROM orders
WHERE status = 'COMPLETED'
GROUP BY 1, 2
ORDER BY 1, 2;


-- ------------------------------------------------------------
-- A3. Category performance, including gross margin
--
-- Margin needs products.cost_price, so this aggregates at the line
-- level rather than off orders.total_amount.
-- ------------------------------------------------------------
SELECT p.category,
       COUNT(DISTINCT o.order_id)                                        AS orders,
       SUM(oi.quantity)                                                  AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 2) AS revenue,
       ROUND(SUM(oi.quantity * p.cost_price), 2)                          AS cost_of_goods,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))
             - SUM(oi.quantity * p.cost_price), 2)                        AS gross_profit,
       ROUND(100.0 * (SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))
                      - SUM(oi.quantity * p.cost_price))
             / NULLIF(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 0), 1)
                                                                          AS gross_margin_pct
FROM orders o
JOIN order_items oi ON oi.order_id  = o.order_id
JOIN products    p  ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY p.category
ORDER BY revenue DESC;


-- ------------------------------------------------------------
-- A4. Top 10 products by revenue
-- ------------------------------------------------------------
SELECT p.product_name,
       p.category,
       SUM(oi.quantity)                                                   AS units_sold,
       COUNT(DISTINCT o.order_id)                                         AS orders,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 2)  AS revenue,
       ROUND(AVG(oi.discount_pct) * 100, 1)                                AS avg_discount_pct
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY p.product_name, p.category
ORDER BY revenue DESC
LIMIT 10;


-- ------------------------------------------------------------
-- A5. Slow movers - sold, but barely
--
-- HAVING filters on the aggregate, which WHERE cannot do.
-- ------------------------------------------------------------
SELECT p.product_name,
       p.category,
       SUM(oi.quantity)                                                   AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 2)  AS revenue,
       p.stock
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY p.product_name, p.category, p.stock
HAVING SUM(oi.quantity) < 30
ORDER BY units_sold, revenue;


-- ------------------------------------------------------------
-- A6. Customer performance - top 15 by lifetime revenue
-- ------------------------------------------------------------
SELECT c.customer_id,
       c.name,
       c.city,
       COUNT(o.order_id)                     AS orders,
       ROUND(SUM(o.total_amount), 2)         AS lifetime_revenue,
       ROUND(AVG(o.total_amount), 2)         AS avg_order_value,
       MIN(o.order_date)                     AS first_order,
       MAX(o.order_date)                     AS last_order,
       MAX(o.order_date) - MIN(o.order_date) AS active_span_days
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE o.status = 'COMPLETED'
GROUP BY c.customer_id, c.name, c.city
ORDER BY lifetime_revenue DESC
LIMIT 15;


-- ------------------------------------------------------------
-- A7. Geography - only cities with real volume behind them
-- ------------------------------------------------------------
SELECT c.state,
       c.city,
       COUNT(DISTINCT c.customer_id)  AS customers,
       COUNT(o.order_id)              AS orders,
       ROUND(SUM(o.total_amount), 2)  AS revenue,
       ROUND(AVG(o.total_amount), 2)  AS avg_order_value,
       ROUND(SUM(o.total_amount) / COUNT(DISTINCT c.customer_id), 2) AS revenue_per_customer
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE o.status = 'COMPLETED'
GROUP BY c.state, c.city
HAVING COUNT(o.order_id) >= 10
ORDER BY revenue DESC;


-- ------------------------------------------------------------
-- A8. Channel mix
-- ------------------------------------------------------------
SELECT channel,
       COUNT(*)                                                  AS orders,
       ROUND(SUM(total_amount), 2)                               AS revenue,
       ROUND(AVG(total_amount), 2)                               AS avg_order_value,
       ROUND(100.0 * SUM(total_amount) / SUM(SUM(total_amount)) OVER (), 1) AS revenue_share_pct
FROM orders
WHERE status = 'COMPLETED'
GROUP BY channel
ORDER BY revenue DESC;


-- ------------------------------------------------------------
-- A9. Order status breakdown, with cancellation and return rates
-- ------------------------------------------------------------
SELECT status,
       COUNT(*)                                          AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders,
       ROUND(SUM(total_amount), 2)                       AS order_value,
       ROUND(AVG(total_amount), 2)                       AS avg_order_value
FROM orders
GROUP BY status
ORDER BY orders DESC;


-- ------------------------------------------------------------
-- A10. Payment health by method
-- ------------------------------------------------------------
SELECT method,
       COUNT(*)                                                    AS attempts,
       COUNT(*) FILTER (WHERE payment_status = 'PAID')             AS paid,
       COUNT(*) FILTER (WHERE payment_status = 'FAILED')           AS failed,
       COUNT(*) FILTER (WHERE payment_status = 'PENDING')          AS pending,
       COUNT(*) FILTER (WHERE payment_status = 'REFUNDED')         AS refunded,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_status = 'FAILED')
             / COUNT(*), 2)                                        AS failure_rate_pct,
       ROUND(SUM(amount) FILTER (WHERE payment_status = 'PAID'), 2)     AS collected,
       ROUND(SUM(amount) FILTER (WHERE payment_status = 'REFUNDED'), 2) AS refunded_value
FROM payments
GROUP BY method
ORDER BY attempts DESC;


-- ------------------------------------------------------------
-- A11. Basket size distribution
--
-- Two levels of aggregation: count lines per order first, then
-- count orders per basket size.
-- ------------------------------------------------------------
WITH basket AS (
    SELECT o.order_id,
           COUNT(*)          AS distinct_products,
           SUM(oi.quantity)  AS units,
           o.total_amount
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'COMPLETED'
    GROUP BY o.order_id, o.total_amount
)
SELECT distinct_products               AS lines_in_order,
       COUNT(*)                        AS orders,
       ROUND(AVG(units), 2)            AS avg_units,
       ROUND(AVG(total_amount), 2)     AS avg_order_value,
       ROUND(SUM(total_amount), 2)     AS revenue
FROM basket
GROUP BY distinct_products
ORDER BY lines_in_order;


-- ------------------------------------------------------------
-- A12. Does discounting actually pay for itself?
--
-- Buckets the lines by discount band and compares volume against
-- the margin that is given away.
-- ------------------------------------------------------------
SELECT CASE WHEN oi.discount_pct = 0     THEN '0% (full price)'
            WHEN oi.discount_pct <= 0.05 THEN '1-5%'
            WHEN oi.discount_pct <= 0.10 THEN '6-10%'
            WHEN oi.discount_pct <= 0.15 THEN '11-15%'
            ELSE                              '16%+'
       END                                                                AS discount_band,
       COUNT(*)                                                           AS order_lines,
       SUM(oi.quantity)                                                   AS units_sold,
       ROUND(AVG(oi.quantity), 2)                                         AS avg_units_per_line,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 2)  AS revenue,
       ROUND(SUM(oi.quantity * oi.unit_price * oi.discount_pct), 2)        AS discount_given,
       ROUND(100.0 * (SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))
                      - SUM(oi.quantity * p.cost_price))
             / NULLIF(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 0), 1)
                                                                          AS gross_margin_pct
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- A13. GROUPING SETS - year, year+category and grand total in one
--      pass instead of three separate queries stitched together.
-- ------------------------------------------------------------
SELECT COALESCE(CAST(EXTRACT(YEAR FROM o.order_date) AS VARCHAR), 'ALL YEARS') AS year,
       COALESCE(p.category, 'ALL CATEGORIES')                                  AS category,
       COUNT(DISTINCT o.order_id)                                              AS orders,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)), 2)       AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id  = o.order_id
JOIN products    p  ON p.product_id = oi.product_id
WHERE o.status = 'COMPLETED'
GROUP BY GROUPING SETS (
    (EXTRACT(YEAR FROM o.order_date), p.category),
    (EXTRACT(YEAR FROM o.order_date)),
    ()
)
ORDER BY 1, 4 DESC;
