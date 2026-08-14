# Partition layout decides scan cost

**In one line:** how you lay out folders in S3 (or any data lake) fixes how much a query
has to read - *before anyone writes a query*. Partition on the column you filter by and
the engine skips whole folders; don't, and every query reads the entire table.

---

## Run it

```bash
bash run.sh
```

Needs `python3`, `python3-venv`, and a JDK. On WSL Ubuntu 24.04:
`sudo apt install -y default-jdk python3-venv`. First run installs PySpark into a local
`.venv`. Captured output is in [`output/output.txt`](output/output.txt). It writes the
same 50,000 rows two ways and runs one query - `WHERE dt = '2024-01-05'` - on each.

## Two layouts, one query

**Partitioned by `dt`** - Hive-style `dt=.../` folders:

```
s3://bucket/events/
  dt=2024-01-01/  dt=2024-01-02/  ...  dt=2024-01-10/
```

**Flat** - `dt` is just a column inside the files, no folders:

```
s3://bucket/events/
  part-00000-*.parquet
```

## What the planner does

Read the physical plan and the difference is right there:

```
A partitioned:  PartitionFilters: [dt = 2024-01-05]   <- prunes 9 of 10 folders, unread
                DataFilters:      []
B flat:         PartitionFilters: (none)
                DataFilters:      [dt = 2024-01-05]    <- opens every file, filters rows
```

When `dt` is a **partition** column, the filter becomes a `PartitionFilter`: the engine
lists and reads only the matching `dt=2024-01-05/` folder and never touches the other
nine. When `dt` is a plain **data** column, it's a `DataFilter`: the engine opens every
file and throws away the rows it doesn't want.

## The cost - you pay per byte scanned

```
A partitioned:   22,194 bytes   (dt=2024-01-05/ only - 1 of 10 days)
B flat:         215,790 bytes   (the whole table)
```

Same 5,000 rows returned either way - but the partitioned query reads **~10%** of the
data, so it's **~10x less scanned and ~10x cheaper**. On Athena and BigQuery you're
billed per byte scanned, so this is a line-item on your invoice; on Spark it's wall-clock
and I/O. The 10x here is just the selectivity (1 of 10 days) - at 365 partitions a
single-day query reads ~0.3% of a year's data.

## Getting the layout right

- **Partition by what you filter on most** - almost always a **date** (`dt=`), because
  most queries are "recent" or "a date range". Add a second level (e.g. `region=`) only
  if you routinely filter on it too; partition-column order should go coarse/most-filtered
  first.
- **Don't over-partition.** Too many tiny partitions is its own problem: thousands of
  small files, slow file listing, and per-file overhead that erases the win. Rule of
  thumb: aim for partitions in the ~100 MB-1 GB range, not one folder per user or per
  minute.
- **Use Hive-style `col=value` folders.** That's the layout Spark, Athena, Presto and
  Hive recognise for automatic pruning.
- **Filter on the partition column directly.** Wrapping it in a function
  (`WHERE year(ts) = 2024` when you partitioned on a `dt` string) can defeat pruning -
  filter on the partition column as stored.

## A myth to retire

Pre-2018, the advice was to put random or hashed characters at the front of your S3 keys
(like `a1b2/log-...`) so requests would spread across partitions for higher throughput.
AWS retired that in 2018: S3 now auto-scales to at least **3,500 PUT / 5,500 GET per
second per prefix** and adds capacity as your request rate grows - logical, sequential
names are fine. (You *can* still parallelise across many prefixes to exceed one prefix's
rate, but that's a high-throughput edge case, not everyday design.) The everyday reason
to think about your prefixes/folders is the one this demo shows: **query pruning** -
scan cost - not request throughput.

## Files

```
s3-prefix-partition-design/
|-- s3-prefix-partition-design-README.md   this file
|-- run.sh                bash run.sh -> writes both layouts, runs the query, shows cost
|-- requirements.txt      Python dependency (pyspark)
|-- partition_pruning.py  the demo
|-- output/
    |-- output.txt        captured expected output
```

---

*Plans and byte counts produced on PySpark 4.2 (`local[2]`); local parquet mirrors S3
parquet. `PartitionFilters` vs `DataFilters` is read from the physical plan (expression
ids stripped).*
