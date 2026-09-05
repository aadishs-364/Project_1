-- ============================================================
-- Sales & Order Management Analytics System
-- File   : 01_schema.sql
-- Purpose: Database definition (DDL) - tables, keys, constraints
-- Target : PostgreSQL 13+ (also runs on DuckDB, used here for testing)
-- ============================================================

-- Drop in reverse dependency order so foreign keys never block us.
DROP VIEW  IF EXISTS v_payment_reconciliation;
DROP VIEW  IF EXISTS v_customer_value;
DROP VIEW  IF EXISTS v_product_performance;
DROP VIEW  IF EXISTS v_monthly_revenue;
DROP VIEW  IF EXISTS v_order_summary;
DROP VIEW  IF EXISTS v_order_lines;

DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;


-- ------------------------------------------------------------
-- customers
-- One row per registered buyer. Email is the natural key, so it
-- carries a UNIQUE constraint even though customer_id is the PK.
-- ------------------------------------------------------------
CREATE TABLE customers (
    customer_id   INTEGER      PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    phone         VARCHAR(20),
    city          VARCHAR(80)  NOT NULL,
    state         VARCHAR(80)  NOT NULL,
    signup_date   DATE         NOT NULL,
    CONSTRAINT chk_customers_email      CHECK (email LIKE '%@%.%'),
    CONSTRAINT chk_customers_signup_min CHECK (signup_date >= DATE '2020-01-01')
);


-- ------------------------------------------------------------
-- products
-- cost_price is kept alongside price so margin can be analysed
-- without a separate costing table.
-- ------------------------------------------------------------
CREATE TABLE products (
    product_id    INTEGER       PRIMARY KEY,
    product_name  VARCHAR(150)  NOT NULL,
    category      VARCHAR(60)   NOT NULL,
    price         DECIMAL(12,2) NOT NULL,
    cost_price    DECIMAL(12,2) NOT NULL,
    stock         INTEGER       NOT NULL DEFAULT 0,
    is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_products_price     CHECK (price > 0),
    CONSTRAINT chk_products_cost      CHECK (cost_price >= 0),
    CONSTRAINT chk_products_margin    CHECK (cost_price <= price),
    CONSTRAINT chk_products_stock     CHECK (stock >= 0)
);


-- ------------------------------------------------------------
-- orders
-- total_amount is denormalised on purpose: it is the amount the
-- customer was actually charged and must survive later price
-- changes on the product catalogue. 05_* validates it against
-- the order_items lines.
-- ------------------------------------------------------------
CREATE TABLE orders (
    order_id      INTEGER       PRIMARY KEY,
    customer_id   INTEGER       NOT NULL,
    order_date    DATE          NOT NULL,
    status        VARCHAR(20)   NOT NULL,
    channel       VARCHAR(20)   NOT NULL,
    total_amount  DECIMAL(12,2) NOT NULL,
    CONSTRAINT fk_orders_customer  FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT chk_orders_status   CHECK (status  IN ('PLACED','SHIPPED','COMPLETED','CANCELLED','RETURNED')),
    CONSTRAINT chk_orders_channel  CHECK (channel IN ('WEB','MOBILE_APP','STORE','MARKETPLACE')),
    CONSTRAINT chk_orders_amount   CHECK (total_amount >= 0)
);


-- ------------------------------------------------------------
-- order_items
-- unit_price is a snapshot of products.price at the time of sale.
-- (order_id, product_id) is unique: a product appears at most once
-- per order, quantity carries the rest.
-- ------------------------------------------------------------
CREATE TABLE order_items (
    order_item_id INTEGER       PRIMARY KEY,
    order_id      INTEGER       NOT NULL,
    product_id    INTEGER       NOT NULL,
    quantity      INTEGER       NOT NULL,
    unit_price    DECIMAL(12,2) NOT NULL,
    discount_pct  DECIMAL(5,4)  NOT NULL DEFAULT 0,
    CONSTRAINT fk_items_order      FOREIGN KEY (order_id)   REFERENCES orders(order_id),
    CONSTRAINT fk_items_product    FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT uq_items_order_prod UNIQUE (order_id, product_id),
    CONSTRAINT chk_items_qty       CHECK (quantity > 0),
    CONSTRAINT chk_items_price     CHECK (unit_price >= 0),
    CONSTRAINT chk_items_discount  CHECK (discount_pct >= 0 AND discount_pct < 1)
);


-- ------------------------------------------------------------
-- payments
-- An order can have more than one payment row (retry after a
-- failure, or a later refund), so order_id is deliberately not
-- unique here.
-- ------------------------------------------------------------
CREATE TABLE payments (
    payment_id     INTEGER       PRIMARY KEY,
    order_id       INTEGER       NOT NULL,
    payment_date   DATE          NOT NULL,
    amount         DECIMAL(12,2) NOT NULL,
    method         VARCHAR(30)   NOT NULL,
    payment_status VARCHAR(20)   NOT NULL,
    CONSTRAINT fk_payments_order   FOREIGN KEY (order_id) REFERENCES orders(order_id),
    CONSTRAINT chk_payments_status CHECK (payment_status IN ('PAID','PENDING','FAILED','REFUNDED')),
    CONSTRAINT chk_payments_method CHECK (method IN ('UPI','CREDIT_CARD','DEBIT_CARD','NET_BANKING','WALLET','COD')),
    CONSTRAINT chk_payments_amount CHECK (amount >= 0)
);
