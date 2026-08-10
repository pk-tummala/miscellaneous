-- seed.sql — a CDC-style feed with multiple updates per customer.
-- Customer 2 is the trap: its two NEWEST rows share the exact same updated_at,
-- with an older row beneath them (so RANK's gap vs DENSE_RANK's no-gap is visible).
DROP TABLE IF EXISTS customer_updates;
CREATE TABLE customer_updates (
  customer_id INTEGER,
  updated_at  TIMESTAMP,
  version     INTEGER,      -- a unique, monotonic per-customer tie-breaker
  status      VARCHAR
);
INSERT INTO customer_updates VALUES
  (1, TIMESTAMP '2024-01-01 10:00', 1, 'new'),
  (1, TIMESTAMP '2024-01-02 10:00', 2, 'active'),
  (1, TIMESTAMP '2024-01-03 10:00', 3, 'churned'),
  (2, TIMESTAMP '2024-01-20 08:00', 1, 'new'),
  (2, TIMESTAMP '2024-02-01 09:00', 2, 'active'),
  (2, TIMESTAMP '2024-02-01 09:00', 3, 'suspended');   -- same updated_at as the row above
