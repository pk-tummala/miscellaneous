# NOT EXISTS vs anti-join vs NOT IN - three ways to ask "what's missing"

**In one line:** to find rows in A with no match in B you can write `NOT EXISTS`, a `LEFT JOIN ... IS
NULL` anti-join, or `NOT IN (subquery)`. They look equivalent - until the subquery contains a `NULL`.
Then `NOT IN` silently returns **zero rows**. Use `NOT EXISTS`. Run `bash run.sh` to see all three on
the same data.

---

## The trap: NOT IN + one NULL = zero rows

`NOT IN` is evaluated with SQL's three-valued logic. `x NOT IN (a, b, NULL)` expands to
`x <> a AND x <> b AND x <> NULL`, and `x <> NULL` is never `TRUE` - it is `UNKNOWN`. So the whole
expression can never be `TRUE`; it is `UNKNOWN` (treated as not-matched) for **every** row, and you
get an empty result.

`IN` returns "false if the expression is not in the RHS
and the RHS has no NULL values, or **NULL if the expression is not in the RHS and the RHS has NULL
values**." `NOT IN` inverts that - and `NOT UNKNOWN` is still `UNKNOWN`.

```sql
-- customers: 1 Alice, 2 Bob, 3 Carol, 4 Dave
-- orders.customer_id: 1, 2, NULL   (one order's customer is unknown)

SELECT * FROM customers
WHERE id NOT IN (SELECT customer_id FROM orders);   -- expected Carol+Dave, actual: ZERO rows
```

This is one of the most common silent SQL bugs: it usually works in dev (no NULLs yet), then a single
NULL lands in prod and the query quietly returns nothing - or in a `WHERE ... NOT IN` filter, drops
everyone.

## The safe patterns

**`NOT EXISTS` (recommended).** A correlated subquery that tests existence, not value equality, so a
NULL in `orders.customer_id` simply doesn't match and the customer is kept.
```sql
SELECT c.id, c.name FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
```
DuckDB "automatically detects when a NOT EXISTS query expresses an antijoin operation" and rewrites
it internally - "there is no need to manually rewrite such queries to use LEFT OUTER JOIN ... WHERE
... IS NULL". Most modern optimizers do the same, so the readable form is typically free - though
decorrelation is not guaranteed for every engine or every correlated predicate.

**`LEFT JOIN ... IS NULL` (explicit anti-join).** Also NULL-safe. Filter on a **non-nullable**
right-side column (the key or PK), not on a column that could itself be NULL.
```sql
SELECT c.id, c.name FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE o.order_id IS NULL;          -- order_id is the PK: NULL only for unmatched rows
```

**`NOT IN` - only when it is safe.** Fine with a literal list of **non-null** constants (`status NOT IN ('x','y')`) or a column
you can *guarantee* is `NOT NULL`. (A literal list that itself contains a NULL - `NOT IN (1, 2, NULL)` -
springs the exact same trap.) With a subquery, guard it:
```sql
WHERE id NOT IN (SELECT customer_id FROM orders WHERE customer_id IS NOT NULL);
```

## Which to reach for

| Pattern | NULL-safe | Notes |
|---|---|---|
| `NOT EXISTS` | yes | Clearest intent; DuckDB rewrites to an anti-join; handles duplicates cleanly. **Default choice.** |
| `LEFT JOIN ... IS NULL` | yes | Explicit anti-join; filter on a non-nullable right column. |
| `NOT IN (subquery)` | **no** | Breaks on a single NULL. Only with a literal list or a guaranteed-non-null column. |

All three compile to a semi/anti-join in DuckDB, so the choice is about **correctness and clarity**,
not speed. `NOT EXISTS` wins on both.

## Two more things worth knowing

**Outer-side NULLs make them diverge even further.** The post above covers a NULL *in the subquery*.
The three patterns *also* differ on a NULL in the **outer (probe) column** - the value you are testing:

| Outer value | `x NOT IN (...)` | `NOT EXISTS` | `LEFT JOIN ... IS NULL` |
|---|---|---|---|
| `NULL` | `NULL` -> row **dropped** | inner never matches -> row **kept** | joins to nothing -> row **kept** |

