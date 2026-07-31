# Auto Loader — ingestion that doesn't re-read your lake

**In one line:** to pick up new files as they land, don't list your whole bucket
every run — track what you've already ingested and process only what's new.
Databricks Auto Loader does exactly that, at scale.

This folder has two parts:
- a **runnable local proof** (open-source Spark, no account) that shows the core
  behaviour — a checkpoint means each run processes only the new files;
- the **real Auto Loader code** (`auto_loader_databricks.py`) from a Databricks
  lakehouse build, which keeps that behaviour and adds the parts that need a
  Databricks workspace.

---

## The problem

A pipeline that ingests files from a data lake has to answer one question every
run: *which files are new?* The naive way is to **list the directory** and compare
against what you've seen. That works on a laptop. It falls apart on a real lake.

Databricks' own docs give the arithmetic. If files land as
`/path/YYYY/MM/DD/HH/file`, a plain Spark file source lists every subdirectory to
find them — for a year of hourly folders that's `1 + 365*24 = 8761` LIST calls to
object storage, and it re-lists to discover new files. On a prefix with millions of
objects, each run spends more time listing than processing, and your storage bill
climbs with it.

And if you get discovery wrong, the other failure is worse: you re-read files you
already processed and load duplicates.

## What Auto Loader gives you

Auto Loader is a Structured Streaming source (`cloudFiles`) that fixes both halves.

**1. Incremental discovery — stop walking the whole tree.**
- *Directory listing mode* (the default) still lists, but Databricks optimises it
  (a flattened listing, and optional incremental listing for lexically-ordered
  files) so it makes far fewer calls than a plain Spark file source.
- *File notification mode* (`cloudFiles.useNotifications = true`) flips discovery
  around: Auto Loader sets up a cloud notification + queue service, so it's **told**
  when a file arrives instead of listing for it. Databricks documents this scaling
  to **millions of files an hour**, and recommends it (via file events) for most
  large workloads.

**2. A checkpoint — never re-read what you've ingested.**
Auto Loader records every processed file in a durable key-value store (RocksDB) at
the `checkpointLocation`. On the next run it processes only the new files; if a run
is killed mid-flight, the next run resumes exactly where it left off. That's
exactly-once, and it's the "doesn't re-read your lake" in the title.

