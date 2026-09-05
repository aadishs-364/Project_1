-- ============================================================
-- File   : 10_postgres_extensions.sql
-- Purpose: The advanced extensions from the brief - triggers and
--          audit history, stored procedures and functions,
--          materialised views, and a partitioning plan.
--
-- POSTGRESQL ONLY. Everything here uses PL/pgSQL, materialised
-- views or declarative partitioning, none of which DuckDB
-- supports, so tools/run_project.py deliberately skips this file.
-- Run it with:  psql -d sales_analytics -f sql/10_postgres_extensions.sql
-- after 01 through 09.
-- ============================================================


-- ============================================================
-- 1. AUDIT HISTORY VIA TRIGGERS
--
-- orders.status is the column the business argues about most
-- ("when did this actually ship?"), so every change to it is
-- recorded. The trigger is AFTER UPDATE so it only fires once the
-- row change has been accepted.
-- ============================================================

CREATE TABLE IF NOT EXISTS order_status_history (
    history_id   BIGSERIAL PRIMARY KEY,
    order_id     INTEGER     NOT NULL REFERENCES orders(order_id),
    old_status   VARCHAR(20),
    new_status   VARCHAR(20) NOT NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    changed_by   TEXT        NOT NULL DEFAULT CURRENT_USER
);

CREATE INDEX IF NOT EXISTS idx_status_history_order
    ON order_status_history(order_id, changed_at);


CREATE OR REPLACE FUNCTION trg_log_order_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- IS DISTINCT FROM rather than <> so a NULL on either side is
    -- still treated as a change.
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO order_status_history (order_id, old_status, new_status)
        VALUES (NEW.order_id, OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_status_audit ON orders;
CREATE TRIGGER orders_status_audit
    AFTER UPDATE OF status ON orders
    FOR EACH ROW
    EXECUTE FUNCTION trg_log_order_status();


-- ------------------------------------------------------------
-- 1b. Keep orders.total_amount honest
--
-- total_amount is denormalised, which means it can drift away from
-- the lines. This trigger recalculates it whenever the lines
-- change, so the reconciliation check in 03 can never fail.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_refresh_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_order INTEGER := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    -- Round per line, then sum. Matches v_order_lines.line_revenue
    -- and the header_vs_lines check in 03_crud_operations.sql.
    UPDATE orders o
    SET total_amount = COALESCE((
            SELECT SUM(ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct), 2))
            FROM order_items oi
            WHERE oi.order_id = affected_order), 0)
    WHERE o.order_id = affected_order;

    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

DROP TRIGGER IF EXISTS order_items_refresh_total ON order_items;
CREATE TRIGGER order_items_refresh_total
    AFTER INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW
    EXECUTE FUNCTION trg_refresh_order_total();


-- ============================================================
-- 2. STORED PROCEDURE - place a complete order atomically
--
-- Takes a customer and an array of (product_id, quantity) pairs,
-- checks stock, prices the lines off the current catalogue, writes
-- the header, the lines and the payment, and decrements stock.
-- Any exception rolls the whole thing back.
-- ============================================================

