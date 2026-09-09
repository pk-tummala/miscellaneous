# Lazy evaluation & actions - why your Spark job does nothing until it does everything

**In one line:** Spark transformations (`select`, `withColumn`, `filter`, `join`, `groupBy`...) are
**lazy** - they only build a plan. Nothing runs until an **action** (`count`, `collect`, `show`,
`write`...) forces it. Two consequences bite people: your timing is meaningless, and every action on
an uncached DataFrame **recomputes the whole lineage**. Run `bash run.sh` to watch it.

---

## How it actually works

- **Transformations** return a new DataFrame and just extend the logical plan. Instant. No job runs.
  `select`, `where`/`filter`, `withColumn`, `join`, `groupBy(...).agg(...)`, `orderBy`, `distinct`, `union`, `repartition`.
- **Actions** trigger a job: Spark analyzes and optimizes the plan (Catalyst), then executes it.
  `count`, `collect`, `show`, `take`, `first`/`head`, `foreach`, `toPandas`, `reduce`, and every
  `write`/`save`.

**One precise distinction: analysis is eager, execution is lazy.** Building a chain still *analyzes*
the plan as you go - schema and column resolution happen immediately. So a **wrong column name**
raises an `AnalysisException` the moment you write the transformation, before any action. What is
deferred is the **computation** of data. That is also why the two error types differ: a bad column
fails at build time (analysis), while a bad *value* or a throwing *UDF* fails at the action (execution)
- exactly what Part C shows.

## What goes wrong

**1. Your timing is a lie.** Building a chain of transformations returns in milliseconds because
nothing computed - it's just a plan. The time appears at the action. In the demo, building the chain
takes ~65 ms; the `count()` over 10M rows takes ~400 ms. If you "benchmark" the transformations, you
are timing plan construction, not work.

**2. Every action recomputes the whole lineage - unless you cache.** The same guide: *"By default,
each transformed RDD may be recomputed each time you run an action on it."* For DataFrames: multiple
actions on the same DataFrame **re-run the entire lineage each time** - re-reading the source, redoing
every transformation. The demo proves it with a counter inside a UDF:

```
transform built, no action:  UDF ran 0 times     (lazy)
after action 1 (collect):    UDF ran 5 times
after action 2 (collect):    UDF ran 10 times     <- the whole lineage ran again
```

The fix is `.cache()` (or `.persist()`): materialize once, reuse across actions.

```
with .cache():
after action 1 (materialises): UDF ran 5 times
after action 2 (from cache):   UDF ran 5 times     <- served from cache, no re-run
```

`.cache()` is itself **lazy** - it only *marks* the DataFrame; the cache is populated on the **first
action** (that is why the demo says "action 1 materialises"). Call an action once to fill it, or you
will still recompute. `DataFrame.cache()` uses `MEMORY_AND_DISK`; use `.persist(StorageLevel...)` for
other levels, and `.unpersist()` when you're done. Cache a DataFrame that is **reused across two or more actions** (or
in a loop, or an iterative algorithm) - not everything, since cache costs memory.

**A caveat on "the whole lineage": shuffle files can be reused.** The demo's lineage is map-only, so
each action genuinely re-runs everything (that is why the counter reached 10). But when a lineage
contains a **shuffle** (`groupBy`, `join`, `distinct`, `repartition`), Spark writes the shuffle output
to disk, and a later action can **skip re-computing the stages up to that shuffle** and reuse the
files. So the official wording is careful - *"may be recomputed"*: expect a full re-run for map-only
chains, and partial reuse when a shuffle sits in the middle. Either way, `.cache()` makes the reuse
explicit and complete.

**3. Bugs surface at the action, not where you wrote them.** A faulty transformation (a UDF that
throws, a bad value) raises nothing when you build it - the exception only appears when an action
executes the plan. "My code ran fine" can mean "my code never ran yet." In the demo, the bad
transformation is silent until `collect()` raises.

## A related trap: accumulators in transformations

The counter above doubled precisely *because* the lineage re-ran. That is also a warning: Spark only
guarantees an accumulator is updated **exactly once for updates performed inside actions**. For
updates inside **transformations**, a value "may be applied more than once if tasks or job stages are
re-executed" (retries, recompute, speculative execution). So don't trust a transformation-side
accumulator as an exact count - it is great for *illustrating* recomputation, not for metrics.

## The habits

- Don't benchmark transformations - benchmark the action, and look at the Spark UI's SQL/Jobs tab.
- Cache (or write to a checkpoint/table) any DataFrame you hit with **multiple actions**; `.unpersist()` after.
- Don't use `df.count()` as a "did it work?" check - it triggers a full pass and, uncached, re-runs later actions too.
- Expect errors at the action. When something "runs instantly", it probably hasn't run.

## Run it (one click, runs anywhere, idempotent)

```bash
bash run.sh
```

Needs `python3` + a JRE (Java 8/11/17/21); it auto-installs `pyspark` and runs a local-mode session
(deterministic, safe to re-run). The script tees its output to `output/output.txt`.

## Files

```
spark-lazy-evaluation/
|-- lazy_evaluation.py   Part A timing, Part B recompute-vs-cache (with a UDF counter), Part C deferred error
|-- run.sh               auto-installs pyspark, runs local Spark, tees to output/output.txt
|-- output/output.txt    captured real run
```