**3. Schema inference and evolution — don't break silently when the data changes.**
Point `cloudFiles.schemaLocation` at a directory and Auto Loader infers the schema
and tracks it over time. When a genuinely new column appears, the behaviour depends
on `schemaEvolutionMode`:
- `addNewColumns` (the default when you don't supply a schema) does **not** silently
  continue — the stream **stops** with an `UnknownFieldException`, writes the updated
  schema to the schema location, and picks the new column up on the **next** run. Run
  it as a Databricks Job and that restart is automatic.
- `rescue` keeps the schema fixed and never stops the stream; new fields go into the
  rescued column instead.

Separately, data that doesn't match the *current* schema — a type mismatch, a casing
difference — is captured in an automatically-added **`_rescued_data`** column (as a
JSON blob with the source path) rather than being dropped or failing the run. Note
the distinction: `_rescued_data` catches mismatches against the known schema; a brand
new column under `addNewColumns` triggers the exception-and-restart above, it isn't
rescued.

## Run the local proof

```bash
bash run.sh
```

This runs `local_incremental_demo.py` using **open-source** Spark Structured
Streaming — no Databricks, no `cloudFiles`. It stages the sample files from
`config/` into a landing folder one "day" at a time and processes each drop with a
checkpoint. Prerequisites on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv openjdk-17-jre-headless
```

First run creates a local `.venv` and installs PySpark (a minute or so). Captured
output is in [`output/output.txt`](output/output.txt). What you'll see:

```
Day 1: two sales land        rows processed THIS run: 2   total: 2
Day 2: one new file lands    rows processed THIS run: 1   total: 3
Day 3: one new file lands    rows processed THIS run: 2   total: 5
Re-run with NO new files     rows processed THIS run: 0   total: 5
```

Read the middle column. After day 1 it processed 2 rows; every run after that
touched **only the newly-arrived file**; and the final re-run with nothing new
processed **0**. The checkpoint skipped everything already ingested. The lake is
never re-read — on your own laptop, with plain Spark.

## What the local proof does NOT show (and why the Databricks code exists)

The demo uses a plain file source, which discovers files by **listing** the landing
folder — fine for four files, but it *is* the thing that doesn't scale. And it uses
a fixed schema, so there's no inference or evolution.

Those two gaps — scalable discovery, and schema inference/evolution — are precisely
what Auto Loader adds, and they need a Databricks workspace. See
[`auto_loader_databricks.py`](auto_loader_databricks.py): the same checkpointed,
`trigger(availableNow=True)` shape you just ran, but with `cloudFiles`,
`cloudFiles.schemaLocation`, and `_rescued_data`. The exact steps to run it are in
**Run the Auto Loader code on Databricks** below.

So: the **behaviour** is proven here locally; the **scale and schema handling** are
in the Databricks code.

## Run the Auto Loader code on Databricks

This is the part that needs a workspace (that's the "T3" in the plan). Every step
below is standard Databricks; the option names in the code are from the official
docs.

**Prerequisites**
- A Databricks workspace with **Unity Catalog** enabled, and a cluster (or SQL
  warehouse for the queries) you can run.
- A catalog, a schema, and an existing **Volume** you can write to. A volume path is
  `/Volumes/<catalog>/<schema>/<volume>/…`, and **the volume must already exist** —
  you can't create it just by naming it in a path (that's the `UC_VOLUME_NOT_FOUND`
  error). The code uses catalog `main`, schema `bronze`, and a volume named
  `landing`. Edit the `catalog` / `schema` / `volume` variables at the top of
  `auto_loader_databricks.py` to match yours.
- Permissions: `USE CATALOG` + `USE SCHEMA`, `WRITE VOLUME` on the volume, and
  `CREATE TABLE` on the schema.

**Steps**
1. **Upload the first file into the volume.** The source lives in a `suburb_sales`
   sub-directory of your volume. Sidebar → *New* → *Add or upload data* →
   *Upload files to a volume* → navigate into your `landing` volume, into
   `suburb_sales` (create the folder here if it doesn't exist) → upload
   `config/day1.json`. (CLI alternative — note the required `dbfs:/` prefix:
   `databricks fs cp config/day1.json dbfs:/Volumes/main/bronze/landing/suburb_sales/`.)
   You do **not** create `_schemas` or `_checkpoints` — Auto Loader makes those
   directories inside the volume on the first run.
2. **Run the code.** Create a notebook, paste in `auto_loader_databricks.py`, attach
   a cluster, and run. It ingests the file into `main.bronze.suburb_sales` and then
   **stops** — that's `trigger(availableNow=True)`.
3. **Check the result.**
   ```sql
   SELECT * FROM main.bronze.suburb_sales;
   -- which files Auto Loader has already processed:
   SELECT * FROM cloud_files_state('/Volumes/main/bronze/landing/_checkpoints/suburb_sales/');
   ```
4. **Prove the incremental behaviour.** Upload `day2.json` into the same
   `suburb_sales` folder and run the notebook again. Only the new file is processed —
   the checkpoint skips `day1.json`. That's the same thing the local proof shows, now
   on Auto Loader.
5. **(Optional) See schema evolution.** Upload a file with an extra column and re-run.
   With the default `addNewColumns`, the run stops with `UnknownFieldException` and
   records the new schema; run it once more (or run it as a Databricks Job, which
   restarts automatically) and the new column appears — with anything that doesn't
   fit the current schema captured in `_rescued_data`.
6. **(Optional) See the same-name behaviour.** Re-upload `day1.json` after editing a
   value (overwrite it in place) and run again — the file is skipped, exactly as the
   local proof's last round shows.

The output from steps 3–6 is the real Auto Loader output to capture.

## What if the same file re-lands with edits?

Short answer: by default Auto Loader **ignores it** — and that's usually what you
want.

Auto Loader ingests each file **exactly once, by its path**. If a file you've already
processed re-lands under the same name with edited records and a few new ones, the
default (`cloudFiles.allowOverwrites = false`) skips it — the edits and the new
records are **not** picked up. Databricks also notes that if a file is overwritten it
can't guarantee which version would be processed, which is why it recommends treating
landed files as **immutable**.

The local proof shows exactly this in its last round: `day1.json` re-lands with
`sale_id 1`'s price changed to 900000 and a new `sale_id 6`, and the run processes
**0** rows — the target still shows the old price and no new row.

If you genuinely need modified files re-read, set `cloudFiles.allowOverwrites = true`.
But know what it does: Auto Loader re-reads the **entire** file — it's *not* a content
diff — and the stream appends, so you get **duplicate** rows for the records that
didn't change, and you have to dedupe them yourself. (In file-notification mode it can
even ingest the same file twice from a timestamp mismatch.)

**The right way to apply updates** isn't overwriting a file — it's landing updates as
**new** files and applying them with a Delta `MERGE` inside `foreachBatch`, keyed on a
business id. Auto Loader delivers the rows; MERGE turns them into updates + inserts:

```python
from delta.tables import DeltaTable

def upsert(microbatch_df, batch_id):
    target = DeltaTable.forName(spark, "main.bronze.suburb_sales")
    (target.alias("t")
        .merge(microbatch_df.alias("s"), "t.sale_id = s.sale_id")
        .whenMatchedUpdateAll()
        .whenNotMatchedInsertAll()
        .execute())

(spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "json")
    .option("cloudFiles.schemaLocation", schema_location)
    .load(source_path)
 .writeStream
    .foreachBatch(upsert)
    .option("checkpointLocation", checkpoint)
    .trigger(availableNow=True)
    .start())
```

That's the standard bronze→silver shape: Auto Loader for incremental *file* ingestion,
`MERGE` for row-level *updates*.

## Files

```
databricks-auto-loader/
├── databricks-auto-loader-README.md   this file
├── auto_loader_databricks.py   the REAL Auto Loader (cloudFiles) — runs on Databricks
├── run.sh                      bash run.sh → the local, open-source proof
├── local_incremental_demo.py   the proof: checkpoint → only new files each run
├── requirements.txt            Python dependency (pyspark)
├── config/
│   ├── day1.json  day2.json  day3.json   the sample "drops" (committed inputs)
│   └── day1_edited.json                  day1 re-landed with an edit + a new record
└── output/
    └── output.txt              captured output from the local proof
```

---

*The local output was produced by running `bash run.sh` on PySpark 4.2 / Java 21.*
