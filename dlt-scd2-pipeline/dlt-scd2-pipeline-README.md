# Native SCD Type 2 with AUTO CDC - and the one decision that makes or breaks it

**In one line:** Databricks **AUTO CDC** (formerly `APPLY CHANGES` / `apply_changes`) turns SCD
Type 2 into a declaration - `create_auto_cdc_flow(..., stored_as_scd_type=2)` and it handles the
start/end dating, the versioning, the upserts. The one decision that matters is **`sequence_by`**:
it must reflect *when the change happened at the source*, not *when your pipeline ingested the row*.
Get that wrong and it silently builds a wrong dimension.

**The API removes the plumbing; it does not remove the judgment.** AUTO CDC deletes the MERGE, the
effective-dating and the version-closing you used to hand-write - but it cannot know which of your
columns reflects true change order. Picking that column is where experience comes in.

> AUTO CDC replaces the APPLY CHANGES APIs (same signature); Databricks recommends the new name.

---

## The trap: which column decides "latest"

A CDC feed is a log of *changes*, so a key legitimately appears once per change - `order_id=1` here goes
`PENDING` (source 09:00) then `SHIPPED` (source 10:00). AUTO CDC keeps the latest as `current` using
`sequence_by`, so the only decision that matters is **which column tells it the true order**.

The source's own updated/created timestamp is the ground truth. Your ingestion time is not even a
source column - `ingested_at` is stamped by *your* pipeline on arrival (Auto Loader's
`_metadata.file_modification_time`, or a `current_timestamp()` you add). It is convenient, which is
exactly the trap. A feed's delivery order is not guaranteed to match the source's change order - a
feed's delivery order is not guaranteed to match the source's change order (partitioned/parallel
readers, retries and reprocessing all reorder). Sequence by ingestion time and, the moment delivery
and source order disagree, the wrong record wins `current` - with no error.

Demo feed - `order_id=1`'s two changes are **delivered out of source order** (the older `PENDING`
is ingested *after* the newer `SHIPPED`):

```
naive   (sequence_by = ingested_at):        order_id=1 -> PENDING   (won on arrival order)   WRONG
guarded (sequence_by = order_updated_at):   order_id=1 -> SHIPPED   (won on source order)    CORRECT
```

You do **not** need a special sequence number - almost every feed has a created/updated timestamp.
Just make sure it is granular enough to be monotonic per key (a full timestamp or a version/LSN,
not a coarse date). Picking that column is the whole game: it is the "is the source newer than my
current row?" check you would otherwise hand-write in a MERGE - AUTO CDC does it for you once
`sequence_by` points at the right clock.

## The checks and balances

Same `create_auto_cdc_flow`, four guardrails:

1. **`sequence_by` the source's updated/created timestamp** (or a real version/LSN), granular enough
   to be monotonic per key - never ingestion time. This is how AUTO CDC knows an out-of-order record
   is old and must not become `current`.
2. **Expectations on the feed** - `@dlt.expect_all_or_drop({"valid_key": "order_id IS NOT NULL",
   "valid_timestamp": "order_updated_at IS NOT NULL"})` drops records that cannot be keyed or ordered
   before they can corrupt the dimension (the drop count shows in the pipeline).
3. **`track_history_except_column_list=["ingested_at"]`** - do not spawn a new SCD2 version on
   ingestion noise.
4. **`apply_as_deletes`** - close deleted keys out of `current` instead of leaving them live.

```python
dlt.create_auto_cdc_flow(
    target="dim_orders_guarded", source="cdc_clean", keys=["id"],
    sequence_by=col("order_updated_at"),               # source event time, not arrival time
    apply_as_deletes=expr("op = 'DELETE'"),
    stored_as_scd_type=2,
    track_history_except_column_list=["ingested_at"],
)
```

## Run it (one click, self-provisioning, idempotent)

```bash
bash run.sh            # uses the vic-dev profile by default (DATABRICKS_PROFILE=<name> to override)
```

Assumes **only** the Databricks CLI + your connection profile. `run.sh` provisions everything else
and is fully re-runnable:

1. resolves or **creates** a small serverless SQL warehouse (`scd2_demo_wh`, 2X-Small, auto-stop 10m),
2. **creates the catalog and schema and grants** the needed privileges - all idempotent,
3. seeds the CDC feed (order_id=1's changes delivered out of source order + a null-key row) into
   `dlt_scd2_demo.demo.cdc_source`,
4. `bundle deploy` + `bundle run scd2_pipeline --full-refresh-all` - a clean, reproducible build of
   `dim_orders_naive`, `dim_orders_guarded` and `scd2_contrast`,
5. queries `scd2_contrast` and prints the current row of each dimension - the contrast.

All output is captured to `output/output.txt`. (`CREATE CATALOG` uses the metastore privilege your
`vic-dev` principal already has for creating catalogs; everything else the demo grants itself.)

## The proof

`scd2_contrast` (current rows, `__END_AT IS NULL`) after one run:

```
dimension           order_id  order_status  order_updated_at
guarded (checks)    1         SHIPPED       2026-09-01 10:00:00   <- correct: newest source time won
guarded (checks)    2         PENDING       2026-09-01 09:10:00
naive (no checks)   1         PENDING       2026-09-01 09:00:00   <- wrong: late arrival won on ingested_at
naive (no checks)   2         PENDING       2026-09-01 09:10:00
naive (no checks)   NULL      GARBAGE       2026-09-01 09:20:00   <- null-key row leaked in
```

## Idempotent by design

The real payoff of sequencing by `order_updated_at` is idempotency. Bronze accumulates changes; when
silver runs it processes whatever is pending as one batch - including any late-arriving old record (a
backfill, a retry, or a change that landed at 11:05 after silver already ran). Because AUTO CDC orders
by the source's change time, an older record can never overwrite a newer `current` - it lands in
history. Re-run silver as many times as you like and the dimension is identical. Sequence by
`ingested_at` and that same reprocess silently flips `current` to the stale value - not idempotent.

## Teardown

```sql
DROP CATALOG IF EXISTS dlt_scd2_demo CASCADE;
```
```bash
databricks warehouses delete <warehouse_id> -p vic-dev   # the scd2_demo_wh that run.sh created
```

## Files

```
dlt-scd2-pipeline/
|-- databricks.yml               the bundle (serverless DLT pipeline, one workspace)
|-- resources/pipeline.yml       the pipeline resource
|-- src/scd2_pipeline.py         AUTO CDC: dim_orders_naive vs dim_orders_guarded + scd2_contrast
|-- run.sh                       seed -> deploy -> run -> query the contrast -> output/output.txt
|-- output/output.txt           captured run output
```

---

*Verified against the current Databricks docs: `create_auto_cdc_flow` (replaces `apply_changes`),
`stored_as_scd_type=2` with `__START_AT`/`__END_AT`, `sequence_by` handling out-of-order and
late-arriving events (must reflect true source order), `track_history_except_column_list`,
`apply_as_deletes`, `@dlt.expect_all_or_drop`, and the serverless requirement for AUTO CDC.*
