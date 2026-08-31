-- 01_pipeline.sql
-- A SELF-HEALING CDC pipeline in Snowflake: a Stream + a Task, plus a watchdog that keeps the
-- consumer alive - so the stream can never drift to stale.

-- 0. Self-contained context so nothing depends on your connection's defaults (all idempotent):
-- a small auto-suspend warehouse, a dedicated database and schema.
CREATE WAREHOUSE IF NOT EXISTS demo_wh
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
CREATE DATABASE  IF NOT EXISTS streams_tasks_demo;
CREATE SCHEMA    IF NOT EXISTS streams_tasks_demo.demo;
USE WAREHOUSE demo_wh;
USE SCHEMA    streams_tasks_demo.demo;

-- Source (retention = your safety margin), target, and the stream (a bookmark into Time Travel).
CREATE OR REPLACE TABLE orders (
  order_id   INT,
  customer   STRING,
  amount     NUMBER(12,2),
  updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
  DATA_RETENTION_TIME_IN_DAYS     = 1     -- Standard-edition max; plenty with an hourly watchdog (raise on Enterprise+ for a wider window)
  MAX_DATA_EXTENSION_TIME_IN_DAYS = 7;    -- not edition-capped: an UNCONSUMED stream still survives a week (storage cost only then)

CREATE OR REPLACE TABLE orders_target (
  order_id   INT,
  customer   STRING,
  amount     NUMBER(12,2),
  updated_at TIMESTAMP_NTZ
);

CREATE OR REPLACE STREAM orders_stream ON TABLE orders;

-- The CDC task: MERGE the stream into the target. WHEN keeps an empty stream fresh while running.
CREATE OR REPLACE TASK orders_cdc_task
  SCHEDULE = '1 MINUTE'
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'   -- serverless; no warehouse to name
  WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
AS
  MERGE INTO orders_target t
  USING ( SELECT order_id, customer, amount, updated_at, METADATA$ACTION AS action
          FROM orders_stream
          WHERE NOT (METADATA$ACTION='DELETE' AND METADATA$ISUPDATE='TRUE') ) s
     ON t.order_id = s.order_id
  WHEN MATCHED AND s.action='DELETE'     THEN DELETE
  WHEN MATCHED AND s.action='INSERT'     THEN UPDATE SET t.customer=s.customer, t.amount=s.amount, t.updated_at=s.updated_at
  WHEN NOT MATCHED AND s.action='INSERT' THEN INSERT (order_id,customer,amount,updated_at)
                                              VALUES (s.order_id,s.customer,s.amount,s.updated_at);

-- The self-healer: bring the CDC task back if it ever stops. Harmless if it is already running.
CREATE OR REPLACE PROCEDURE heal_pipeline()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  ALTER TASK orders_cdc_task RESUME;
  RETURN 'cdc_task ensured running';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'cdc_task already running';
END;
$$;

-- The watchdog task: on a schedule it runs heal_pipeline(), which RESUMEs orders_cdc_task if it has
-- stopped - keeping the stream consumed so it can't go stale. Hourly is plenty: it resumes the CDC
-- task within an hour of any stop, far inside the 1-day retention, and an hourly serverless run costs
-- almost nothing. (A 5-minute schedule would be ~12x the compute for zero extra safety.)
CREATE OR REPLACE TASK cdc_watchdog_task
  SCHEDULE = '60 MINUTE'
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
AS
  CALL heal_pipeline();

-- Tasks are created SUSPENDED - resume both.
ALTER TASK orders_cdc_task RESUME;
ALTER TASK cdc_watchdog_task  RESUME;
