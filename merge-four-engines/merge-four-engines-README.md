# One idempotent MERGE, four engines

The upsert is the most-written statement in data engineering. Every engine has
`MERGE`, they all look nearly identical — and the differences are exactly where
production breaks.

This folder holds a runnable proof that `MERGE` is idempotent, and a runnable
demonstration of the one condition that idempotency depends on.

## Run it

```bash
bash run.sh
```

The first run creates a local `.venv/` in this folder and installs DuckDB into it
— your system Python is never touched, so Ubuntu 24.04's PEP 668 block never
bites. Later runs reuse it and start instantly.

One-time prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

Full WSL + IntelliJ walkthrough: [`../SETUP.md`](../SETUP.md). Captured output is
in [`output.txt`](output.txt).

DuckDB implements ANSI `MERGE`, which is the same statement shape you'd write on
Oracle, Snowflake or Delta — so the demo runs the real thing rather than a
simulation.

## What it proves

1. **The MERGE runs** — one row updated, one inserted, one left alone.
2. **It runs again, unchanged.** The target fingerprint is byte-identical after
   the second run. That's idempotency: same input, same state, however many times
   you run it.
3. **Then it breaks.** Point the same `MERGE` at a *source* that has two rows for
   one key. The *target* still holds one row for that key — both source rows match
   it, so the engine has to pick a winner. It prints the source (two rows), the
   target before, and the target after, so you can see the count never changes and
   the wrong value can quietly win.

## The four dialects

Same intent, four flavours. The differences are small until they aren't.

**Oracle**

```sql
MERGE INTO customer_dim t
USING customer_stg s
   ON (t.customer_id = s.customer_id)
WHEN MATCHED THEN
    UPDATE SET t.full_name  = s.full_name,
               t.balance    = s.balance,
               t.updated_at = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (customer_id, full_name, balance, updated_at)
    VALUES (s.customer_id, s.full_name, s.balance, s.updated_at);
```

Oracle wraps the `ON` clause in brackets, and uniquely lets you hang a
`DELETE WHERE` off the `WHEN MATCHED` branch — handy for purging rows that a
soft-delete flag has just retired.

**Teradata**

```sql
MERGE INTO customer_dim AS t
USING customer_stg AS s
   ON t.customer_id = s.customer_id
WHEN MATCHED THEN
    UPDATE SET full_name  = s.full_name,
               balance    = s.balance,
               updated_at = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (customer_id, full_name, balance, updated_at)
    VALUES (s.customer_id, s.full_name, s.balance, s.updated_at);
```

The catch is architectural: the `ON` clause **must** include the target's primary
index. Teradata needs to know the row lives on the same AMP as the source row
before it will merge it. Miss it and you get an error, not a slow query.

**Snowflake**

```sql
MERGE INTO customer_dim AS t
USING customer_stg AS s
   ON t.customer_id = s.customer_id
WHEN MATCHED THEN
    UPDATE SET t.full_name  = s.full_name,
               t.balance    = s.balance,
               t.updated_at = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (customer_id, full_name, balance, updated_at)
    VALUES (s.customer_id, s.full_name, s.balance, s.updated_at);
```

Snowflake ships a guard rail: `ERROR_ON_NONDETERMINISTIC_MERGE` defaults to
`TRUE`, so a duplicate key in the source raises rather than silently picking a
winner. Leave it on.

**Databricks / Delta**

```sql
MERGE INTO customer_dim AS t
USING customer_stg AS s
   ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
```

Delta's `SET *` / `INSERT *` shorthand maps matching column names automatically —
lovely for wide tables, and a footgun the day someone adds a column upstream.
Delta also offers `WHEN NOT MATCHED BY SOURCE`, which is how you express
"rows that vanished upstream" without a second statement.

## The condition nobody mentions

`MERGE` is idempotent **only if the source has one row per key.**

Break that and the four engines stop agreeing:

| Engine | Duplicate key in source |
|---|---|
| Oracle | `ORA-30926: unable to get a stable set of rows in the source tables` |
| Snowflake | Errors by default (`ERROR_ON_NONDETERMINISTIC_MERGE`) |
| Delta | Errors: multiple source rows matched a target row |
| DuckDB | **Silently picks one** — run `./run.sh` and watch it happen |

Three fail loudly. One fails quietly. The quiet one is the dangerous one: the job
goes green, the pipeline reports success, and the number is simply wrong.

When you run `./run.sh`, it prints the **whole** `customer_dim` after the broken
merge — not just Bob's row. That's deliberate. The table still has four rows, no
error was raised, and only one row changed. **A corrupted table looks exactly like
a healthy one.** No row-count check, no constraint, no green/red tick catches it.
(And because the pick isn't guaranteed, re-running may land Bob on the *other*
value — that non-determinism *is* the bug.)

## "Won't a primary key stop this?"

The obvious reflex is to put a `PRIMARY KEY` or unique constraint on the target and
move on. On the analytical tables you'd actually `MERGE` into, it doesn't save you —
and the details are worth knowing, because whether a PK is even *enforced* differs
by engine and table type:

| Engine / table type | PK · UNIQUE · FK enforced? |
|---|---|
| Oracle, Teradata | **Yes** — enforced |
| Snowflake — standard tables | No — informational only (only `NOT NULL` and `CHECK` are enforced) |
| Snowflake — **hybrid tables (Unistore)** | **Yes** — PK is required and enforced; UNIQUE and FK enforced too |
| Databricks / Delta | No — PK, FK and UNIQUE are informational only (UNIQUE is a recent, still-unenforced addition) |

So "just add a PK" silently does **nothing** on a standard Snowflake table or a
Delta table — which is exactly where a `customer_dim` lives. Snowflake's *hybrid*
tables do enforce it, but those are a row-store, OLTP-oriented type for Unistore
workloads, not the columnar analytical table you'd build a dimension on. Declaring
a PK on the wrong table type is the first trap.

**And even where a PK is enforced, it's a backstop, not a fix.** Watch which path
the duplicate takes:

| Duplicate lands on… | What an enforced PK does |
|---|---|
| `WHEN NOT MATCHED → INSERT` (key is new, two source rows for it) | **Catches it.** The second insert violates the constraint and the statement fails (`ORA-00001`). This is the one path a PK genuinely protects. |
| `WHEN MATCHED → UPDATE` (key already in target, two source rows match it — our Bob) | **Blind to it.** One row is updated, once. The PK is never violated. The engine just overwrites a good value with the wrong one of the two. Row count stays right, the constraint stays satisfied, the number is still wrong. |

That second row is the whole point. The failure that actually corrupts your data —
a non-deterministic *update* — is precisely the one a constraint can never see.
Oracle even raises `ORA-30926` on that path *before* the PK is tested, because the
problem is an ambiguous join, not a constraint breach.

So the fix isn't a constraint on the target. It's **one row per key in the
source**, before the `MERGE` ever runs — a single `ROW_NUMBER()` over the key,
ordered by your tie-break rule, filtered to `= 1`. Cheap insurance against a class
of bug that is genuinely hard to find later, and the only thing that works on all
four engines.

## Files

```
merge-four-engines/
├── merge-four-engines-README.md   this file
├── run.sh                 ./run.sh → creates .venv, runs everything, prints the proof
├── requirements.txt       Python dependency (duckdb)
├── config/
│   ├── seed.sql           target + staging tables, incl. the duplicate-key source
│   └── merge_demo.sql     the MERGE itself (ANSI; runs as-is on DuckDB)
└── output/
    └── output.txt         captured expected output
```
