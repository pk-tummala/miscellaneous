-- =====================================================================
--  Metadata-driven warehouse extract — control schema
--  Six tables. See Section 7 of the white paper.
--
--  Dialect: PostgreSQL. Types will need adjusting for other engines.
--  This schema holds NO warehouse data — only configuration and history.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS extract_meta;
SET search_path TO extract_meta;

-- ---------------------------------------------------------------------
-- 1. MD_TABLE_CONFIG — what to extract, and how.
--    The ONLY table maintained by people. Adding a table to the process
--    means inserting one row here. No code change, no release.
-- ---------------------------------------------------------------------
CREATE TABLE md_table_config (
    table_id            SERIAL       PRIMARY KEY,
    source_schema       VARCHAR(128) NOT NULL,
    source_table        VARCHAR(128) NOT NULL,

    -- nothing is extracted unless in_scope_flag is TRUE; enabled_flag is
    -- the operational switch used to park a problem table temporarily
    in_scope_flag       BOOLEAN      NOT NULL DEFAULT FALSE,
    enabled_flag        BOOLEAN      NOT NULL DEFAULT TRUE,

    load_type           VARCHAR(20)  NOT NULL DEFAULT 'INCREMENTAL',
                                     -- INCREMENTAL | FULL_REFRESH

    -- the single most important setting in the framework.
    -- Must satisfy the three properties in Section 10.3.1.
    change_date_column  VARCHAR(128),

    -- large tables only; empty for the great majority (Section 9.6)
    chunk_column        VARCHAR(128),
    chunk_size          VARCHAR(30),          -- e.g. '1 month' or '10000000'

    priority            INT          NOT NULL DEFAULT 100,  -- lower runs first
    target_prefix       VARCHAR(512),
    max_file_size_mb    INT          NOT NULL DEFAULT 512,
    run_frequency       VARCHAR(20)  NOT NULL DEFAULT 'DAILY',

    table_owner         VARCHAR(128),         -- who approved it into scope
    updated_by          VARCHAR(64),
    updated_datetime    TIMESTAMP    NOT NULL DEFAULT now(),

    CONSTRAINT uq_table_config UNIQUE (source_schema, source_table),
    CONSTRAINT ck_load_type CHECK (load_type IN ('INCREMENTAL','FULL_REFRESH')),
    -- An in-scope incremental table cannot work without a change-date
    -- column. Deliberately NOT enforced for out-of-scope rows: a newly
    -- discovered table has not been profiled yet, and that is exactly
    -- what in_scope_flag = FALSE means.
    CONSTRAINT ck_incremental_needs_column
        CHECK (in_scope_flag = FALSE
               OR load_type <> 'INCREMENTAL'
               OR change_date_column IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 2. MD_EXTRACT_STATE — how far each table has got. Program-written.
-- ---------------------------------------------------------------------
CREATE TABLE md_extract_state (
    table_id                 INT PRIMARY KEY
                             REFERENCES md_table_config (table_id),
    phase                    VARCHAR(20) NOT NULL DEFAULT 'PENDING',
                             -- PENDING | BASELINE | INCREMENTAL | HELD

    -- the marker: L for the next run. Only ever advanced after the
    -- files for a window are confirmed complete (Section 12).
    last_extracted_datetime  TIMESTAMP,
    baseline_boundary        TIMESTAMP,   -- the H the baseline was cut at

    -- refreshed from the source catalogue; used for run ordering (13.4)
    est_size_mb              BIGINT,
    est_row_count            BIGINT,
    last_duration_seconds    INT,

    -- schema drift detection (Section 16.1)
    column_list              TEXT,
    column_list_hash         VARCHAR(64),

    last_success_run_id      INT,
    last_success_datetime    TIMESTAMP,
    consecutive_failures     INT NOT NULL DEFAULT 0,

    -- optimistic lock: stops two runs colliding on one table
    locked_by_run_id         INT,
    lock_acquired_datetime   TIMESTAMP,

    CONSTRAINT ck_phase CHECK (phase IN ('PENDING','BASELINE','INCREMENTAL','HELD'))
);

-- ---------------------------------------------------------------------
-- 3. MD_BATCH_RUN — one row per scheduled run.
-- ---------------------------------------------------------------------
CREATE TABLE md_batch_run (
    batch_run_id     SERIAL PRIMARY KEY,
    run_type         VARCHAR(20),      -- BASELINE | INCREMENTAL | CATCHUP
    environment      VARCHAR(10),
    start_datetime   TIMESTAMP NOT NULL DEFAULT now(),
    end_datetime     TIMESTAMP,
    status           VARCHAR(20) NOT NULL DEFAULT 'RUNNING',
                     -- RUNNING | COMPLETE | PARTIAL | FAILED | STOPPED
    tables_succeeded INT DEFAULT 0,
    tables_failed    INT DEFAULT 0,
    tables_skipped   INT DEFAULT 0,
    triggered_by     VARCHAR(64)
);

-- ---------------------------------------------------------------------
-- 4. MD_TASK_RUN — one row per table (or chunk) per run.
-- ---------------------------------------------------------------------
CREATE TABLE md_task_run (
    task_run_id      SERIAL PRIMARY KEY,
    batch_run_id     INT NOT NULL REFERENCES md_batch_run (batch_run_id),
    table_id         INT NOT NULL REFERENCES md_table_config (table_id),
    chunk_no         INT,                    -- NULL when not chunked
    attempt_no       INT NOT NULL DEFAULT 1,

    window_from      TIMESTAMP,              -- L
    window_to        TIMESTAMP,              -- H  (same H for every chunk)

    status           VARCHAR(20) NOT NULL DEFAULT 'RUNNING',
                     -- RUNNING | PUBLISHED | FAILED | SKIPPED | HELD
    rows_extracted   BIGINT,
    source_row_count BIGINT,                 -- for the count check
    file_count       INT,
    bytes_written    BIGINT,
    target_prefix    VARCHAR(1024),

    start_datetime   TIMESTAMP NOT NULL DEFAULT now(),
    end_datetime     TIMESTAMP,
    duration_seconds INT,
    error_message    TEXT
);

CREATE INDEX ix_task_run_batch ON md_task_run (batch_run_id);
CREATE INDEX ix_task_run_table ON md_task_run (table_id, start_datetime DESC);

-- ---------------------------------------------------------------------
-- 5. MD_FILE_LOG — one row per file written.
--    This is the table the downstream team reads (through a view).
--    published_datetime is BOTH the published flag and the value they
--    watermark against. NULL means the file is not yet available.
-- ---------------------------------------------------------------------
CREATE TABLE md_file_log (
    file_id            SERIAL PRIMARY KEY,
    task_run_id        INT NOT NULL REFERENCES md_task_run (task_run_id),
    table_id           INT NOT NULL REFERENCES md_table_config (table_id),
    file_path          VARCHAR(1024) NOT NULL,
    row_count          BIGINT,
    byte_size          BIGINT,
    published_datetime TIMESTAMP
);

-- the downstream query is "everything published since I last ran",
-- so this index is the one that matters
CREATE INDEX ix_file_log_published ON md_file_log (published_datetime)
    WHERE published_datetime IS NOT NULL;
CREATE INDEX ix_file_log_table ON md_file_log (table_id, published_datetime);

-- ---------------------------------------------------------------------
-- 6. MD_EVENT_LOG — every step of every table in every run.
--    This is what answers "where exactly did it stop?" without
--    anyone reading a log file.
-- ---------------------------------------------------------------------
CREATE TABLE md_event_log (
    event_id       BIGSERIAL PRIMARY KEY,
    batch_run_id   INT,
    task_run_id    INT,
    table_id       INT,
    step_name      VARCHAR(40),   -- SELECT|CHECK|BOUNDS|EXTRACT|VERIFY|PUBLISH|MARKER
    event_type     VARCHAR(20),   -- START | END | ERROR | WARNING | RETRY
    message        TEXT,
    event_datetime TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX ix_event_log_task ON md_event_log (task_run_id, event_datetime);
CREATE INDEX ix_event_log_time ON md_event_log (event_datetime);