CREATE OR REPLACE PROCEDURE place_order(
    p_customer_id  INTEGER,
    p_product_ids  INTEGER[],
    p_quantities   INTEGER[],
    p_channel      VARCHAR DEFAULT 'WEB',
    p_method       VARCHAR DEFAULT 'UPI',
    INOUT p_order_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    i             INTEGER;
    v_price       DECIMAL(12,2);
    v_stock       INTEGER;
    v_total       DECIMAL(12,2) := 0;
BEGIN
    IF array_length(p_product_ids, 1) IS DISTINCT FROM array_length(p_quantities, 1) THEN
        RAISE EXCEPTION 'product and quantity arrays must be the same length';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'customer % does not exist', p_customer_id;
    END IF;

    SELECT COALESCE(MAX(order_id), 0) + 1 INTO p_order_id FROM orders;

    INSERT INTO orders (order_id, customer_id, order_date, status, channel, total_amount)
    VALUES (p_order_id, p_customer_id, CURRENT_DATE, 'PLACED', p_channel, 0);

    FOR i IN 1 .. array_length(p_product_ids, 1) LOOP
        -- FOR UPDATE locks the product row so two concurrent orders
        -- cannot both pass the stock check on the same last unit.
        SELECT price, stock INTO v_price, v_stock
        FROM products
        WHERE product_id = p_product_ids[i]
          AND is_active = TRUE
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'product % is not available', p_product_ids[i];
        END IF;

        IF v_stock < p_quantities[i] THEN
            RAISE EXCEPTION 'insufficient stock for product %: have %, need %',
                            p_product_ids[i], v_stock, p_quantities[i];
        END IF;

        INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price, discount_pct)
        VALUES ((SELECT COALESCE(MAX(order_item_id), 0) + 1 FROM order_items),
                p_order_id, p_product_ids[i], p_quantities[i], v_price, 0);

        UPDATE products
        SET stock = stock - p_quantities[i]
        WHERE product_id = p_product_ids[i];

        v_total := v_total + (v_price * p_quantities[i]);
    END LOOP;

    UPDATE orders SET total_amount = ROUND(v_total, 2) WHERE order_id = p_order_id;

    INSERT INTO payments (payment_id, order_id, payment_date, amount, method, payment_status)
    VALUES ((SELECT COALESCE(MAX(payment_id), 0) + 1 FROM payments),
            p_order_id, CURRENT_DATE, ROUND(v_total, 2), p_method, 'PENDING');
END;
$$;

-- Example:
-- CALL place_order(12, ARRAY[3, 30, 35], ARRAY[1, 2, 3], 'MOBILE_APP', 'UPI');


-- ============================================================
-- 3. FUNCTIONS
-- ============================================================

-- Lifetime value of a single customer, as a scalar function.
CREATE OR REPLACE FUNCTION customer_lifetime_value(p_customer_id INTEGER)
RETURNS DECIMAL(14,2)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(total_amount), 0)
    FROM orders
    WHERE customer_id = p_customer_id
      AND status = 'COMPLETED';
$$;


-- Revenue for an arbitrary window, returned as a result set.
CREATE OR REPLACE FUNCTION revenue_between(p_from DATE, p_to DATE)
RETURNS TABLE (
    month        DATE,
    orders       BIGINT,
    revenue      DECIMAL(14,2),
    avg_order    DECIMAL(14,2)
)
LANGUAGE sql
STABLE
AS $$
    SELECT DATE_TRUNC('month', order_date)::DATE,
           COUNT(*),
           ROUND(SUM(total_amount), 2),
           ROUND(AVG(total_amount), 2)
    FROM orders
    WHERE status = 'COMPLETED'
      AND order_date BETWEEN p_from AND p_to
    GROUP BY 1
    ORDER BY 1;
$$;

-- SELECT * FROM revenue_between(DATE '2026-01-01', DATE '2026-08-31');


-- ============================================================
-- 4. MATERIALISED VIEW
--
-- v_monthly_revenue recomputes from scratch on every hit. Once the
-- order table is large and the dashboard is refreshed by dozens of
-- users, it is cheaper to store the answer and rebuild it nightly.
--
-- The UNIQUE index is what makes REFRESH ... CONCURRENTLY legal,
-- and CONCURRENTLY is what stops the dashboard from blocking for
-- the duration of the rebuild.
-- ============================================================

DROP MATERIALIZED VIEW IF EXISTS mv_monthly_revenue;

CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT DATE_TRUNC('month', o.order_date)::DATE  AS order_month,
       COUNT(*)                                 AS orders,
       COUNT(DISTINCT o.customer_id)            AS customers,
       ROUND(SUM(o.total_amount), 2)            AS revenue,
       ROUND(AVG(o.total_amount), 2)            AS avg_order_value
