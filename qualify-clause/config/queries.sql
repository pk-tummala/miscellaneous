-- queries.sql — QUALIFY, in four steps. Runs as-is on DuckDB.
-- The runner prints each block, runs it, and shows the result (or the error, for
-- the one that's meant to fail). Paste any block straight into DuckDB yourself.

-- @label: 1. You can't filter a window function in WHERE
-- @note: Window functions are computed AFTER WHERE runs, so the planner rejects this outright. That is the whole reason you need a workaround to filter on one.
-- @expect_error
SELECT region, rep, amount
FROM sales
WHERE ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) = 1;

-- @label: 2. The old way — wrap it in a subquery and filter outside
-- @note: Compute the row number in a derived table, then filter rn = 1 in the outer query. It works, but it is a wrapper you did not want, and you have to remember to drop the rn column from the output.
SELECT region, rep, amount FROM (
  SELECT region, rep, amount,
         ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn
  FROM sales
) WHERE rn = 1
ORDER BY region;

-- @label: 3. The QUALIFY way — same result, no wrapper
-- @note: QUALIFY filters on the window function directly, in the same query block. It is to window functions what HAVING is to GROUP BY. Same rows, no derived table, no leftover rn column.
SELECT region, rep, amount
FROM sales
QUALIFY ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) = 1
ORDER BY region;

-- @label: 4. QUALIFY isn't just for ROW_NUMBER — any window function works
-- @note: Keep only the reps who beat their region's average. QUALIFY takes any window expression as its predicate, so it filters on averages, running totals, RANK, LAG - anything you can put in an OVER clause.
SELECT region, rep, amount
FROM sales
QUALIFY amount > AVG(amount) OVER (PARTITION BY region)
ORDER BY region, amount DESC;
