-- queries.sql — the latest-row-per-key dedup, the tie-break that makes it correct,
-- and how ROW_NUMBER / RANK / DENSE_RANK actually differ. Runs as-is on DuckDB.

-- @label: 1. The dedup everyone writes — latest row per customer
-- @note: ROW_NUMBER numbers each customer's rows newest-first; we keep number 1. Customer 1 resolves to 'churned', clearly the latest. Customer 2 resolves to 'active' - but it has a tie hiding in it. Look at the raw rows next.
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
  FROM customer_updates
)
SELECT customer_id, updated_at, version, status
FROM ranked WHERE rn = 1
ORDER BY customer_id;

-- @label: 2. Why customer 2 is a trap — its two newest rows share updated_at
-- @note: Both of customer 2's newest rows have updated_at 2024-02-01 09:00. The ORDER BY can't separate them, so ROW_NUMBER assigned rn = 1 to one arbitrarily - it kept 'active' (version 2), but 'suspended' (version 3) is the later update, the row you wanted. SQL does not guarantee which tied row wins: it is implementation-dependent and can flip on another engine, an index change, or a data reload.
SELECT customer_id, updated_at, version, status
FROM customer_updates
WHERE customer_id = 2
ORDER BY version;

-- @label: 3. The fix — make the tie-break explicit in ORDER BY
-- @note: Add a unique, monotonic column (version here, or a surrogate/ingest id) as a secondary sort key. Now 'latest' is fully determined - customer 2 resolves to 'suspended', reproducibly, on any engine and every run.
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC, version DESC) AS rn
  FROM customer_updates
)
SELECT customer_id, updated_at, version, status
FROM ranked WHERE rn = 1
ORDER BY customer_id;

-- @label: 4. ROW_NUMBER vs RANK vs DENSE_RANK — same ORDER BY, side by side
-- @note: With NO ties (customer 1) all three agree: 1, 2, 3. On the tie (customer 2's two 09:00 rows) they diverge - ROW_NUMBER breaks it with unique numbers (1, 2, 3); RANK gives tied rows the same rank then SKIPS (1, 1, 3); DENSE_RANK gives the same rank with NO gap (1, 1, 2). So for dedup (WHERE = 1): ROW_NUMBER returns ONE row; RANK and DENSE_RANK return BOTH tied rows.
SELECT customer_id, version, status,
       ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS row_number,
       RANK()       OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rank,
       DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS dense_rank
FROM customer_updates
ORDER BY customer_id, row_number;

-- @label: 5. Add the tie-breaker and the three converge
-- @note: With updated_at DESC, version DESC the ties disappear, so ROW_NUMBER, RANK and DENSE_RANK all produce 1, 2, 3 - and WHERE = 1 returns one row for any of them. That is the whole point: the three only differ when the ORDER BY has ties. ROW_NUMBER is the safe default for dedup because it says "exactly one" directly and does not depend on the ordering being unique.
SELECT customer_id, version, status,
       ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC, version DESC) AS row_number,
       RANK()       OVER (PARTITION BY customer_id ORDER BY updated_at DESC, version DESC) AS rank,
       DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY updated_at DESC, version DESC) AS dense_rank
FROM customer_updates
ORDER BY customer_id, row_number;
