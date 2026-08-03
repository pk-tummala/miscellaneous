# QUALIFY: filter a window function without a subquery

**In one line:** `QUALIFY` is `WHERE` for window functions — it lets you filter on a
`ROW_NUMBER()`, `RANK()`, running total, or any window result directly, instead of
wrapping the query in a subquery just to filter it.

---

## Run it

```bash
bash run.sh
```

The first run creates a local `.venv` and installs DuckDB into it — nothing
system-wide. One-time prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

Captured output is in [`output/output.txt`](output/output.txt). The four queries are
in [`config/queries.sql`](config/queries.sql) — paste any of them into DuckDB.

## The problem: you can't filter a window in WHERE

Window functions are computed *after* `WHERE` runs. So this — "give me the top rep
per region" — is rejected outright:

```sql
SELECT region, rep, amount
FROM sales
WHERE ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) = 1;
-- Binder Error: WHERE clause cannot contain window functions!
```

The row number doesn't exist yet when `WHERE` is evaluated. You need a way to filter
*after* the window runs.

## The old way: a wrapper subquery

Compute the row number in a derived table, then filter it in an outer query:

```sql
SELECT region, rep, amount FROM (
  SELECT region, rep, amount,
         ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn
  FROM sales
) WHERE rn = 1;
```

It works. But you didn't want the subquery — it's there purely to give the window
result a name you can filter on. And now you have a stray `rn` column to remember to
drop.

## The QUALIFY way

```sql
SELECT region, rep, amount
FROM sales
QUALIFY ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) = 1;
```

Same rows. No derived table, no leftover column. `QUALIFY` filters on the window
function directly, in the same query block.

The clean way to think about it: **`QUALIFY` does for window functions exactly what
`HAVING` does for `GROUP BY`.** `WHERE` filters rows before grouping; `HAVING` filters
after aggregation; `QUALIFY` filters after window functions. That's the mental slot it
fills.

## It's not just `ROW_NUMBER`

`QUALIFY` takes *any* window expression as its predicate. Keep only the reps who beat
their region's average:

```sql
SELECT region, rep, amount
FROM sales
QUALIFY amount > AVG(amount) OVER (PARTITION BY region);
```

So it filters on `RANK()`, `LAG()`, running totals, per-group averages — anything you
can put in an `OVER` clause. Two patterns you'll reach for constantly:

- **Top-N per group** — `QUALIFY ROW_NUMBER() OVER (PARTITION BY g ORDER BY x DESC) <= N`.
- **Deduplicate / keep the latest** — `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) = 1`. This one alone replaces a huge share of "wrap it in a subquery" code.

## Where it works (and where you still need the subquery)

`QUALIFY` is **not** part of the SQL standard. It started as a Teradata extension and
has been adopted by several engines:

| Supports `QUALIFY` | Use the subquery instead |
|--------------------|--------------------------|
| Teradata (origin), Snowflake, Databricks SQL, BigQuery, DuckDB, Redshift | PostgreSQL, MySQL, SQL Server |

So on Snowflake or Databricks, reach for `QUALIFY`. On Postgres or MySQL, the portable
pattern is still the wrapper subquery from above — same logic, more lines.

## Files

```
qualify-clause/
├── qualify-clause-README.md   this file
├── run.sh                     bash run.sh → runs each query, shows the result
├── requirements.txt           Python dependency (duckdb)
├── config/
│   ├── seed.sql               five sales rows
│   └── queries.sql            the four queries — runnable on their own
└── output/
    └── output.txt             captured expected output
```

---

*Every result here was produced on DuckDB 1.5.*