This never bites on a primary key (non-null), but it does on a *nullable* probe column - "emails not in
a suppression list", "SKUs never ordered". `NOT IN` quietly drops the NULL-keyed rows; `NOT EXISTS`
and the anti-join keep them. So the three are not just unequal on subquery NULLs - they disagree on
outer NULLs too. Decide deliberately whether a NULL-keyed row should count as "missing".

**`EXCEPT` is a fourth, NULL-safe option - with different semantics.**
```sql
SELECT id FROM customers
EXCEPT
SELECT customer_id FROM orders;      -- customers whose id is in neither... set difference
```
`EXCEPT` is NULL-safe and returns the right answer here, but it is not a drop-in for the others: it
**de-duplicates** the result, compares **whole rows** (all selected columns), and - unlike `NOT IN` -
treats `NULL` as **equal to NULL** (set operators use not-distinct comparison). Reach for it when you
want a de-duplicated set difference; reach for `NOT EXISTS` when you want row-by-row anti-join
semantics with duplicates preserved.

## Portability - it's the same on every engine

This is not a DuckDB quirk. `NOT IN` + a NULL is ANSI SQL three-valued logic, so it behaves
identically across traditional RDBMS and cloud warehouses. `NOT EXISTS` and `LEFT JOIN ... IS NULL`
are the NULL-safe anti-join patterns on all of them:

| Engine | NOT IN + a NULL | Source |
|---|---|---|
| Oracle | returns no rows | SQL Reference: `NOT IN (10, 20, NULL)` -> `!= null` -> UNKNOWN -> no rows |
| Databricks / Spark SQL | returns no rows | NULL Semantics: "NOT IN always returns UNKNOWN when the list contains NULL" |
| DuckDB | returns no rows | Subqueries: IN returns NULL when not found and the RHS has NULLs |
| MySQL / MariaDB | returns no rows | docs: "NOT IN with NULL pitfall ... result: empty set" |
| PostgreSQL / Redshift | returns no rows | ANSI 3VL - parses `NOT IN (SELECT ...)` as `NOT (= ANY ...)` |
| SQL Server | returns no rows | ANSI 3VL (`ANSI_NULLS` is always ON in modern versions) |
| Snowflake | returns no rows | ANSI 3VL |
| BigQuery | returns no rows | ANSI 3VL |

Most optimizers (Oracle, SQL Server, PostgreSQL, Snowflake, Databricks/Spark, DuckDB) also rewrite
`NOT EXISTS` into an anti-join automatically - Oracle even labels a null-aware anti-join `HASH JOIN
ANTI NA` in the plan - so the safe form costs nothing.

Two portability footnotes:
- **Oracle** treats the empty string `''` as `NULL`, so a column of empty strings springs the same
  trap even when you believe there are no NULLs.
- For scalar (non-subquery) null-safe comparison, `IS DISTINCT FROM` is the ANSI null-safe operator -
  supported by PostgreSQL, DuckDB, Spark 3.4+, SQL Server 2022+, Snowflake and BigQuery.

## Run it (one click, runs anywhere, idempotent)

```bash
bash run.sh
```

Needs only `python3`; it auto-installs `duckdb` if missing and runs an in-memory demo (deterministic,
safe to re-run). The script tees its output to `output/output.txt`.

## The result

```
PART 1 - a NULL in the subquery      (which customers have no order?  expect Carol, Dave)
  NOT EXISTS                             -> 3 Carol, 4 Dave
  LEFT JOIN ... IS NULL (anti-join)      -> 3 Carol, 4 Dave
  EXCEPT (set difference)                -> 3, 4
  NOT IN (raw subquery)                  -> (no rows)        <- the NULL wiped every row
  NOT IN (WHERE customer_id IS NOT NULL) -> 3 Carol, 4 Dave

PART 2 - a NULL in the outer value   (which leads were not contacted?  leads.id = [1, 2, NULL])
  NOT EXISTS  /  LEFT JOIN ... IS NULL   -> 2, NULL           <- the NULL-keyed lead is kept
  NOT IN (contacted has no NULLs)        -> 2                 <- the NULL-keyed lead is dropped
```

## Files

```
anti-join-patterns/
|-- anti_join_patterns.py   the four queries on the same data
|-- run.sh                  installs duckdb if needed, runs, tees to output/output.txt
|-- output/output.txt       captured real run
```
