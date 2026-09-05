-- ============================================================
-- File   : 06_advanced_analytics.sql
-- Purpose: CTEs, subqueries, CASE and window functions applied to
--          growth, ranking, retention and segmentation questions.
-- ============================================================


-- ------------------------------------------------------------
-- W1. Monthly revenue with running total and month-over-month growth
--
-- LAG reaches back one row for the previous month; the SUM(...)
-- OVER (ORDER BY ...) frame accumulates the running total. Both
-- avoid a self join onto the same aggregate.
-- ------------------------------------------------------------
WITH monthly AS (
    SELECT CAST(DATE_TRUNC('month', order_date) AS DATE) AS month,
           COUNT(*)                                      AS orders,
           SUM(total_amount)                             AS revenue
    FROM orders
    WHERE status = 'COMPLETED'
    GROUP BY 1
)
SELECT month,
       orders,
       ROUND(revenue, 2)                                              AS revenue,
       ROUND(SUM(revenue) OVER (ORDER BY month), 2)                   AS running_total,
       ROUND(LAG(revenue) OVER (ORDER BY month), 2)                   AS prev_month_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 1)      AS mom_growth_pct,
       ROUND(AVG(revenue) OVER (ORDER BY month
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                                      AS revenue_3m_moving_avg
FROM monthly
ORDER BY month;


-- ------------------------------------------------------------
-- W2. Year-over-year comparison for the same calendar month
--
-- LAG with an offset of 12 over a month-of-year partition lines
-- each month up against the same month a year earlier, which
-- strips out seasonality.
-- ------------------------------------------------------------
WITH monthly AS (
    SELECT EXTRACT(YEAR  FROM order_date) AS yr,
           EXTRACT(MONTH FROM order_date) AS mth,
           SUM(total_amount)              AS revenue
    FROM orders
    WHERE status = 'COMPLETED'
    GROUP BY 1, 2
)
SELECT yr,
       mth,
       ROUND(revenue, 2)                                                  AS revenue,
       ROUND(LAG(revenue) OVER (PARTITION BY mth ORDER BY yr), 2)         AS same_month_last_year,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (PARTITION BY mth ORDER BY yr))
             / NULLIF(LAG(revenue) OVER (PARTITION BY mth ORDER BY yr), 0), 1)
                                                                          AS yoy_growth_pct
FROM monthly
ORDER BY yr, mth;


-- ------------------------------------------------------------
-- W3. Customer revenue ranking
--
-- RANK, DENSE_RANK and ROW_NUMBER side by side, plus PERCENT_RANK
-- and NTILE(4) to place each customer in a quartile.
-- ------------------------------------------------------------
WITH customer_revenue AS (
    SELECT c.customer_id,
           c.name,
           c.city,
           COUNT(o.order_id)   AS orders,
           SUM(o.total_amount) AS revenue
    FROM customers c
    JOIN orders o ON o.customer_id = c.customer_id
    WHERE o.status = 'COMPLETED'
    GROUP BY c.customer_id, c.name, c.city
)
SELECT name,
       city,
       orders,
       ROUND(revenue, 2)                                     AS revenue,
       RANK()       OVER (ORDER BY revenue DESC)             AS revenue_rank,
       DENSE_RANK() OVER (ORDER BY revenue DESC)             AS dense_rank,
       ROW_NUMBER() OVER (ORDER BY revenue DESC)             AS row_num,
       ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY revenue), 1) AS percentile,
       NTILE(4)     OVER (ORDER BY revenue DESC)             AS revenue_quartile
FROM customer_revenue
ORDER BY revenue DESC
LIMIT 20;


