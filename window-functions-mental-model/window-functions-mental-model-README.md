# Window functions: the mental model

**In one line:** for each row, a window function looks at a *window* of related
rows and returns a value — **without collapsing your rows into groups** the way
`GROUP BY` does.

Most people learn the syntax — `OVER`, `PARTITION BY`, `ORDER BY` — and still find
window functions slippery. This folder is about the picture behind the syntax.
Get the picture once and the rest stops being magic.

---

## Run it

```bash
bash run.sh
```

The first run creates a local `.venv/` in this folder and installs DuckDB into it —
nothing system-wide, so Ubuntu 24.04's PEP 668 block never bites. One-time
prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

Full WSL + IntelliJ walkthrough: [`../SETUP.md`](../SETUP.md). Captured output is in
[`output/output.txt`](output/output.txt). The four teaching queries live in
[`config/queries.sql`](config/queries.sql) — paste any of them straight into DuckDB.

## The one difference that unlocks everything

Start here, because everything else builds on it.

`GROUP BY` **collapses** rows. Ask for the total per region and you get one row per
region — the individual reps are gone:

```
region  region_total
North            260
South            250
```

A window function **keeps every row** and adds the answer as a new column:

```
region  rep  amount  region_total
North   Ana     100           260
North   Ben     100           260
North   Cy       60           260
South   Dee     200           250
South   Eli      50           250
```

Same totals. But every original row survives, with the group total sitting beside
it. **A window function never changes the row count.** That's the whole reason they
exist: they let you compare each row to a summary of its group *without* throwing
the rows away.

## The picture: a line of people

Think of each row as a person standing in a line.

- **`PARTITION BY`** splits people into separate lines — one line per region. The
  calculation restarts in each line. (Leave it out and everyone stands in one big
  line.)
- **`ORDER BY`** decides where each person stands within their line.
- **The frame** is how far back each person can see — which of the others in the
  line their calculation includes.

`PARTITION BY` is the "which rows", `ORDER BY` is the "in what order", and the frame
is the "how many". Those three define the window. That's it.

**One caveat that keeps you honest — and that most tutorials skip.** The frame only
applies to **aggregate** functions (`SUM`, `AVG`, `COUNT`, `MIN`, `MAX`) and to
`FIRST_VALUE` / `LAST_VALUE` / `NTH_VALUE`. The ranking functions (`ROW_NUMBER`,
`RANK`, `DENSE_RANK`) and the offset functions (`LAG`, `LEAD`) **ignore the frame
entirely** — they always see the whole ordered partition. That's exactly why the
trap below is about `SUM` and not about ranking: change the frame and `SUM` moves,
but `ROW_NUMBER` doesn't budge.

## The trap: `ORDER BY` quietly changes the window

This is the one that catches almost everyone, so it's worth slowing down on.

Watch what happens when the *only* change is adding `ORDER BY`. Each rep sold on a
different day, so we order by the day:

```
region  rep  sale_day  amount  partition_total  running_total
North   Ana         1     100              260            100
North   Ben         2     100              260            200
North   Cy          3      60              260            260
South   Dee         1     200              250            200
South   Eli         2      50              250            250
```

- `partition_total` = `SUM(amount) OVER (PARTITION BY region)` → the whole region,
  the same 260 on every North row.
- `running_total` = `SUM(amount) OVER (PARTITION BY region ORDER BY sale_day)` →
  a **running total** that accumulates day by day: 100, then 200, then 260.

You didn't ask for a running total. Adding `ORDER BY` gave you one anyway.

Here's why, and it's worth knowing exactly rather than vaguely. When you add
`ORDER BY` to a window and don't specify a frame, the default frame changes:

- **No `ORDER BY`** → the frame is the **entire partition**. Every row sees the
  whole group, so you get the group total.
- **With `ORDER BY`** → the frame becomes **`RANGE BETWEEN UNBOUNDED PRECEDING AND
  CURRENT ROW`** — "everything from the start of the partition up to this row". So
  the sum grows as you go down: a running total.

