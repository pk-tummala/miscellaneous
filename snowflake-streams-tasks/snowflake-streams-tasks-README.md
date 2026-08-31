# A self-healing CDC pipeline in Snowflake (Streams + Tasks)

**The problem:** a Snowflake stream is a bookmark into Time Travel, not a durable queue. If it
isn't consumed within the source table's retention window, it goes **stale** and the unconsumed
change records are gone - and the usual cause is boring: the CDC task got suspended (tasks are
even *created* suspended) and nobody noticed.

**The fix, as a pipeline that heals itself:** run a tiny **watchdog task** that resumes the CDC
task whenever it stops. As long as the watchdog runs, the CDC task is never down longer than a
few minutes - far inside the retention window - so the stream can't drift to stale. No paging, no
manual recovery.

---

## The shape

```
orders  ->  orders_stream  ->  orders_cdc_task  ->  orders_target
                                   (WHEN has_data -> MERGE)
                                        ^
                                        | resume if stopped
                              cdc_watchdog_task --(hourly)--> heal_pipeline() --> RESUME orders_cdc_task
```

- **`orders_cdc_task`** - `WHEN SYSTEM$STREAM_HAS_DATA` + a MERGE. While it runs, the WHEN check
  keeps even an empty stream fresh, and the MERGE handles insert/update/delete.
- **`heal_pipeline()`** - one line that matters: `ALTER TASK orders_cdc_task RESUME` (a no-op if
  it's already running).
- **`cdc_watchdog_task`** - on a schedule, runs `heal_pipeline()`, which `RESUME`s `orders_cdc_task` if it
  has stopped. Runs **hourly** - far inside the 1-day window, costs next to nothing, and keeps the
  consumer alive so the stream never expires.

## One click

```bash
bash run.sh          # uses your default connection, or: SF_CONN=<connection> bash run.sh
```

`run.sh` (needs the Snowflake CLI `snow` with a connection in `~/.snowflake/config.toml`; tasks are serverless, nothing else to name):

The first thing it does is create a dedicated **warehouse** (`demo_wh`, XSMALL, 60s auto-suspend), **database** (`streams_tasks_demo`) and **schema** (`demo`) and `USE` them - so it never depends on your connection's default context. All idempotent.

1. builds the pipeline + the watchdog (`01_pipeline.sql`),
2. **breaks it** - suspends the CDC task, lets a change arrive - then **watches it heal**
   (`02_demo.sql`): the watchdog resumes the task, the backlog is processed, the stream stays fresh.

Everything is captured to `output/output.txt`.

## The proof

The demo prints the CDC task state before and after, and the stream's `STALE_AFTER`:

```
state_before   suspended          <- outage: consumer down, a change waiting
...  CALL heal_pipeline();  ...
state_after    started            <- watchdog brought it back
orders_target  1 | ACME | 100.00  <- the backlog was processed
orders_stream  stale=false  stale_after=2026-09-07 ...   <- never went stale
```

`STALE_AFTER` = last consume + max(`DATA_RETENTION_TIME_IN_DAYS`, `MAX_DATA_EXTENSION_TIME_IN_DAYS`),
visible via `SHOW STREAMS` - the exact moment the stream would expire if it stopped being consumed.

## Why it works

Staleness is a race: the stream expires if the offset falls outside retention. The watchdog wins
the race by keeping the gap small - a suspended CDC task is resumed within one watchdog cycle
(an hour), which is nothing against the stream's staleness deadline. In a real run `STALE_AFTER`
landed a week out - it's last-consume + max(retention, max_extension) = max(1, 7) = 7 days - so
the base retention is a cheap 1 day, but the stream can coast up to 7 days unconsumed. Keep retention comfortably above
your watchdog interval and worst-case restart, and the stream simply can't go stale.

## Cost

Cheap, and tuned to stay that way:

- **CDC task** - the `WHEN` guard means skipped runs don't spin up compute; you pay per-second
  only when there are real changes to MERGE. An idle pipeline is effectively free.
- **`cdc_watchdog_task`** - it runs its body unconditionally, so it's scheduled **hourly**, not every
  few minutes. Hourly is deep inside the 1-day window and costs almost nothing; a 5-minute
  watchdog would be roughly 12x the compute for zero extra safety.
- **Storage** - the stream is just an offset (free). The real line item is Time Travel on the
  source: `DATA_RETENTION_TIME_IN_DAYS = 1` is the base you always pay for (Standard-edition max; raise on Enterprise+);
  `MAX_DATA_EXTENSION_TIME_IN_DAYS = 7` only costs storage in the rare case every consumer is
  dead for days. Don't leave retention at the max "just in case".
- **Metadata** - the `SYSTEM$STREAM_HAS_DATA` / `ALTER TASK` calls run in the cloud-services
  layer, free under the 10%-of-warehouse-usage allowance.

## Teardown

```sql
DROP DATABASE  IF EXISTS streams_tasks_demo;   -- pipeline, stream, tasks, proc, target
DROP WAREHOUSE IF EXISTS demo_wh;
```

## Files

```
snowflake-streams-tasks/
|-- 01_pipeline.sql     source + stream + target + CDC task + heal_pipeline() + cdc_watchdog_task
|-- 02_demo.sql         suspend the CDC task, let it heal, prove recovery
|-- run.sh              one click: build, break, heal - captured to output/output.txt
|-- output/output.txt   captured run output
```
