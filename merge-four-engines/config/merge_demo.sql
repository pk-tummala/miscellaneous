-- merge_demo.sql
-- The upsert itself. This is ANSI-standard MERGE and runs as-is on DuckDB.
-- The Oracle / Teradata / Snowflake / Delta variants are in README.md.
--
-- Why this is idempotent: the target is matched on a key, and every source
-- row carries the full new state. Run it once or run it five times against
-- the same source - the target lands in the same place.
--
-- The condition that idempotency rests on: ONE ROW PER KEY IN THE SOURCE.
-- Break that and the engines stop agreeing with each other (see README).

MERGE INTO customer_dim AS t
USING customer_stg AS s
   ON t.customer_id = s.customer_id
WHEN MATCHED THEN
    UPDATE SET full_name  = s.full_name,
               balance    = s.balance,
               updated_at = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (customer_id, full_name, balance, updated_at)
    VALUES (s.customer_id, s.full_name, s.balance, s.updated_at);
