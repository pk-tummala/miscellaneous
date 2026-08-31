-- 02_demo.sql
-- Break the pipeline, then watch it heal itself.

-- Same context as 01 (each `snow sql -f` runs in its own session).
USE WAREHOUSE demo_wh;
USE SCHEMA    streams_tasks_demo.demo;

-- 1. Simulate an outage: the CDC task gets suspended.
ALTER TASK orders_cdc_task SUSPEND;

-- 2. A change arrives while CDC is down.
INSERT INTO orders (order_id, customer, amount) VALUES (1, 'ACME', 100.00);

-- 3. BEFORE healing: CDC is suspended, a change is waiting.
SHOW TASKS LIKE 'orders_cdc_task';
SELECT "name", "state" AS state_before FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SELECT SYSTEM$STREAM_HAS_DATA('orders_stream') AS stream_has_pending;

-- 4. The watchdog heals it - heal_pipeline() RESUMEs the CDC task. Run it now instead of waiting for the hourly schedule:
CALL heal_pipeline();

-- 5. CDC is back - let it process the pending change (async; give it a moment):
EXECUTE TASK orders_cdc_task;
CALL SYSTEM$WAIT(20);

-- 6. AFTER healing: CDC started, change landed, stream fresh again.
SHOW TASKS LIKE 'orders_cdc_task';
SELECT "name", "state" AS state_after FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SELECT * FROM orders_target;
SHOW STREAMS LIKE 'orders_stream';
SELECT "name", "stale", "stale_after" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
