# ROW_NUMBER() dedup: the latest record per key

**In one line:** keeping the newest row per key is one of the most common queries in data
engineering — and the part people get wrong is the **tie-break**: when two rows share
the same timestamp, which one you keep is arbitrary unless you make the rule explicit.

---

## Run it

```bash
bash run.sh
```

First run creates a local `.venv` and installs DuckDB. Prereq on WSL Ubuntu 24.04:
`sudo apt install -y python3 python3-venv`. Captured output is in
[`output/output.txt`](output/output.txt); the queries are in
[`config/queries.sql`](config/queries.sql).

## The pattern

You have several rows per key (a CDC feed, an append log, a source with duplicates) and
you want the latest one per key:

```sql
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
  FROM customer_updates
)
SELECT * FROM ranked WHERE rn = 1;
```

`PARTITION BY` restarts the numbering for each key; `ORDER BY ... DESC` puts the newest
first; `rn = 1` keeps it. (On Snowflake/Databricks/BigQuery/DuckDB you can drop the CTE
and write `QUALIFY ROW_NUMBER() OVER (...) = 1` — same logic, no wrapper.)

## The trap: ties in the ORDER BY

Here's where it goes wrong. In the demo, customer 2 has **two rows with the exact same
`updated_at`**. The `ORDER BY updated_at DESC` can't tell them apart, so `ROW_NUMBER`
assigns `rn = 1` to one of them **arbitrarily**. In this run it kept `active` — but
`suspended` (version 2) is the later update, the row you actually wanted.

The dangerous part isn't that it's random — it's that it's **implementation-dependent
and silent**. On DuckDB today it happens to be stable, but the SQL standard doesn't
guarantee *which* tied row wins. A different engine, a new index, a parallel plan, or a
data reload can flip it — and your "latest record" quietly changes with no error.

## The fix: make the tie-break explicit

Add a **unique, monotonic** secondary sort key so no two rows can tie:

```sql
ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC, version DESC)
```

Now `latest` is fully determined — customer 2 resolves to `suspended`, reproducibly, on
every engine and every run. Good tie-breakers: a version number, a monotonic ingest/
sequence id, a surrogate key — anything guaranteed unique within the partition. If you
don't have one, that's a signal your source lacks a reliable ordering, which is worth
knowing before it bites you downstream.

## ROW_NUMBER vs RANK vs DENSE_RANK — and when to use each

They look interchangeable, and on data with **no ties they are**: give all three a
fully-ordered `ORDER BY` and they all produce `1, 2, 3, …`. They only diverge on a
**tie**. On customer 2's two rows that share a timestamp (with an older row beneath):

| function     | numbers the tie as       | on `WHERE = 1`  |
|--------------|--------------------------|-----------------|
| `ROW_NUMBER` | `1, 2` then `3` (unique)  | one row         |
| `RANK`       | `1, 1` then `3` (a gap)   | both tied rows  |
| `DENSE_RANK` | `1, 1` then `2` (no gap)  | both tied rows  |

When to reach for each:

- **`ROW_NUMBER`** — keep **exactly one** per key (dedup). It always assigns a unique
  number, so `= 1` returns a single row *whether or not* the `ORDER BY` has ties. That
  robustness is why it's the safe default for dedup.
- **`RANK`** — **top-N with ties, competition-style**. Ties share a rank and the next
  rank skips (two 1sts, then 3rd), so the number tells you how many rows are ahead. Use
  it when you want *all* rows tied at a position and the gap is meaningful.
- **`DENSE_RANK`** — **top-N distinct values, no gaps**. Ties share a rank and the next
  is consecutive (two 1sts, then 2nd). Use it for "rows in the top *N* distinct values" —
  e.g. everyone in the top 3 distinct salary bands (`DENSE_RANK() <= 3`).

Here's the subtlety worth internalising: add the unique tie-breaker from the fix above
and the ties disappear — so `ROW_NUMBER`, `RANK` and `DENSE_RANK` all produce `1, 2, 3`,
and any of them would dedup correctly. **The three only differ when ties exist.**
`ROW_NUMBER` is still the right default for dedup because it states "exactly one"
directly and doesn't rely on your ordering being unique.

## Two more ways to get it slightly wrong

- **Forgetting `DESC`.** `ORDER BY updated_at` (ascending) keeps the **oldest** row per
  key, not the newest. Silent, and exactly backwards.
- **NULLs in the sort column.** If your recency column can be `NULL`, be explicit with
  `NULLS LAST` / `NULLS FIRST` — the default placement varies by engine, so a `NULL`
  timestamp can end up "newest" on one database and "oldest" on another.

## The rule

`ORDER BY` your recency column **plus a unique tie-breaker**, and use `ROW_NUMBER`.
That one habit turns one of the most common queries in data engineering from *usually right* into
*always right*.

## Files

```
row-number-dedup/
├── row-number-dedup-README.md   this file
├── run.sh                bash run.sh → runs each query, shows the result
├── requirements.txt      Python dependency (duckdb)
├── config/
│   ├── seed.sql          five rows; customer 2 is the tie
│   └── queries.sql       the four queries — runnable on their own
└── output/
    └── output.txt        captured expected output
```

---

*Every result was produced on DuckDB 1.5. That `ROW_NUMBER` gives a unique number while
`RANK` repeats on ties is standard SQL window-function behaviour; that the order of tied
rows is unspecified (hence the need for an explicit tie-breaker) is a property of the SQL
standard, not a DuckDB quirk.*