That default is straight from the SQL standard (and DuckDB's documentation). If you
actually wanted the group total *and* an ordering, you have to say so explicitly
with `... ORDER BY sale_day RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED
FOLLOWING`.

### Going deeper: what if the order column has ties?

Above, each day is unique, so the running total climbs one row at a time — clean
and intuitive. But there's a subtlety worth knowing for the day it bites you.

Order by a column that has **ties**, and the default `RANGE` frame behaves
differently. Say you ordered by `amount DESC` instead — Ana and Ben both sold 100,
so they tie. Under `RANGE`, tied rows are *peers*, and `CURRENT ROW` means "this
row **and all its peers**". So Ana and Ben would each include the other and both
show **200**, not 100 and 200:

```
rep  amount  running_total   (ORDER BY amount DESC)
Ana     100            200    ← Ana and Ben are peers,
Ben     100            200    ← so they share the value
Cy       60            260
```

Switch to a `ROWS` frame and `CURRENT ROW` means *only this row*, so you'd get 100
then 200 — counted one at a time. Same data, different frame, different answer. The
rule of thumb: when your order column can have ties and you want a strict
one-row-at-a-time running total, order by something unique or say `ROWS` explicitly.

## Ranking is the same idea

Once you have "ordered rows within a window", ranking falls out for free. Same
window, three functions, and they differ only in how they treat ties:

```
region  rep  amount  row_number  rank  dense_rank
North   Ana     100           1     1           1
North   Ben     100           2     1           1
North   Cy       60           3     3           2
```

- **`ROW_NUMBER()`** — always `1, 2, 3`. Ties are broken arbitrarily, so use a
  tie-breaker in `ORDER BY` if you need it stable.
- **`RANK()`** — peers share a number, then it **skips**: `1, 1, 3`.
- **`DENSE_RANK()`** — peers share a number, **no gap**: `1, 1, 2`.

## One more thing that trips people up

A window function runs **after** `WHERE`. So `WHERE` filters the rows first, and the
window only ever sees the survivors — filter out a row and it won't count toward any
running total or ranking.

For the same reason, you can't put a window function in a `WHERE` clause
(`WHERE ROW_NUMBER() OVER (...) = 1` is rejected). Wrap it in a subquery and filter
the result — or use `QUALIFY`, where your engine supports it. That's its own topic;
here the point is just: windows are computed late.

## Does this hold in your engine?

The behaviour in this folder isn't DuckDB-specific — it's the SQL standard, and I
checked the default-frame rule against each vendor's own current documentation:

| Engine | Aggregate + `ORDER BY`, no frame → default |
|--------|--------------------------------------------|
| DuckDB | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |
| PostgreSQL | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |
| Oracle | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |
| Snowflake | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |
| Databricks / Spark SQL | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |
| BigQuery | `RANGE UNBOUNDED PRECEDING … CURRENT ROW` |

So the trap — add `ORDER BY` to an aggregate and you get a running total — is the
same everywhere.

**One caveat worth knowing if you're on Snowflake.** For the *value* functions
`FIRST_VALUE` / `LAST_VALUE` / `NTH_VALUE`, Snowflake's default frame is the **whole
window** (`ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`), which its
docs explicitly note deviates from the ANSI standard. It does **not** change the
aggregate behaviour above — but if you rely on the "up to current row" default for
`LAST_VALUE` on Snowflake, you'll get the last row of the whole partition instead.
When you use those functions, state the frame explicitly on any engine.

## Files

```
window-functions-mental-model/
├── window-functions-mental-model-README.md   this file
├── run.sh              bash run.sh → creates .venv, runs each query, shows the result
├── requirements.txt    Python dependency (duckdb)
├── config/
│   ├── seed.sql        five sales rows (North has a tie, on purpose)
│   └── queries.sql     the four teaching queries — runnable on their own
└── output/
    └── output.txt      captured expected output
```

---

*Every result here was produced by running the queries on DuckDB 1.5. The
default-frame rule was verified against the official documentation of DuckDB,
PostgreSQL, Oracle, Snowflake, Databricks and BigQuery (see the table above).*
