# Narrow vs wide transformations: the one idea that explains your runtimes

**In one line:** some Spark transformations run without moving data across the cluster
(cheap); others must **shuffle** — redistribute data over the network — and that's what
makes a job slow. If it shuffles, it's expensive. Almost everything else is detail.

---

## Run it

```bash
bash run.sh
```

No cluster needed — it runs local Spark and prints real `explain()` plans.
Prerequisites on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv openjdk-17-jre-headless
```

First run creates a local `.venv` and installs PySpark. Captured output is in
[`output/output.txt`](output/output.txt).

## The two kinds of transformation

**Narrow** — each **input** partition feeds at most **one** output partition, so no
data crosses the network. Spark pipelines these together and runs them on each
partition independently. `filter`, `select`, `withColumn`, `union`, `coalesce`.
(Note `coalesce` merges several input partitions *into* one output — that's still
narrow, because the merge is local, with no shuffle. The defining property is "no
data redistributed across the network", not a one-to-one mapping.)

**Wide** — an output partition needs data from **many** input partitions, so Spark has
to **shuffle**: redistribute the data across the cluster so the right records land
together (all rows for a key, say). `groupBy`/`agg`, `join`, `distinct`, `orderBy`/
`sort`, `repartition`, and window functions.

The shuffle is the whole story. It writes data to disk, moves it over the network, and
serialises/deserialises it on the way — and it splits your job at a **stage boundary**
(number of stages ≈ number of shuffles + 1). On a laptop with ten rows you won't feel
it. On real data it's the difference between seconds and hours.

## See it in the plan

You don't have to guess whether something shuffles — the physical plan tells you. A
shuffle shows up as an **`Exchange`**. Run `df.explain()` and look for it.

A narrow op has none:

```
*(1) Filter (amount > 100)
+- *(1) Scan ExistingRDD[region, product, amount]
```

A wide op has one:

```
HashAggregate(keys=[region], functions=[sum(amount)])
+- Exchange hashpartitioning(region, 4)          <-- the shuffle
   +- HashAggregate(keys=[region], functions=[partial_sum(amount)])
      +- Scan ExistingRDD[region, product, amount]
```

The demo runs both and prints the plans so you can see the `Exchange` appear.

## The trap: two lines that look identical, one shuffles

This is the hook made concrete. `coalesce` and `repartition` both change the number of
partitions and read almost identically — but:

```
df.coalesce(2)      ->  Coalesce 2                          (narrow — merges in place)
df.repartition(2)   ->  Exchange RoundRobinPartitioning(2)  (wide — a full shuffle)
```

`coalesce` just merges existing partitions locally (no network); `repartition` reshuffles
everything. Reach for `coalesce` when you only need to *reduce* partitions — it's free.
Use `repartition` only when you actually need an even redistribution.

(One caveat worth knowing: `orderBy` on data Spark already knows is sorted — e.g. straight
off `spark.range()` — can have its shuffle optimised away entirely. That's why this demo
uses genuinely unsorted data, so the shuffle actually shows up.)

## Why it matters, and what to do

Because shuffles are the expensive part, most Spark tuning is really "do fewer, smaller
shuffles":

- **Filter early.** Cut rows *before* a `join` or `groupBy` so the shuffle moves less data.
- **Prefer narrow.** `coalesce` over `repartition` when reducing partitions; avoid
  needless `distinct`/`orderBy`.
- **Read the plan.** Count the `Exchange`s. Each one is a stage boundary you're paying for.

Get this one idea and Spark performance stops being mysterious: find the shuffles,
then make them fewer and smaller.

## Files

```
narrow-vs-wide-transformations/
├── narrow-vs-wide-transformations-README.md   this file
├── run.sh                 bash run.sh → prints which ops shuffle, with real plans
├── narrow_vs_wide.py      the demo
├── requirements.txt       Python dependency (pyspark)
├── config/
│   └── sales.json         ten sample rows (values don't matter — the plan shape does)
└── output/
    └── output.txt         captured output
```

---

*Every result was produced on PySpark 4.2 / Java 21.*