-- ------------------------------------------------------------
-- W4. Top 3 products inside each category
--
-- ROW_NUMBER partitioned by category, then filtered in an outer
-- query. Window functions cannot be used in WHERE, which is why
-- the subquery wrapper is needed.
-- ------------------------------------------------------------
WITH product_revenue AS (
    SELECT p.category,
           p.product_name,
           SUM(oi.quantity)                                            AS units,
           SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct))     AS revenue
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.status = 'COMPLETED'
    GROUP BY p.category, p.product_name
),
ranked AS (
    SELECT category,
           product_name,
           units,
           revenue,
           ROW_NUMBER() OVER (PARTITION BY category ORDER BY revenue DESC) AS rn,
           ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY category), 1)
                                                                          AS pct_of_category
    FROM product_revenue
)
SELECT category, rn AS rank_in_category, product_name, units,
       ROUND(revenue, 2) AS revenue, pct_of_category
FROM ranked
WHERE rn <= 3
ORDER BY category, rn;


-- ------------------------------------------------------------
-- W5. Pareto check - how few products carry 80% of revenue
--
-- Cumulative share via a running SUM over the ordered revenue,
-- divided by the grand total from an unbounded window.
-- ------------------------------------------------------------
WITH product_revenue AS (
    SELECT p.product_name,
           p.category,
           SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)) AS revenue
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.status = 'COMPLETED'
    GROUP BY p.product_name, p.category
),
cumulative AS (
    SELECT product_name,
           category,
           revenue,
           ROW_NUMBER() OVER (ORDER BY revenue DESC)                     AS rn,
           SUM(revenue) OVER (ORDER BY revenue DESC)                     AS running_revenue,
           SUM(revenue) OVER ()                                          AS total_revenue,
           COUNT(*)     OVER ()                                          AS product_count
    FROM product_revenue
)
SELECT rn                                                    AS rank,
       product_name,
       category,
       ROUND(revenue, 2)                                     AS revenue,
       ROUND(100.0 * running_revenue / total_revenue, 1)      AS cumulative_revenue_pct,
       ROUND(100.0 * rn / product_count, 1)                   AS cumulative_product_pct,
       CASE WHEN 100.0 * running_revenue / total_revenue <= 80 THEN 'CORE 80%'
            ELSE 'LONG TAIL'
       END                                                    AS pareto_band
FROM cumulative
ORDER BY rn;


-- ------------------------------------------------------------
-- W6. Repeat purchase behaviour
--
-- LAG over each customer's own order history gives the gap between
-- consecutive orders, which is the input to any churn definition.
-- ------------------------------------------------------------
WITH ordered AS (
    SELECT o.customer_id,
           c.name,
           o.order_id,
           o.order_date,
           o.total_amount,
           ROW_NUMBER() OVER (PARTITION BY o.customer_id ORDER BY o.order_date, o.order_id)
                                                                            AS order_seq,
           LAG(o.order_date) OVER (PARTITION BY o.customer_id ORDER BY o.order_date, o.order_id)
                                                                            AS prev_order_date
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.status = 'COMPLETED'
)
SELECT customer_id,
       name,
       COUNT(*)                                                 AS orders,
       ROUND(AVG(order_date - prev_order_date), 1)              AS avg_days_between_orders,
       MIN(order_date - prev_order_date)                        AS fastest_repeat_days,
       MAX(order_date - prev_order_date)                        AS longest_gap_days,
       MAX(order_date)                                          AS last_order_date,
       CURRENT_DATE - MAX(order_date)                           AS days_since_last_order
FROM ordered
GROUP BY customer_id, name
HAVING COUNT(*) >= 5
ORDER BY avg_days_between_orders
LIMIT 20;


-- ------------------------------------------------------------
-- W7. First order versus repeat orders
--
-- Splits revenue into acquisition and retention. A business that
-- lives off first orders has a very different problem to one that
-- lives off repeats.
-- ------------------------------------------------------------
WITH seq AS (
    SELECT o.order_id,
           o.customer_id,
           o.order_date,
           o.total_amount,
           ROW_NUMBER() OVER (PARTITION BY o.customer_id ORDER BY o.order_date, o.order_id) AS order_seq
    FROM orders o
    WHERE o.status = 'COMPLETED'
)
SELECT CASE WHEN order_seq = 1 THEN 'FIRST ORDER' ELSE 'REPEAT ORDER' END AS order_type,
       COUNT(*)                                                           AS orders,
       COUNT(DISTINCT customer_id)                                        AS customers,
       ROUND(SUM(total_amount), 2)                                        AS revenue,
       ROUND(AVG(total_amount), 2)                                        AS avg_order_value,
       ROUND(100.0 * SUM(total_amount) / SUM(SUM(total_amount)) OVER (), 1) AS revenue_share_pct
