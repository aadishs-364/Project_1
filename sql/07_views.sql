-- ============================================================
-- File   : 07_views.sql
-- Purpose: Reusable reporting layer.
--
-- The idea is that no dashboard or ad-hoc query should have to
-- re-derive "what is revenue" or "what is a paid order". Those
-- definitions live here once, and everything else selects from
-- these views.
--
-- v_order_lines is the base fact view; the rest build on it.
-- ============================================================


-- ------------------------------------------------------------
-- v_order_lines - the grain is one order line
--
-- This is the workhorse. It resolves the customer, the product and
-- the derived money columns (line revenue, line cost, line profit)
-- so nobody has to remember the discount formula again.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_order_lines AS
SELECT oi.order_item_id,
       o.order_id,
       o.order_date,
       CAST(DATE_TRUNC('month', o.order_date) AS DATE)                    AS order_month,
       o.status                                                          AS order_status,
       o.channel,
       c.customer_id,
       c.name                                                            AS customer_name,
       c.city,
       c.state,
       p.product_id,
       p.product_name,
       p.category,
       oi.quantity,
       oi.unit_price,
       oi.discount_pct,
       ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct), 2)      AS line_revenue,
       ROUND(oi.quantity * p.cost_price, 2)                               AS line_cost,
       ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct)
             - oi.quantity * p.cost_price, 2)                             AS line_profit,
       ROUND(oi.quantity * oi.unit_price * oi.discount_pct, 2)            AS line_discount
FROM order_items oi
JOIN orders    o ON o.order_id   = oi.order_id
JOIN customers c ON c.customer_id = o.customer_id
JOIN products  p ON p.product_id = oi.product_id;


-- ------------------------------------------------------------
-- v_order_summary - one row per order, with payment state resolved
--
-- payment_state collapses the (possibly several) payment rows an
-- order can have into a single answer: was this order actually
-- collected, refunded, or is money still outstanding?
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_order_summary AS
SELECT o.order_id,
       o.order_date,
       CAST(DATE_TRUNC('month', o.order_date) AS DATE)  AS order_month,
       o.status,
       o.channel,
       c.customer_id,
       c.name                                           AS customer_name,
       c.city,
       c.state,
       li.line_count,
       li.units,
       o.total_amount,
       li.cost,
       ROUND(o.total_amount - li.cost, 2)               AS gross_profit,
       COALESCE(pm.paid_amount, 0)                      AS paid_amount,
       COALESCE(pm.refunded_amount, 0)                  AS refunded_amount,
       COALESCE(pm.paid_amount, 0)
         - COALESCE(pm.refunded_amount, 0)              AS net_collected,
       CASE WHEN COALESCE(pm.refunded_amount, 0) > 0                 THEN 'REFUNDED'
            WHEN COALESCE(pm.paid_amount, 0)     > 0                 THEN 'COLLECTED'
            WHEN pm.pending_attempts > 0                             THEN 'AWAITING_PAYMENT'
            WHEN pm.failed_attempts  > 0                             THEN 'PAYMENT_FAILED'
            ELSE                                                          'NO_PAYMENT_RECORD'
       END                                              AS payment_state
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN (
    SELECT oi.order_id,
           COUNT(*)                                  AS line_count,
           SUM(oi.quantity)                          AS units,
           ROUND(SUM(oi.quantity * p.cost_price), 2) AS cost
    FROM order_items oi
    JOIN products p ON p.product_id = oi.product_id
    GROUP BY oi.order_id
) li ON li.order_id = o.order_id
LEFT JOIN (
    SELECT order_id,
           SUM(amount) FILTER (WHERE payment_status = 'PAID')     AS paid_amount,
           SUM(amount) FILTER (WHERE payment_status = 'REFUNDED') AS refunded_amount,
           COUNT(*)    FILTER (WHERE payment_status = 'PENDING')  AS pending_attempts,
           COUNT(*)    FILTER (WHERE payment_status = 'FAILED')   AS failed_attempts
    FROM payments
    GROUP BY order_id
) pm ON pm.order_id = o.order_id;


-- ------------------------------------------------------------
-- v_monthly_revenue - the monthly trend line, ready for a chart
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_revenue AS
WITH m AS (
    SELECT order_month,
           COUNT(*)                    AS orders,
           COUNT(DISTINCT customer_id) AS customers,
           SUM(units)                  AS units,
           SUM(total_amount)           AS revenue,
           SUM(gross_profit)           AS gross_profit
    FROM v_order_summary
    WHERE status = 'COMPLETED'
    GROUP BY order_month
)
SELECT order_month,
       orders,
       customers,
       units,
       ROUND(revenue, 2)                                            AS revenue,
       ROUND(gross_profit, 2)                                       AS gross_profit,
       ROUND(revenue / orders, 2)                                   AS avg_order_value,
       ROUND(SUM(revenue) OVER (ORDER BY order_month), 2)           AS running_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
             / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0), 1) AS mom_growth_pct
FROM m;


