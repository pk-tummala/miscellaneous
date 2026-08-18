# Micro-partitions: why standard Snowflake tables have no indexes

**In one line:** a standard Snowflake table has no `CREATE INDEX`. Every table is split
into immutable micro-partitions, each storing the min/max of every column, and a filtered
query skips (prunes) the partitions that can't hold a match. Pruning replaces indexing -
but it only works if the values you filter on are physically co-located, which is what
clustering controls. (Hybrid / Unistore tables, Snowflake's OLTP option, are the
exception - those *do* support `CREATE INDEX`. This is about standard analytical tables.)

> **Needs a Snowflake account.** This is real SQL against real data. An XSMALL warehouse
> and a free trial are enough.

## Run it

```bash
bash run.sh                 # uses your default Snowflake CLI connection
bash run.sh my_connection   # or a named connection
```

`run.sh` executes [`micro_partitions_demo.sql`](micro_partitions_demo.sql) through the
Snowflake CLI (`snow`) and writes the captured results into
[`output/output.txt`](output/output.txt) automatically - no manual copy/paste. You need
the Snowflake CLI installed and a connection configured (`pip install snowflake-cli`, then
`snow connection add`). Legacy SnowSQL works too; see the fallback printed by `run.sh`.

The data is generated **deterministically** - from a hashed row number, not `RANDOM()`
(which Snowflake does not reproduce across runs, even with a seed). So the rows are the
same every run.

The **partition counts still wobble** though - the total might be 128 one run and 126 the
next, and the clustered query might scan 1 partition or 2. That is not the data changing;
it is Snowflake packing micro-partitions in **parallel** at load time, so the boundaries
are execution-dependent. No SQL controls that. What is rock-solid is the **ratio**
(`pct_scanned`): the unclustered query scans ~100% of its partitions every time, the
clustered query scans ~1%. **All partitions vs about one** is the reproducible result and
the whole point of the post - don't read too much into the exact counts.

## What a micro-partition is

When you load a table, Snowflake automatically divides it into **micro-partitions**:
immutable, columnar storage units of 50 to 500 MB of uncompressed data, stored compressed on disk. A
large table can have thousands or millions of them. For each one, Snowflake records
metadata in the services layer: the **min and max of every column**, distinct counts,
null counts. You never create or size them.

## Why standard tables have no indexes

A traditional database points a B-tree index at a column so lookups skip most of the
table. Snowflake does the same job with the micro-partition metadata instead. When you
write `WHERE event_date = DATE '2024-06-15'`, the planner reads each partition's min/max
for `event_date` and eliminates every partition whose range can't contain that date. It
only scans what's left. That's **partition pruning**, and it's why a selective query on a
50-terabyte table can return in seconds without a single index. (Snowflake's hybrid /
Unistore tables do support indexes for OLTP-style point lookups; the rest of this note is
about standard tables.)

## The catch: pruning needs co-location (clustering)

Pruning only helps if the partitions you *don't* need have tight, non-overlapping ranges
on the column you filter by. Data is naturally partitioned by **load order**:

- Load rows in **random** date order and every partition's `event_date` min/max spans
  almost the whole year. No partition can be ruled out, so a one-day filter scans
  (nearly) everything.
- Load the same rows **sorted by `event_date`** and each partition holds a narrow slice
  of dates. A one-day filter now prunes almost every partition.

Same data, same query, very different cost - decided entirely by physical layout. At
scale you don't re-sort by hand; you set a **clustering key**
(`ALTER TABLE ... CLUSTER BY (event_date)`) and Snowflake's automatic clustering keeps the
table organised. This demo uses sorted-vs-random load order to show the effect
immediately, without waiting for the background service.

## How to read the results

Two signals, both captured by the script:

- **`SYSTEM$CLUSTERING_INFORMATION(...)` gives `average_depth`.** How many partitions overlap
  on a typical value. Lower is better; 1.0 is perfect. The unclustered table's depth is
  high; the clustered table's is near 1.
- **`GET_QUERY_OPERATOR_STATS(...)` gives `partitions_scanned` / `partitions_total`** on the
  `TableScan`, and the script derives **`pct_scanned`** from them. This is what actually
  happened. **The ratio is the number to watch** (the raw counts wobble run to run - see
  the note above): ~100% scanned means no pruning; ~1% means pruning did its job. (Also in
  the Query Profile as "Partitions scanned" vs "Partitions total".)

`output/output.txt` is filled in for you by `run.sh`. The story the numbers tell: the clustered
table scans a small fraction of its partitions for the one-day filter; the unclustered
table scans almost all of them - for the identical query and identical rows.

## The gotcha (Section 4): don't defeat your own pruning

Pruning uses the column's stored metadata, so it breaks the moment you stop filtering on
the column *as stored*:

- **Wrapping the column in a function** - `WHERE TO_VARCHAR(event_date) = '2024-06-15'` -
  forces a row-by-row evaluation, so the min/max metadata is useless and the scan falls
  back to (nearly) full. The demo shows this directly (Section 3). Filter on the column as
  stored instead: `WHERE event_date = DATE '2024-06-15'`.
- **Predicates with subqueries** don't prune either - this one is stated in Snowflake's
  own docs: "Snowflake does not prune micro-partitions based on a predicate with a
  subquery, even if the subquery results in a constant."

Section 3 of the script demonstrates this with `TO_VARCHAR(event_date) = '2024-06-15'`:
same clustered table, but `partitions_scanned` jumps back up toward the total.

## Files

```
snowflake-micro-partitions/
|-- snowflake-micro-partitions-README.md   this file
|-- micro_partitions_demo.sql   the SQL run.sh executes
|-- run.sh   runs the SQL via the Snowflake CLI, writes output/output.txt
|-- output/
    |-- output.txt   captured results (written automatically by run.sh)
```

---

*Facts verified against a real Snowflake run: micro-partitions and the min/max pruning
that replaces indexes, natural clustering by load order, `average_depth` from
SYSTEM$CLUSTERING_INFORMATION, and `partitions_scanned` / `partitions_total` from
GET_QUERY_OPERATOR_STATS. Every number in output/output.txt is captured straight from
executing this SQL on a live Snowflake account - nothing here is generated.*