FROM seq
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- W8. New vs returning customers per month
-- ------------------------------------------------------------
WITH first_order AS (
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders
    WHERE status = 'COMPLETED'
    GROUP BY customer_id
)
SELECT CAST(DATE_TRUNC('month', o.order_date) AS DATE) AS month,
       COUNT(DISTINCT o.customer_id)                   AS active_customers,
       COUNT(DISTINCT o.customer_id) FILTER (
            WHERE DATE_TRUNC('month', f.first_order_date)
                = DATE_TRUNC('month', o.order_date))   AS new_customers,
       COUNT(DISTINCT o.customer_id) FILTER (
            WHERE DATE_TRUNC('month', f.first_order_date)
                < DATE_TRUNC('month', o.order_date))   AS returning_customers,
       ROUND(SUM(o.total_amount), 2)                   AS revenue
FROM orders o
JOIN first_order f ON f.customer_id = o.customer_id
WHERE o.status = 'COMPLETED'
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- W9. Acquisition cohort retention
--
-- Customers are bucketed by the month of their first order, then
-- tracked forward. month_offset 0 is the acquisition month itself.
-- ------------------------------------------------------------
WITH first_order AS (
    SELECT customer_id,
           CAST(DATE_TRUNC('month', MIN(order_date)) AS DATE) AS cohort_month
    FROM orders
    WHERE status = 'COMPLETED'
    GROUP BY customer_id
),
activity AS (
    SELECT f.cohort_month,
           CAST(DATE_TRUNC('month', o.order_date) AS DATE) AS activity_month,
           o.customer_id,
           o.total_amount
    FROM orders o
    JOIN first_order f ON f.customer_id = o.customer_id
    WHERE o.status = 'COMPLETED'
),
sized AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM first_order f
    GROUP BY cohort_month
)
SELECT a.cohort_month,
       s.cohort_size,
       (EXTRACT(YEAR FROM a.activity_month) - EXTRACT(YEAR FROM a.cohort_month)) * 12
        + (EXTRACT(MONTH FROM a.activity_month) - EXTRACT(MONTH FROM a.cohort_month))
                                                                     AS month_offset,
       COUNT(DISTINCT a.customer_id)                                 AS active_customers,
       ROUND(100.0 * COUNT(DISTINCT a.customer_id) / s.cohort_size, 1) AS retention_pct,
       ROUND(SUM(a.total_amount), 2)                                 AS revenue
FROM activity a
JOIN sized s ON s.cohort_month = a.cohort_month
GROUP BY a.cohort_month, s.cohort_size, 3
HAVING (EXTRACT(YEAR FROM a.activity_month) - EXTRACT(YEAR FROM a.cohort_month)) * 12
        + (EXTRACT(MONTH FROM a.activity_month) - EXTRACT(MONTH FROM a.cohort_month)) <= 6
ORDER BY a.cohort_month, month_offset;


