-- =====================================================================
--  Day-to-day operational queries.
--  Everything an operator or project manager needs to ask, in SQL.
-- =====================================================================

SET search_path TO extract_meta;

-- ---------------------------------------------------------------------
-- A. PROFILING: does the change-date column advance between commits?
--    Property 3 in Section 10.3.1. This CANNOT be answered by asking —
--    it has to be measured. Run against the source warehouse.
--
--    A handful of distinct values clustered at the load's start time
--    means the timestamp is frozen in a variable and reused across
--    commits: rows can then be missed permanently.
--    Values spread across the load's duration means it advances properly.
-- ---------------------------------------------------------------------
/*  Run this on the SOURCE warehouse, not the metadata database:

    SELECT COUNT(*)                        AS rows_in_window,
           COUNT(DISTINCT last_updated_ts) AS distinct_timestamps,
           MIN(last_updated_ts)            AS earliest,
           MAX(last_updated_ts)            AS latest
    FROM   sales.fct_orders
    WHERE  last_updated_ts >= '<start of yesterday''s load>';

    distinct_timestamps = 1 (or a very few)  -> FROZEN. Investigate.
    distinct_timestamps spread over the load -> healthy.
*/

-- ---------------------------------------------------------------------
-- B. Baseline progress: how much of the estate is done?
--    The report someone will ask for every morning.
-- ---------------------------------------------------------------------
SELECT s.phase,
       COUNT(*)                                   AS tables,
       ROUND(SUM(s.est_size_mb) / 1024.0, 1)      AS gb_estimated,
       ROUND(100.0 * COUNT(*) /
             SUM(COUNT(*)) OVER (), 1)            AS pct_of_tables
FROM   md_extract_state s
JOIN   md_table_config  c ON c.table_id = s.table_id
WHERE  c.in_scope_flag = TRUE
GROUP  BY s.phase
ORDER  BY tables DESC;

-- ---------------------------------------------------------------------
-- C. What is outstanding right now, biggest first?
-- ---------------------------------------------------------------------
SELECT c.source_schema, c.source_table, s.phase, c.priority,
       ROUND(s.est_size_mb / 1024.0, 1) AS gb_estimated,
       s.consecutive_failures
FROM   md_table_config  c
JOIN   md_extract_state s ON s.table_id = c.table_id
WHERE  c.in_scope_flag = TRUE
  AND  c.enabled_flag  = TRUE
  AND  s.phase IN ('PENDING','BASELINE')
ORDER  BY c.priority, s.est_size_mb DESC NULLS LAST;

-- ---------------------------------------------------------------------
-- D. Last night's outcome.
-- ---------------------------------------------------------------------
SELECT b.batch_run_id, b.run_type, b.status,
       b.start_datetime, b.end_datetime,
       b.tables_succeeded, b.tables_failed, b.tables_skipped
FROM   md_batch_run b
ORDER  BY b.batch_run_id DESC
LIMIT  7;

-- ---------------------------------------------------------------------
-- E. Which tables failed, and why?
-- ---------------------------------------------------------------------
SELECT c.source_schema, c.source_table, t.chunk_no, t.attempt_no,
       t.window_from, t.window_to,
       t.rows_extracted, t.source_row_count,
       t.error_message
FROM   md_task_run      t
JOIN   md_table_config  c ON c.table_id = t.table_id
WHERE  t.batch_run_id = (SELECT MAX(batch_run_id) FROM md_batch_run)
  AND  t.status = 'FAILED'
ORDER  BY c.source_schema, c.source_table;

-- ---------------------------------------------------------------------
-- F. Where exactly did a table stop? (Section 17.2)
--    The reason MD_EVENT_LOG exists — one query, no log files.
-- ---------------------------------------------------------------------
SELECT e.event_datetime, e.step_name, e.event_type, e.message
FROM   md_event_log     e
JOIN   md_table_config  c ON c.table_id = e.table_id
WHERE  c.source_schema = 'sales'
  AND  c.source_table  = 'fct_orders'
ORDER  BY e.event_datetime DESC
LIMIT  50;

-- ---------------------------------------------------------------------
-- G. Volume anomaly check (Section 16).
--    Catches the failure where everything "succeeds" but an upstream
--    load never ran, and an empty increment is published.
-- ---------------------------------------------------------------------
WITH recent AS (
    SELECT table_id, rows_extracted,
           ROW_NUMBER() OVER (PARTITION BY table_id
                              ORDER BY start_datetime DESC) AS rn
    FROM   md_task_run
    WHERE  status = 'PUBLISHED' AND chunk_no IS NULL
)
SELECT c.source_schema, c.source_table,
       MAX(CASE WHEN r.rn = 1 THEN r.rows_extracted END) AS latest_rows,
       ROUND(AVG(CASE WHEN r.rn BETWEEN 2 AND 8
                      THEN r.rows_extracted END), 0)     AS prior_7_avg
FROM   recent r
JOIN   md_table_config c ON c.table_id = r.table_id
WHERE  r.rn <= 8
GROUP  BY c.source_schema, c.source_table
HAVING MAX(CASE WHEN r.rn = 1 THEN r.rows_extracted END) <
       0.2 * NULLIF(AVG(CASE WHEN r.rn BETWEEN 2 AND 8
                             THEN r.rows_extracted END), 0)
ORDER  BY 1, 2;

-- ---------------------------------------------------------------------
-- H. Tables held for schema drift, awaiting human acknowledgement.
-- ---------------------------------------------------------------------
SELECT c.source_schema, c.source_table, s.column_list_hash,
       s.last_success_datetime
FROM   md_extract_state s
JOIN   md_table_config  c ON c.table_id = s.table_id
WHERE  s.phase = 'HELD'
ORDER  BY s.last_success_datetime;

-- ---------------------------------------------------------------------
-- I. Clear a stale lock left by a killed process.
--    Safe because publishing and marker advancement are separate steps:
--    the next run re-extracts the same window idempotently.
-- ---------------------------------------------------------------------
/*  UPDATE md_extract_state
    SET    locked_by_run_id = NULL, lock_acquired_datetime = NULL
    WHERE  locked_by_run_id IS NOT NULL
      AND  lock_acquired_datetime < now() - INTERVAL '6 hours';   */
