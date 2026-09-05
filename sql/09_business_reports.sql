-- ============================================================
-- File   : 09_business_reports.sql
-- Purpose: The finished report pack, written against the views in
--          07_views.sql rather than the raw tables.
--
-- Each report is tagged with a "-- @report <name>" marker. The
-- runner in tools/run_project.py picks those up and exports the
-- result of the statement that follows to output/<name>.csv.
-- ============================================================


-- @report r01_executive_kpis
-- Everything a weekly business review needs on one line.
WITH o AS (
    SELECT * FROM v_order_summary
)
SELECT COUNT(*)                                                      AS total_orders,
       COUNT(*) FILTER (WHERE status = 'COMPLETED')                  AS completed_orders,
       COUNT(DISTINCT customer_id)                                   AS buying_customers,
       ROUND(SUM(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS revenue,
       ROUND(SUM(gross_profit) FILTER (WHERE status = 'COMPLETED'), 2) AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) FILTER (WHERE status = 'COMPLETED')
             / NULLIF(SUM(total_amount) FILTER (WHERE status = 'COMPLETED'), 0), 1)
                                                                     AS gross_margin_pct,
       ROUND(AVG(total_amount) FILTER (WHERE status = 'COMPLETED'), 2) AS avg_order_value,
       ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'CANCELLED') / COUNT(*), 2)
                                                                     AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'RETURNED')  / COUNT(*), 2)
                                                                     AS return_rate_pct,
       ROUND(SUM(net_collected), 2)                                  AS net_cash_collected
FROM o;


-- @report r02_monthly_trend
-- Revenue, profit and growth by month.
SELECT * FROM v_monthly_revenue ORDER BY order_month;


-- @report r03_category_scorecard
SELECT category,
       COUNT(DISTINCT product_id)                                   AS products,
       COUNT(DISTINCT product_id) FILTER (WHERE units_sold > 0)     AS products_with_sales,
       SUM(units_sold)                                              AS units_sold,
       ROUND(SUM(revenue), 2)                                       AS revenue,
       ROUND(SUM(gross_profit), 2)                                  AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(revenue), 0), 1) AS gross_margin_pct,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)    AS revenue_share_pct
FROM v_product_performance
GROUP BY category
ORDER BY revenue DESC;


-- @report r04_top_products
SELECT product_name,
       category,
       units_sold,
       orders,
       distinct_buyers,
       revenue,
       gross_profit,
       gross_margin_pct,
       avg_discount_pct,
       last_sold_on
FROM v_product_performance
WHERE units_sold > 0
ORDER BY revenue DESC
LIMIT 15;


-- @report r05_underperforming_stock
-- Products with capital sitting in them and little or no demand.
-- This is the delist / clearance candidate list.
SELECT product_name,
       category,
       price,
       stock,
       is_active,
       units_sold,
       revenue,
       last_sold_on,
       ROUND(stock * cost_price, 2) AS capital_tied_up,
       CASE WHEN units_sold = 0                     THEN 'NEVER SOLD'
            WHEN last_sold_on < CURRENT_DATE - 180  THEN 'STALE - no sale in 6 months'
            ELSE                                         'LOW VELOCITY'
       END                          AS flag
FROM v_product_performance
WHERE units_sold < 25
ORDER BY capital_tied_up DESC, units_sold;


-- @report r06_customer_segments
SELECT buyer_type,
       COUNT(*)                                                      AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)            AS pct_of_customers,
       SUM(completed_orders)                                         AS orders,
       ROUND(SUM(lifetime_revenue), 2)                               AS revenue,
       ROUND(100.0 * SUM(lifetime_revenue) / SUM(SUM(lifetime_revenue)) OVER (), 1)
                                                                     AS revenue_share_pct,
       ROUND(AVG(lifetime_revenue), 2)                               AS avg_lifetime_value,
       ROUND(AVG(days_since_last_order), 0)                          AS avg_days_since_last_order
FROM v_customer_value
GROUP BY buyer_type
ORDER BY revenue DESC;


-- @report r07_top_customers
SELECT customer_id,
       name,
       city,
       state,
       signup_date,
       completed_orders,
       lifetime_revenue,
       avg_order_value,
       first_order_date,
       last_order_date,
       days_since_last_order,
       buyer_type
FROM v_customer_value
WHERE completed_orders > 0
ORDER BY lifetime_revenue DESC
LIMIT 20;


-- @report r08_city_performance
SELECT state,
       city,
       COUNT(*)                                                  AS customers,
       SUM(completed_orders)                                     AS orders,
       ROUND(SUM(lifetime_revenue), 2)                           AS revenue,
       ROUND(SUM(lifetime_revenue) / NULLIF(SUM(completed_orders), 0), 2) AS avg_order_value,
       ROUND(SUM(lifetime_revenue) / COUNT(*), 2)                AS revenue_per_customer