-- ------------------------------------------------------------
-- W10. RFM segmentation
--
-- Recency, Frequency and Monetary value are each scored 1-5 with
-- NTILE, then combined into a plain-English segment. This is the
-- classic CRM segmentation, done entirely in SQL.
-- ------------------------------------------------------------
WITH base AS (
    SELECT c.customer_id,
           c.name,
           c.city,
           CURRENT_DATE - MAX(o.order_date) AS recency_days,
           COUNT(o.order_id)                AS frequency,
           SUM(o.total_amount)              AS monetary
    FROM customers c
    JOIN orders o ON o.customer_id = c.customer_id
    WHERE o.status = 'COMPLETED'
    GROUP BY c.customer_id, c.name, c.city
),
scored AS (
    SELECT base.*,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,  -- lower recency wins
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,
           NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM base
)
SELECT customer_id,
       name,
       city,
       recency_days,
       frequency,
       ROUND(monetary, 2) AS monetary,
       r_score, f_score, m_score,
       CAST(r_score AS VARCHAR) || CAST(f_score AS VARCHAR) || CAST(m_score AS VARCHAR) AS rfm_cell,
       CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal'
            WHEN r_score >= 4 AND f_score <= 2                  THEN 'New / Promising'
            WHEN r_score <= 2 AND f_score >= 4                  THEN 'At Risk - was valuable'
            WHEN r_score <= 2 AND m_score >= 4                  THEN 'Cannot Lose Them'
            WHEN r_score <= 2                                   THEN 'Hibernating'
            ELSE                                                     'Needs Attention'
       END AS segment
FROM scored
ORDER BY monetary DESC;


-- ------------------------------------------------------------
-- W11. Segment roll up - how much revenue sits in each RFM bucket
-- ------------------------------------------------------------
WITH base AS (
    SELECT c.customer_id,
           CURRENT_DATE - MAX(o.order_date) AS recency_days,
           COUNT(o.order_id)                AS frequency,
           SUM(o.total_amount)              AS monetary
    FROM customers c
    JOIN orders o ON o.customer_id = c.customer_id
    WHERE o.status = 'COMPLETED'
    GROUP BY c.customer_id
),
scored AS (
    SELECT base.*,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,
           NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM base
),
labelled AS (
    SELECT scored.*,
           CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
                WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal'
                WHEN r_score >= 4 AND f_score <= 2                  THEN 'New / Promising'
                WHEN r_score <= 2 AND f_score >= 4                  THEN 'At Risk - was valuable'
                WHEN r_score <= 2 AND m_score >= 4                  THEN 'Cannot Lose Them'
                WHEN r_score <= 2                                   THEN 'Hibernating'
                ELSE                                                     'Needs Attention'
           END AS segment
    FROM scored
)
SELECT segment,
       COUNT(*)                                                        AS customers,
       ROUND(AVG(recency_days), 0)                                     AS avg_recency_days,
       ROUND(AVG(frequency), 1)                                        AS avg_orders,
       ROUND(SUM(monetary), 2)                                         AS revenue,
       ROUND(AVG(monetary), 2)                                         AS avg_lifetime_value,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1)    AS revenue_share_pct
FROM labelled
GROUP BY segment
ORDER BY revenue DESC;


-- ------------------------------------------------------------
-- W12. Correlated subquery - each customer's single biggest order
--
-- The inner query is evaluated per customer. Readable, but it is
-- also the pattern most worth replacing with a window function on
-- large tables (see 08_indexes_optimization.sql).
-- ------------------------------------------------------------
SELECT c.customer_id,
       c.name,
       (SELECT MAX(o.total_amount)
        FROM orders o
        WHERE o.customer_id = c.customer_id
          AND o.status = 'COMPLETED')                      AS biggest_order,
       (SELECT COUNT(*)
        FROM orders o
        WHERE o.customer_id = c.customer_id
          AND o.status = 'COMPLETED')                      AS completed_orders
FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o
              WHERE o.customer_id = c.customer_id
                AND o.status = 'COMPLETED')
ORDER BY biggest_order DESC
LIMIT 10;


-- ------------------------------------------------------------
-- W13. Above-average orders
--
-- A scalar subquery in the WHERE clause: every order compared
-- against the global average order value.
-- ------------------------------------------------------------
SELECT o.order_id,
       c.name,
       o.order_date,
       o.total_amount,
       ROUND(o.total_amount - (SELECT AVG(total_amount) FROM orders WHERE status = 'COMPLETED'), 2)
            AS amount_above_average
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.status = 'COMPLETED'
  AND o.total_amount > (SELECT AVG(total_amount) * 3 FROM orders WHERE status = 'COMPLETED')
ORDER BY o.total_amount DESC
LIMIT 15;
