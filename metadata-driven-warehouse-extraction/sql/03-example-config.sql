-- =====================================================================
--  Worked configuration examples — the six table archetypes.
--  See Sections 8 and 22.2 of the white paper.
--
--  This is the whole onboarding process: one INSERT per table.
-- =====================================================================

SET search_path TO extract_meta;

-- 1. Small reference table — full refresh every run.
--    Safer than inventing change detection, and catches deletes free.
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, load_type,
   change_date_column, priority, target_prefix, table_owner)
VALUES
  ('sales', 'dim_country', TRUE, 'FULL_REFRESH',
   NULL, 10, 'prod/sales/dim_country', 'reference-data-team');

-- 2. Medium dimension with frequent updates — ordinary incremental.
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, load_type,
   change_date_column, priority, target_prefix, table_owner)
VALUES
  ('sales', 'dim_customer', TRUE, 'INCREMENTAL',
   'last_updated_ts', 20, 'prod/sales/dim_customer', 'crm-team');

-- 3. Very large fact — chunked baseline, then plain incremental.
--    chunk_column is a DIFFERENT column from change_date_column:
--    the chunk predicate slices the table, the change-date predicate
--    bounds the window. Every chunk shares one H. (Section 9.6)
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, load_type,
   change_date_column, chunk_column, chunk_size,
   priority, target_prefix, max_file_size_mb, run_frequency, table_owner)
VALUES
  ('sales', 'fct_orders', TRUE, 'INCREMENTAL',
   'last_updated_ts', 'order_date', '1 month',
   5, 'prod/sales/fct_orders', 512, 'HOURLY', 'sales-analytics');

-- 4. Table whose change-date is a load id rather than a timestamp.
--    Where one exists it is usually the better choice: a monotonic
--    load id sidesteps all three properties in Section 10.3.1.
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, load_type,
   change_date_column, priority, target_prefix, table_owner)
VALUES
  ('finance', 'fct_ledger', TRUE, 'INCREMENTAL',
   'etl_load_id', 15, 'prod/finance/fct_ledger', 'finance-systems');

-- 5. Discovered but NOT yet approved into scope.
--    in_scope_flag = FALSE means the framework ignores it entirely.
--    Nothing is extracted until someone puts their name against it.
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, load_type,
   change_date_column, target_prefix)
VALUES
  ('staging', 'tmp_order_rebuild', FALSE, 'INCREMENTAL',
   NULL, NULL);

-- 6. A table temporarily parked after repeated failures.
--    enabled_flag = FALSE keeps the config but stops it running, so one
--    bad table cannot keep the nightly run permanently red.
INSERT INTO md_table_config
  (source_schema, source_table, in_scope_flag, enabled_flag, load_type,
   change_date_column, priority, target_prefix, table_owner)
VALUES
  ('web', 'fct_clickstream', TRUE, FALSE, 'INCREMENTAL',
   'event_ts', 90, 'prod/web/fct_clickstream', 'digital-team');

-- Every in-scope table needs a state row. The program creates these,
-- but seeding them explicitly makes the first run's intent obvious.
INSERT INTO md_extract_state (table_id, phase)
SELECT table_id, 'PENDING' FROM md_table_config
WHERE  in_scope_flag = TRUE
  AND  table_id NOT IN (SELECT table_id FROM md_extract_state);
