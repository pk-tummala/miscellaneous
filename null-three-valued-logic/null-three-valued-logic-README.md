# NULL is not a value: the NOT IN trap and three-valued logic

**In one line:** `NOT IN (a subquery that contains a NULL)` silently returns **zero rows**.
Nothing errors. It's the bug that quietly breaks reconciliations - and it comes straight from
how SQL treats NULL.

---

## Run it

```bash
bash run.sh
```

Needs `python3` and `python3-venv`. First run installs DuckDB into a local `.venv` (embedded,
no server, no account). Captured output is in [`output/output.txt`](output/output.txt); the
SQL is in [`three_valued_logic.sql`](three_valued_logic.sql).

## The setup

```
orders.customer_id            : 1, 2, 3, 4, 5
excluded_customers.customer_id: 2, 4, NULL      <- one NULL slipped in
```

We want the orders whose customer is **not** excluded - clearly `1, 3, 5`.

## The trap

```sql
SELECT customer_id FROM orders
WHERE customer_id NOT IN (SELECT customer_id FROM excluded_customers);
-- returns 0 rows
```

No error. No warning. Zero rows. In a nightly reconciliation that "no exceptions" looks like
success - until someone notices the numbers never tie out.

## Why it happens: three-valued logic

SQL predicates are not two-valued (TRUE/FALSE). They are **three-valued**: TRUE, FALSE, and
**UNKNOWN**. Any comparison with NULL is UNKNOWN, because NULL means "unknown value", not a
value you can equal or not-equal:

```
1 = NULL     -> UNKNOWN
1 <> NULL    -> UNKNOWN
NULL = NULL  -> UNKNOWN
```

Now expand the trap. `x NOT IN (2, 4, NULL)` is defined as:

```
NOT (x = 2 OR x = 4 OR x = NULL)
= (x <> 2) AND (x <> 4) AND (x <> NULL)
= (x <> 2) AND (x <> 4) AND UNKNOWN
```

`something AND UNKNOWN` can never be TRUE - it is UNKNOWN when the rest is true, FALSE
otherwise. And **`WHERE` keeps a row only when the predicate is TRUE**; UNKNOWN is dropped
exactly like FALSE. So every row fails the test, and you get nothing back.

`IN` with a NULL has the mirror problem: `x IN (2,4,NULL)` is TRUE if x matches, else UNKNOWN
(never a clean FALSE) - which is why you can't simply negate it.

## The fixes

**Reach for `NOT EXISTS`** - it is NULL-safe, because it asks "does a matching row exist?",
never comparing against NULL as if it were a value:

```sql
SELECT customer_id FROM orders o
WHERE NOT EXISTS (
  SELECT 1 FROM excluded_customers e WHERE e.customer_id = o.customer_id
);
-- 1, 3, 5
```

**Or filter the NULLs out** of the subquery so `NOT IN` never sees one:

```sql
SELECT customer_id FROM orders
WHERE customer_id NOT IN (
  SELECT customer_id FROM excluded_customers WHERE customer_id IS NOT NULL
);
-- 1, 3, 5
```

Between the two, prefer `NOT EXISTS`: it stays correct even if someone later removes the
`IS NOT NULL` guard, and the optimiser handles it as an anti-join.

## Takeaways

- A column that is nullable **will** eventually contain a NULL - design for it.
- `NOT IN (subquery)` is a landmine whenever the subquery column is nullable. Default to
  `NOT EXISTS`.
- Test predicates against the three outcomes (TRUE / FALSE / UNKNOWN), not two.
- The danger isn't an error - it's the **silent** wrong answer.

## Portability: this is ANSI SQL, not a DuckDB quirk

Three-valued logic (TRUE / FALSE / UNKNOWN, and the rule that WHERE keeps only TRUE) is the
SQL standard, so the `NOT IN` + NULL trap and the `NOT EXISTS` fix behave the same across the
major engines. Verified against each vendor's own documentation:

| Engine | Official documentation |
| --- | --- |
| SQL Server / Azure SQL | "NULL and UNKNOWN (Transact-SQL)" - comparisons can return UNKNOWN; filters (ON/WHERE/HAVING) treat UNKNOWN as FALSE |
| Oracle | "Nulls" (SQL Language Reference) - a condition comparing to NULL evaluates to UNKNOWN; `NOT IN (...,NULL)` returns no rows |
| PostgreSQL | Comparison operators / NULL - any comparison with NULL yields NULL (unknown) |
| Snowflake | "Ternary logic" - TRUE/FALSE/UNKNOWN, UNKNOWN represented by NULL |
| Databricks (Spark SQL) | "NULL Semantics" - `IN`/`NOT IN` returns UNKNOWN when the list contains a NULL |
| Amazon Redshift | "Nulls" / "Comparison condition" - null equates to UNKNOWN; null is not equal or unequal to any value |
| Amazon Athena (Trino) | Trino follows the SQL standard for NULL and three-valued logic |
| Google BigQuery | "Operators" - `NOT IN` returns NULL when no match and the set contains NULL; logical operators use three-valued logic |
| Teradata | ANSI-standard three-valued logic; `IS NULL` / `IS NOT NULL` predicates for null tests |

**One caveat - SQL Server / Azure SQL `ANSI_NULLS`:** the above assumes the default
`ANSI_NULLS ON` (SQL-92 compliant). With the deprecated `ANSI_NULLS OFF`, `= NULL` / `<> NULL`
use two-valued logic and the trap changes. That option is nonstandard and slated for removal
(it will always behave as ON), so under default settings SQL Server matches everyone else.

Minor quirks that do **not** change the `NOT IN` trap: Oracle treats `''` as NULL, and
Oracle's `DECODE` treats two NULLs as equal.

## Files

```
null-three-valued-logic/
|-- null-three-valued-logic-README.md   this file
|-- three_valued_logic.sql   the setup + all four queries (the SQL)
|-- run.sh                   bash run.sh -> installs duckdb in .venv, runs the demo
|-- run_demo.py              executes the .sql and prints each query with its result
|-- requirements.txt         duckdb
|-- output/
    |-- output.txt           captured expected output
```

---

*Run on DuckDB 1.5.5, deterministic and byte-identical across runs. Three-valued logic (the
TRUE/FALSE/UNKNOWN truth values and the rule that WHERE keeps only TRUE) is standard SQL, not
a DuckDB quirk - the same trap fires in PostgreSQL, SQL Server, Oracle, Snowflake and the
rest.*
