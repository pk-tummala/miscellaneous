-- seed.sql
-- Target dimension + today's staging delta from upstream.
-- Deliberately small so you can verify every row by eye.

DROP TABLE IF EXISTS customer_dim;
DROP TABLE IF EXISTS customer_stg;
DROP TABLE IF EXISTS customer_stg_dupes;

CREATE TABLE customer_dim (
    customer_id INTEGER PRIMARY KEY,
    full_name   VARCHAR,
    balance     DECIMAL(12,2),
    updated_at  DATE
);

INSERT INTO customer_dim VALUES
    (1, 'Alice Chen',   1200.00, DATE '2026-07-17'),
    (2, 'Bob Nguyen',    850.50, DATE '2026-07-17'),
    (3, 'Carol Smith',  2400.00, DATE '2026-07-17');

-- Today's delta: one changed, one unchanged, one brand new.
CREATE TABLE customer_stg (
    customer_id INTEGER,
    full_name   VARCHAR,
    balance     DECIMAL(12,2),
    updated_at  DATE
);

INSERT INTO customer_stg VALUES
    (2, 'Bob Nguyen',    900.75, DATE '2026-07-18'),   -- balance changed
    (3, 'Carol Smith',  2400.00, DATE '2026-07-17'),   -- unchanged
    (4, 'Dan Okafor',    500.00, DATE '2026-07-18');   -- new customer

-- The trap: the SAME key twice in the source, with different values.
-- This is what a missing dedup step upstream actually looks like.
CREATE TABLE customer_stg_dupes (
    customer_id INTEGER,
    full_name   VARCHAR,
    balance     DECIMAL(12,2),
    updated_at  DATE
);

INSERT INTO customer_stg_dupes VALUES
    (2, 'Bob Nguyen',    900.75, DATE '2026-07-18'),
    (2, 'Bob Nguyen',    999.99, DATE '2026-07-18');   -- same key, different amount