FROM orders o
WHERE o.status = 'COMPLETED'
GROUP BY 1
WITH DATA;

CREATE UNIQUE INDEX idx_mv_monthly_revenue_month
    ON mv_monthly_revenue(order_month);

-- Nightly:  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_revenue;


-- ============================================================
-- 5. PARTITIONING THE ORDER TABLE
--
-- Almost every query in this project filters orders by date. Range
-- partitioning by year lets the planner prune whole partitions
-- instead of scanning history it will never return.
--
-- This is written as a migration because a table cannot be
-- converted to a partitioned table in place.
-- ============================================================

-- CREATE TABLE orders_partitioned (
--     order_id      INTEGER       NOT NULL,
--     customer_id   INTEGER       NOT NULL REFERENCES customers(customer_id),
--     order_date    DATE          NOT NULL,
--     status        VARCHAR(20)   NOT NULL,
--     channel       VARCHAR(20)   NOT NULL,
--     total_amount  DECIMAL(12,2) NOT NULL,
--     -- the partition key has to be part of the primary key
--     PRIMARY KEY (order_id, order_date)
-- ) PARTITION BY RANGE (order_date);
--
-- CREATE TABLE orders_2024 PARTITION OF orders_partitioned
--     FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
-- CREATE TABLE orders_2025 PARTITION OF orders_partitioned
--     FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
-- CREATE TABLE orders_2026 PARTITION OF orders_partitioned
--     FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
-- CREATE TABLE orders_default PARTITION OF orders_partitioned DEFAULT;
--
-- INSERT INTO orders_partitioned SELECT * FROM orders;
--
-- Verify pruning with:
--   EXPLAIN SELECT SUM(total_amount) FROM orders_partitioned
--   WHERE order_date >= DATE '2026-01-01';
-- Only orders_2026 should appear in the plan.


-- ============================================================
-- 6. SLOWLY CHANGING DIMENSION (TYPE 2) FOR PRODUCT PRICES
--
-- products holds only the current price, so a report re-run next
-- year would re-price last year's orders. order_items.unit_price
-- protects the transactional record, but a proper warehouse keeps
-- the full price history as a Type 2 dimension.
-- ============================================================

CREATE TABLE IF NOT EXISTS dim_product_scd2 (
    product_sk    BIGSERIAL PRIMARY KEY,   -- surrogate key
    product_id    INTEGER       NOT NULL,  -- natural / business key
    product_name  VARCHAR(150)  NOT NULL,
    category      VARCHAR(60)   NOT NULL,
    price         DECIMAL(12,2) NOT NULL,
    cost_price    DECIMAL(12,2) NOT NULL,
    valid_from    DATE          NOT NULL,
    valid_to      DATE          NOT NULL DEFAULT DATE '9999-12-31',
    is_current    BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_scd2_current
    ON dim_product_scd2(product_id) WHERE is_current;


CREATE OR REPLACE PROCEDURE scd2_apply_price_change(
    p_product_id INTEGER,
    p_new_price  DECIMAL(12,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- close the current row off ...
    UPDATE dim_product_scd2
    SET valid_to   = CURRENT_DATE - 1,
        is_current = FALSE
    WHERE product_id = p_product_id
      AND is_current;

    -- ... then open a new version
    INSERT INTO dim_product_scd2
           (product_id, product_name, category, price, cost_price, valid_from)
    SELECT p.product_id, p.product_name, p.category, p_new_price, p.cost_price, CURRENT_DATE
    FROM products p
    WHERE p.product_id = p_product_id;

    UPDATE products SET price = p_new_price WHERE product_id = p_product_id;
END;
$$;

-- Seed the dimension from the current catalogue:
-- INSERT INTO dim_product_scd2
--        (product_id, product_name, category, price, cost_price, valid_from)
-- SELECT product_id, product_name, category, price, cost_price, DATE '2024-01-01'
-- FROM products;