FROM v_customer_value
GROUP BY state, city
HAVING SUM(completed_orders) > 0
ORDER BY revenue DESC;


-- @report r09_channel_performance
SELECT channel,
       COUNT(*)                                                       AS orders,
       COUNT(DISTINCT customer_id)                                    AS customers,
       ROUND(SUM(total_amount), 2)                                    AS revenue,
       ROUND(AVG(total_amount), 2)                                    AS avg_order_value,
       ROUND(SUM(gross_profit), 2)                                    AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(total_amount), 0), 1) AS gross_margin_pct,
       ROUND(100.0 * SUM(total_amount) / SUM(SUM(total_amount)) OVER (), 1) AS revenue_share_pct
FROM v_order_summary
WHERE status = 'COMPLETED'
GROUP BY channel
ORDER BY revenue DESC;


-- @report r10_payment_reconciliation
SELECT * FROM v_payment_reconciliation ORDER BY order_month;


-- @report r11_loss_analysis
-- What cancellations and returns cost, split by category, so the
-- problem can be pinned on specific products rather than guessed.
SELECT l.category,
       COUNT(DISTINCT l.order_id) FILTER (WHERE l.order_status = 'CANCELLED') AS cancelled_orders,
       COUNT(DISTINCT l.order_id) FILTER (WHERE l.order_status = 'RETURNED')  AS returned_orders,
       ROUND(SUM(l.line_revenue) FILTER (WHERE l.order_status = 'CANCELLED'), 2) AS cancelled_value,
       ROUND(SUM(l.line_revenue) FILTER (WHERE l.order_status = 'RETURNED'), 2)  AS returned_value,
       ROUND(SUM(l.line_revenue) FILTER (WHERE l.order_status IN ('CANCELLED','RETURNED')), 2)
                                                                              AS total_lost_value,
       ROUND(100.0 * SUM(l.line_revenue) FILTER (WHERE l.order_status IN ('CANCELLED','RETURNED'))
             / NULLIF(SUM(l.line_revenue), 0), 1)                             AS loss_rate_pct
FROM v_order_lines l
GROUP BY l.category
ORDER BY total_lost_value DESC;


-- @report r12_recent_90_days
-- A rolling window that does not care which month it is in.
SELECT CURRENT_DATE - 90                                              AS window_start,
       CURRENT_DATE                                                   AS window_end,
       COUNT(*)                                                       AS orders,
       COUNT(DISTINCT customer_id)                                    AS active_customers,
       ROUND(SUM(total_amount), 2)                                    AS revenue,
       ROUND(AVG(total_amount), 2)                                    AS avg_order_value,
       ROUND(SUM(gross_profit), 2)                                    AS gross_profit
FROM v_order_summary
WHERE order_date >= CURRENT_DATE - 90
  AND status IN ('COMPLETED', 'SHIPPED', 'PLACED');


-- @report r13_reorder_alert
-- Sell-through speed against what is left on the shelf. weeks_of_
-- cover is the number of weeks current stock lasts at the last 90
-- days' rate; anything under 4 needs a purchase order.
WITH recent AS (
    SELECT product_id,
           SUM(quantity) AS units_90d
    FROM v_order_lines
    WHERE order_status = 'COMPLETED'
      AND order_date >= CURRENT_DATE - 90
    GROUP BY product_id
)
SELECT p.product_name,
       p.category,
       p.stock,
       COALESCE(r.units_90d, 0)                                   AS units_last_90d,
       ROUND(COALESCE(r.units_90d, 0) / 13.0, 2)                  AS units_per_week,
       CASE WHEN COALESCE(r.units_90d, 0) = 0 THEN NULL
            ELSE ROUND(p.stock / (r.units_90d / 13.0), 1)
       END                                                        AS weeks_of_cover,
       CASE WHEN COALESCE(r.units_90d, 0) = 0     THEN 'NO RECENT DEMAND'
            WHEN p.stock = 0                      THEN 'STOCKOUT - reorder now'
            WHEN p.stock / (r.units_90d / 13.0) < 4  THEN 'REORDER'
            WHEN p.stock / (r.units_90d / 13.0) < 12 THEN 'MONITOR'
            ELSE                                        'SUFFICIENT'
       END                                                        AS action
FROM products p
LEFT JOIN recent r ON r.product_id = p.product_id
WHERE p.is_active = TRUE
ORDER BY CASE WHEN COALESCE(r.units_90d, 0) = 0 THEN 9999
              ELSE p.stock / (r.units_90d / 13.0) END,
         p.product_name;
