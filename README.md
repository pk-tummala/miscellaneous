# miscellaneous

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Languages](https://img.shields.io/badge/languages-SQL%20%7C%20Python%20%7C%20Bash-1f425f.svg)
![Status](https://img.shields.io/badge/status-active-success.svg)

Runnable data-engineering patterns, gotchas and utilities - plus the occasional
long-form design paper. Most entries are small enough to read in a sitting and
self-contained enough to clone and run in seconds.

Some folders are working utilities I've built and used. Most are minimal, runnable
demonstrations of a single idea - a SQL pattern, a Spark internal, a shell habit, a
cloud technique - the kind of thing that's easy to assert in a post and far more
convincing when you can run it and watch it happen. A few are longer design papers,
where the problem is too big for a snippet and the reasoning *is* the deliverable;
those still ship runnable SQL alongside the prose.

Each folder stands alone: its own README, its own sample data or schema, its own
captured output. Nothing here depends on anything else here.

## Scope

The repo grows alongside an ongoing data-engineering writing series - each piece
that includes code drops its runnable snippet here, and longer design work lands as
a paper. It spans four areas:

- **SQL & data modelling** - the ANSI core and the dialect differences (Oracle |
  Teradata | Snowflake | Delta), window functions, dimensional modelling
- **Python & PySpark** - pipeline craft, Spark internals, testing
- **Shell, orchestration & platform** - the glue: bash, scheduling, Hadoop, HDFS
- **Cloud data platforms** - AWS, Snowflake and Databricks

Most demos run on nothing but **bash** (shell demos) or **Python 3 + a local
`.venv`** (Python demos) - no account, no cluster. Each Python demo's `run.sh`
creates its own `.venv` on first run and installs into it, so nothing lands in
your system Python. A few cloud techniques genuinely need a Snowflake /
Databricks / AWS account (and PySpark demos need Java); those ship the real code,
sample data and **captured real output**, clearly labelled, so you can read
exactly what happens without one. No demo here fakes a result.

New to the repo? See [`SETUP.md`](SETUP.md) for a tested WSL Ubuntu 24.04 +
IntelliJ walkthrough.

## Contents

Each folder has its own README with the exact command to run it (most are `bash run.sh`).

### Design & architecture
| Folder | What it does |
|--------|--------------|
| [`metadata-driven-warehouse-extraction/`](metadata-driven-warehouse-extraction/metadata-driven-warehouse-extraction-README.md) | A 34-page white paper on getting a whole data warehouse out in files - roughly a thousand tables, tens of terabytes, a ten-hour nightly window. Covers the metadata control schema, watermarks that can't skip data, restart and reconciliation. Ships the six-table schema and the operational queries as runnable PostgreSQL. |

### SQL & data modelling
| Folder | What it does |
|--------|--------------|
| [`merge-four-engines/`](merge-four-engines/merge-four-engines-README.md) | The same idempotent upsert in Oracle, Teradata, Snowflake and Delta - plus a runnable proof of the one condition idempotency depends on, and what happens when you break it. |
| [`window-functions-mental-model/`](window-functions-mental-model/window-functions-mental-model-README.md) | The picture behind `OVER` / `PARTITION BY` / `ORDER BY` - why a window keeps every row where `GROUP BY` collapses them, and the frame trap that turns a group total into a running total the moment you add `ORDER BY`. |
| [`qualify-clause/`](qualify-clause/qualify-clause-README.md) | Filter a window function directly with `QUALIFY` instead of wrapping it in a subquery. Shows the `WHERE` that's rejected, the old subquery, and the `QUALIFY` that replaces it - plus which engines support it. |
| [`row-number-dedup/`](row-number-dedup/row-number-dedup-README.md) | The most-typed query in data engineering: latest row per key. Shows the tie-break people miss - two rows with the same timestamp make the kept row arbitrary - and the fix, plus ROW_NUMBER vs RANK. |
| [`snowflake-micro-partitions/`](snowflake-micro-partitions/snowflake-micro-partitions-README.md) | Why Snowflake has no indexes: micro-partitions + min/max metadata + pruning. Same 20M rows loaded random vs sorted by date, showing partitions_scanned/total and clustering depth. Needs a Snowflake account; run.sh captures the output automatically. |

### Python & PySpark
| Folder | What it does |
|--------|--------------|
| [`config-driven-python/`](config-driven-python/config-driven-python-README.md) | Keep the settings that change between test and live out of your code, so the same pipeline runs anywhere. Shows the four places a setting can come from - and which one wins. |
| [`databricks-auto-loader/`](databricks-auto-loader/databricks-auto-loader-README.md) | Why listing a bucket to find new files stops scaling, and how Auto Loader's checkpoint fixes it. A runnable open-source proof that only new files are processed each run, plus the real `cloudFiles` code from a Databricks build. |
| [`narrow-vs-wide-transformations/`](narrow-vs-wide-transformations/narrow-vs-wide-transformations-README.md) | The one Spark idea that explains your runtimes: narrow transformations stay in a partition, wide ones shuffle. Shows which ops shuffle via real `explain()` plans, plus the `coalesce` vs `repartition` trap. |
| [`broadcast-joins/`](broadcast-joins/broadcast-joins-README.md) | A regular join shuffles both tables; broadcast the small side and the big fact never moves. Reads the physical plan before (sort-merge, two Exchanges) and after (broadcast hash join, one), and covers the 10MB/8GB limits and the driver-collect cost. |
| [`data-skew-salting/`](data-skew-salting/data-skew-salting-README.md) | Conditional salting: fix a skewed join by salting ONLY the hot key, not the whole table. ACME_CORP holds 1,600,000 of 2,000,000 orders. Normal salting fans the dimension out to 64,016 rows; conditional salting keeps it at 4,016 - same busiest-task drop (1,600,000 -> 100,000) for ~16x less shuffle. Skewed keys found dynamically. |

### Shell, orchestration & platform
| Folder | What it does |
|--------|--------------|
| [`daily-job-status-automation/`](daily-job-status-automation/daily-job-status-automation-README.md) | A pure-shell tool that queries DataStage master sequences and emails a RAG colour-coded daily status report. Runs in a self-contained demo mode out of the box. |
| [`set-euo-pipefail/`](set-euo-pipefail/set-euo-pipefail-README.md) | The same load script twice - one exits 0 after three failures and reports success, the other doesn't. Three characters of insurance. |
| [`event-driven-ingestion-aws/`](event-driven-ingestion-aws/event-driven-ingestion-aws-README.md) | Why polling a bucket on a timer (or keeping a cluster warm) costs you latency and idle compute - and the event-driven fix: S3 -> EventBridge -> Step Functions -> EMR Serverless. A runnable inotify proof of the idea, plus the real AWS wiring. |
| [`cron-environment/`](cron-environment/cron-environment-README.md) | Why a script that works by hand dies at 3am under cron: a bare environment and minimal PATH, none of your `~/.bashrc`. Reproduces it with `env -i` and shows the fix. |
| [`s3-prefix-partition-design/`](s3-prefix-partition-design/s3-prefix-partition-design-README.md) | How folder layout fixes scan cost before you write a query. Writes the same rows partitioned by `dt` vs flat, shows PartitionFilters vs DataFilters and ~10x fewer bytes scanned. Retires the old prefix-for-throughput myth. |
| [`awk-one-liners/`](awk-one-liners/awk-one-liners-README.md) | Ten awk one-liners every data engineer should own - field extraction with a condition, conditional sums, group-by count/sum, dedup without sorting, averages, min/max, deriving a column, and a two-file lookup/join. awk streams line by line, so the same one-liners run on an 8GB file in constant memory (group-bys hold only the distinct keys); `bash run.sh stress 8` proves it. Pure shell, no account. |

_New folders land as the series continues._

### Folder layout

Two shapes, depending on what the folder is.

**Runnable demos** - committed inputs in `config/`, the captured output in
`output/`, and anything a run generates in `data/`, which is git-ignored and
disposable (`rm -rf data` resets any demo). Nothing a demo needs is ever written
to `data/`.

**Document-led folders** - the paper in `docs/` (Markdown, PDF and Word), its
diagrams in `images/`, and any runnable schema in `sql/`.

## Philosophy

Three ideas run through everything here.

**Runnable proof over assertion.** A claim about data engineering is cheap; a
folder you can run and watch is not. Every demo ships the code, its sample data and
its captured output - so the point is demonstrated, not just described.

**Fundamentals outlast the stack.** Engines change every few years; the reasons
behind them - set-based thinking, avoiding the shuffle, idempotency, reading less
data - don't. The focus here is the transferable idea, not the vendor button. And
when a problem's requirements and boundaries are clearly known, a small,
well-bounded tool beats a complex one every time.

**Show what breaks, not just the happy path.** The useful part is usually the
failure: the duplicate key that quietly corrupts a MERGE, the script that exits 0
after failing. Several demos deliberately break, because the gotcha is the lesson.

## Author

**Pavan Kumar Tummala** - Senior Data Engineering professional, Melbourne
[LinkedIn](https://www.linkedin.com/in/pavan-k-tummala/) | [GitHub](https://github.com/pk-tummala)

## License

Released under the [MIT License](LICENSE).