-- ------------------------------------------------------------
-- v_product_performance - catalogue scorecard
--
-- LEFT JOIN from products so items that never sold still appear
-- with zeros instead of vanishing.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_product_performance AS
SELECT p.product_id,
       p.product_name,
       p.category,
       p.price,
       p.cost_price,
       p.stock,
       p.is_active,
       COALESCE(SUM(l.quantity), 0)                                     AS units_sold,
       COUNT(DISTINCT l.order_id)                                       AS orders,
       COUNT(DISTINCT l.customer_id)                                    AS distinct_buyers,
       ROUND(COALESCE(SUM(l.line_revenue), 0), 2)                       AS revenue,
       ROUND(COALESCE(SUM(l.line_profit), 0), 2)                        AS gross_profit,
       ROUND(100.0 * COALESCE(SUM(l.line_profit), 0)
             / NULLIF(SUM(l.line_revenue), 0), 1)                       AS gross_margin_pct,
       ROUND(COALESCE(AVG(l.discount_pct), 0) * 100, 1)                 AS avg_discount_pct,
       MAX(l.order_date)                                                AS last_sold_on
FROM products p
LEFT JOIN v_order_lines l
       ON l.product_id = p.product_id
      AND l.order_status = 'COMPLETED'
GROUP BY p.product_id, p.product_name, p.category, p.price,
         p.cost_price, p.stock, p.is_active;


-- ------------------------------------------------------------
-- v_customer_value - one row per customer, CRM ready
--
-- Includes customers who never ordered (LEFT JOIN), because the
-- "registered but never bought" group is itself a report.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_value AS
SELECT c.customer_id,
       c.name,
       c.email,
       c.city,
       c.state,
       c.signup_date,
       COUNT(s.order_id)                                        AS total_orders,
       COUNT(s.order_id) FILTER (WHERE s.status = 'COMPLETED')  AS completed_orders,
       COUNT(s.order_id) FILTER (WHERE s.status = 'CANCELLED')  AS cancelled_orders,
       COUNT(s.order_id) FILTER (WHERE s.status = 'RETURNED')   AS returned_orders,
       ROUND(COALESCE(SUM(s.total_amount) FILTER (WHERE s.status = 'COMPLETED'), 0), 2)
                                                                AS lifetime_revenue,
       ROUND(COALESCE(AVG(s.total_amount) FILTER (WHERE s.status = 'COMPLETED'), 0), 2)
                                                                AS avg_order_value,
       MIN(s.order_date) FILTER (WHERE s.status = 'COMPLETED')  AS first_order_date,
       MAX(s.order_date) FILTER (WHERE s.status = 'COMPLETED')  AS last_order_date,
       CURRENT_DATE - MAX(s.order_date) FILTER (WHERE s.status = 'COMPLETED')
                                                                AS days_since_last_order,
       CASE WHEN COUNT(s.order_id) FILTER (WHERE s.status = 'COMPLETED') = 0 THEN 'NEVER_PURCHASED'
            WHEN COUNT(s.order_id) FILTER (WHERE s.status = 'COMPLETED') = 1 THEN 'ONE_TIME'
            WHEN COUNT(s.order_id) FILTER (WHERE s.status = 'COMPLETED') <= 4 THEN 'OCCASIONAL'
            ELSE                                                                  'REPEAT'
       END                                                      AS buyer_type
FROM customers c
LEFT JOIN v_order_summary s ON s.customer_id = c.customer_id
GROUP BY c.customer_id, c.name, c.email, c.city, c.state, c.signup_date;


-- ------------------------------------------------------------
-- v_payment_reconciliation - order book against settled cash
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_payment_reconciliation AS
SELECT order_month,
       COUNT(*)                                                       AS orders,
       ROUND(SUM(total_amount), 2)                                    AS booked_value,
       ROUND(SUM(paid_amount), 2)                                     AS gross_collected,
       ROUND(SUM(refunded_amount), 2)                                 AS refunded,
       ROUND(SUM(net_collected), 2)                                   AS net_collected,
       ROUND(SUM(total_amount) FILTER (WHERE payment_state IN
             ('AWAITING_PAYMENT', 'PAYMENT_FAILED', 'NO_PAYMENT_RECORD')), 2)
                                                                      AS uncollected_value,
       ROUND(100.0 * SUM(net_collected) / NULLIF(SUM(total_amount), 0), 1)
                                                                      AS collection_rate_pct
FROM v_order_summary
GROUP BY order_month;


-- ------------------------------------------------------------
-- Smoke tests - prove each view returns something sensible
-- ------------------------------------------------------------
SELECT * FROM v_order_lines            ORDER BY order_id DESC, product_name LIMIT 10;
SELECT * FROM v_order_summary          ORDER BY order_date DESC, order_id DESC LIMIT 10;
SELECT * FROM v_monthly_revenue        ORDER BY order_month;
SELECT * FROM v_product_performance    ORDER BY revenue DESC LIMIT 10;
SELECT * FROM v_customer_value         ORDER BY lifetime_revenue DESC LIMIT 10;
SELECT * FROM v_payment_reconciliation ORDER BY order_month;
