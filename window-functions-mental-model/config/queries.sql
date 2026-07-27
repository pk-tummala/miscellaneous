-- queries.sql — the mental model in four steps. Runs as-is on DuckDB.
-- Each block below is a self-contained query; the runner prints it, runs it,
-- and shows the result. You can also just paste any block into DuckDB yourself.

-- @label: 1. GROUP BY collapses rows — one row per group, the detail is gone
-- @note: GROUP BY answers "what is the total per region?" and discards the individual reps.
SELECT region, SUM(amount) AS region_total
FROM sales
GROUP BY region
ORDER BY region;

-- @label: 2. A window keeps every row — same total, detail intact
-- @note: PARTITION BY region groups like GROUP BY does, but collapses nothing. Every rep survives and gets the region total beside them. A window function never changes the row count.
SELECT region, rep, amount,
       SUM(amount) OVER (PARTITION BY region) AS region_total
FROM sales
ORDER BY region, sale_day;

-- @label: 3. THE TRAP — adding ORDER BY silently changes what the window sees
-- @note: partition_total sees the whole region, so it is the same 260 on every North row. running_total only adds ORDER BY sale_day - but that changes the default frame from "the whole partition" to "everything up to this row", so it accumulates: 100, then 200, then 260. You asked for a total; ORDER BY quietly turned it into a running total. Almost everyone trips on this once.
SELECT region, rep, sale_day, amount,
       SUM(amount) OVER (PARTITION BY region)                     AS partition_total,
       SUM(amount) OVER (PARTITION BY region ORDER BY sale_day)   AS running_total
FROM sales
ORDER BY region, sale_day;

-- @label: 4. ORDER BY inside the window also powers ranking
-- @note: Same idea, three ranking functions, ordering by amount so the tie shows. Ana and Ben both sold 100. ROW_NUMBER is always 1,2,3 (the tie is broken arbitrarily). RANK gives the tied rows the same number then skips (1,1,3). DENSE_RANK gives the tied rows the same number with no gap (1,1,2).
SELECT region, rep, amount,
       ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS row_number,
       RANK()       OVER (PARTITION BY region ORDER BY amount DESC) AS rank,
       DENSE_RANK() OVER (PARTITION BY region ORDER BY amount DESC) AS dense_rank
FROM sales
ORDER BY region, amount DESC, rep;
