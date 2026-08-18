/* ============================================================================
   Micro-partitions: why Snowflake has no indexes
   ----------------------------------------------------------------------------
   Snowflake has no CREATE INDEX. Instead, every table is split into immutable
   micro-partitions (50-500 MB uncompressed, ~16 MB compressed), and each one
   stores the MIN/MAX of every column. A filtered query reads that metadata and
   skips - "prunes" - the partitions that can't hold a match. Pruning replaces
   indexing.

   The catch: pruning only works if the values you filter on are physically
   co-located in the same partitions. Data is naturally partitioned by LOAD
   ORDER. Load in date order and a date filter prunes beautifully; load in
   random order and every partition's date range spans the whole year, so
   nothing can be pruned. This script shows exactly that, same data both ways.

   Needs a Snowflake account. Run it with run.sh (Snowflake CLI), which captures
   the results into output/output.txt automatically, or paste it into a
   worksheet. An XSMALL warehouse and a free trial are enough.
   ============================================================================ */

-- ---------------------------------------------------------------------------
-- 0. Context. An XSMALL warehouse is plenty; it auto-suspends after 60s idle.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS mp_demo_wh
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE mp_demo_wh;
CREATE DATABASE IF NOT EXISTS mp_demo;
CREATE SCHEMA  IF NOT EXISTS mp_demo.demo;
USE SCHEMA mp_demo.demo;

-- ---------------------------------------------------------------------------
-- 1. Build the data ONCE. 20M rows across 365 days of 2024, with a padding
--    column so the table spans many micro-partitions.
--
--    DETERMINISTIC ON PURPOSE. Snowflake's RANDOM() is NOT reproducible across
--    runs - not even with a seed - because worker-thread count and row order can
--    differ (per the RANDOM docs). So we derive every column from HASH() of a
--    stable row number instead: same input, same rows, every run. HASH scatters
--    the dates across the rows, so this table is naturally UNCLUSTERED on
--    event_date (worst case), while the data itself is reproducible.
--    (Bump ROWCOUNT up for a more dramatic contrast; 20M runs in a minute or two
--    on XSMALL. Note: Snowflake still chooses micro-partition boundaries at load
--    time, so the total count and the clustered scan can still shift by one
--    between runs - the ratio, all partitions vs ~one, is the stable point.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE events_unclustered AS
WITH base AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ8()) AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 20000000))
)
SELECT
    DATEADD(day, MOD(ABS(HASH(n)), 365), DATE '2024-01-01')        AS event_date,
    MOD(ABS(HASH(n, 101)), 1000000) + 1                            AS user_id,
    (MOD(ABS(HASH(n, 202)), 100000) / 100.0)::NUMBER(10,2)          AS amount,
    SHA1_HEX(TO_VARCHAR(n))      || SHA1_HEX(TO_VARCHAR(n * 3 + 1)) ||
    SHA1_HEX(TO_VARCHAR(n * 7 + 2)) || SHA1_HEX(TO_VARCHAR(n * 11 + 3)) ||
    SHA1_HEX(TO_VARCHAR(n * 13 + 5))                               AS payload
FROM base;

-- Same rows, but physically sorted by event_date on load -> each micro-partition
-- holds a narrow date range. This is what a clustering key achieves at scale.
CREATE OR REPLACE TABLE events_clustered AS
SELECT * FROM events_unclustered ORDER BY event_date;

-- ---------------------------------------------------------------------------
-- 2. How well is each table clustered on event_date?
--    average_depth: how many partitions overlap on a given value. Lower = better
--    (1.0 is perfect). total_partition_count: how many micro-partitions exist.
-- ---------------------------------------------------------------------------
SELECT 'events_unclustered' AS table_name,
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION('events_unclustered','(event_date)')):average_depth::float        AS average_depth,
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION('events_unclustered','(event_date)')):total_partition_count::int   AS total_partitions
UNION ALL
SELECT 'events_clustered',
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION('events_clustered','(event_date)')):average_depth::float,
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION('events_clustered','(event_date)')):total_partition_count::int;

-- ---------------------------------------------------------------------------
-- 3. Run the SAME one-day query on each table, capturing each query's id.
--    Filter on the column AS STORED (event_date is DATE -> compare to a DATE
--    literal). The third query wraps the column in a function on purpose.
-- ---------------------------------------------------------------------------
SELECT COUNT(*) FROM events_unclustered WHERE event_date = DATE '2024-06-15';
SET uncl_qid  = LAST_QUERY_ID();

SELECT COUNT(*) FROM events_clustered   WHERE event_date = DATE '2024-06-15';
SET clust_qid = LAST_QUERY_ID();

SELECT COUNT(*) FROM events_clustered   WHERE TO_VARCHAR(event_date) = '2024-06-15';
SET anti_qid  = LAST_QUERY_ID();

-- ---------------------------------------------------------------------------
-- 4. The result that matters: partitions scanned vs total for each scenario, plus
--    the percentage scanned. Read straight off the TableScan operator - what
--    actually happened, not an estimate.
--
--    Note on determinism: the raw COUNTS wobble run to run (128 vs 126, 1 vs 2)
--    because Snowflake packs micro-partitions in PARALLEL at load time - the
--    boundaries are execution-dependent, not data-dependent, so no SQL fixes it.
--    The PCT_SCANNED ratio is the stable, reproducible result: ~100% when pruning
--    fails, ~1% when it works. That ratio is the whole lesson.
-- ---------------------------------------------------------------------------
WITH pruning AS (
    SELECT 'unclustered   (event_date = DATE)'                AS scenario,
           operator_statistics:pruning:partitions_scanned::int AS partitions_scanned,
           operator_statistics:pruning:partitions_total::int   AS partitions_total
    FROM TABLE(GET_QUERY_OPERATOR_STATS($uncl_qid))  WHERE operator_type = 'TableScan'
    UNION ALL
    SELECT 'clustered     (event_date = DATE)',
           operator_statistics:pruning:partitions_scanned::int,
           operator_statistics:pruning:partitions_total::int
    FROM TABLE(GET_QUERY_OPERATOR_STATS($clust_qid)) WHERE operator_type = 'TableScan'
    UNION ALL
    SELECT 'clustered but TO_VARCHAR() wraps the column (defeats pruning)',
           operator_statistics:pruning:partitions_scanned::int,
           operator_statistics:pruning:partitions_total::int
    FROM TABLE(GET_QUERY_OPERATOR_STATS($anti_qid))  WHERE operator_type = 'TableScan'
)
SELECT scenario, partitions_scanned, partitions_total,
       ROUND(100 * partitions_scanned / NULLIF(partitions_total, 0), 1) AS pct_scanned
FROM pruning;

-- ---------------------------------------------------------------------------
-- 5. Clean up (optional).
-- ---------------------------------------------------------------------------
-- DROP DATABASE IF EXISTS mp_demo;
-- DROP WAREHOUSE IF EXISTS mp_demo_wh;
