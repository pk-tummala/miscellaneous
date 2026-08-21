# Conditional salting: salt only the skewed key, not the whole table

**In one line:** plain salting fixes a skewed join by salting every row and replicating the
other side across all N salts - but that fans out the *entire* small side N times, even for
the thousands of keys that were never skewed. Conditional salting salts **only the keys that
are actually skewed**; normal keys pass through untouched. Same fix, a fraction of the
shuffle.

---

## Run it

```bash
bash run.sh
```

Needs `python3`, `python3-venv`, and a JDK. On WSL Ubuntu 24.04:
`sudo apt install -y default-jdk python3-venv`. First run installs PySpark into a local
`.venv`. Captured output is in [`output/output.txt`](output/output.txt).

## The scenario

`orders` (2,000,000 rows) joined to a `customers` dimension (4,001 rows) on `customer_id`.
One big account, `ACME_CORP`, owns **1,600,000 orders (80%)**. A join shuffles every row of
a key to one task, so all 1,600,000 land on a single task - the straggler. (A join skews
because it has no map-side pre-aggregation; a plain `groupBy(sum/count)` would not need
salting - Spark pre-aggregates that for you.)

## Step 1: find the skewed keys dynamically

Don't hardcode them - skew moves over time. Flag any key above a row-count threshold:

```python
THRESHOLD = 10000
skewed = [r["customer_id"] for r in
          orders.groupBy("customer_id").count().filter(f"count > {THRESHOLD}").collect()]
# ['ACME_CORP']
```

## Plain salting: the sledgehammer

Salt every row, and replicate the whole dimension across all N salts:

```python
N = 16
o = orders.withColumn("salt", F.floor(F.rand() * N))                          # every order
c = customers.withColumn("salt", F.explode(F.array(*[F.lit(i) for i in range(N)])))  # every customer x N
o.join(c, ["customer_id", "salt"])
```

It works - `ACME_CORP` spreads across 16 tasks. But the dimension just went from **4,001 to
64,016 rows** (16x). You fixed one hot key and taxed all 4,000 normal customers to do it.

## Conditional salting: the scalpel

Salt only the skewed keys; give everyone else a fixed salt of `0`. On the small side,
replicate only the skewed rows; keep the normal rows as-is with salt `0`:

```python
# big side: skewed keys get a random salt, everyone else gets 0
o = orders.withColumn(
    "salt",
    F.when(F.col("customer_id").isin(skewed), F.floor(F.rand() * N))
     .otherwise(F.lit(0)))

# small side: normal rows keep salt = 0; only skewed rows fan out across N salts
c = (customers.filter(~F.col("customer_id").isin(skewed)).withColumn("salt", F.lit(0))
     .unionByName(
        customers.filter(F.col("customer_id").isin(skewed))
                 .withColumn("salt", F.explode(F.array(*[F.lit(i) for i in range(N)])))))

o.join(c, ["customer_id", "salt"])
```

Now the dimension is **4,016 rows** (+15), not 64,016 - a **16x smaller fan-out of the
small side** - and `ACME_CORP` still spreads across 16 tasks. Same join, same 2,000,000 rows
out.

## The contrast (from the run)

| | dimension shuffled | busiest task | join result |
| --- | --- | --- | --- |
| Plain join (no salt) | 4,001 | 1,600,000 (straggler) | 2,000,000 |
| Normal salting | 4,001 -> **64,016** (16x) | 100,000 (fixed) | 2,000,000 |
| Conditional salting | 4,001 -> **4,016** (+15) | 100,000 (fixed) | 2,000,000 |

Both salting versions kill the straggler equally. Conditional gets there without bloating
the dimension - only the hot key pays.

**One honest caveat:** the *big* side (the 2,000,000 orders) is shuffled the same in both -
only the *small* side changes. In this demo the total shuffle is only about 3% less, because
the dimension is tiny. The win scales with the dimension: the bigger it is, the more normal
salting wastes by replicating it N times. If the dimension is small enough to broadcast,
skip salting entirely.

## How the 2,000,000 rows land on the tasks

Spark shuffles into `spark.sql.shuffle.partitions` reduce tasks - **default 200**, but this
demo sets it to **64** (with AQE off) so the per-task counts are exact and reproducible.
Each row is sent to `hash(customer_id, salt) % 64`. (With AQE on, Spark starts from that
number and coalesces small partitions at runtime toward
`spark.sql.adaptive.advisoryPartitionSizeInBytes`, default 64 MB - so the effective count
can be fewer.) Shuffling only *moves* rows - the count is
conserved:

```
2,000,000 orders
  ACME_CORP      1,600,000  ->  salt 0..15  ->  16 buckets x 100,000  = 1,600,000
  4,000 normals    400,000  ->  salt 0      ->  4,000 keys x ~100      =   400,000
                                                               total   = 2,000,000
```

- **Naive join:** ACME's 1,600,000 rows all hash to one task -> busiest task ~1,600,000 (the
  straggler); the other 63 tasks share the 400,000 normal rows (~6,250 each).
- **Salted join:** ACME's 16 buckets spread across ~16 tasks -> busiest task ~107,000 (one
  100,000 bucket plus the few normal rows that hashed to the same task).
- **Either way, all 64 tasks sum to exactly 2,000,000** - salting changes how *evenly* the
  rows are spread, not how *many* there are.

## The details that matter

- **Find skewed keys dynamically**, don't hardcode - the threshold (here 10,000 rows) adapts
  as the data changes.
- **Real salt is random.** The demo salts on `order_id % N` so the numbers reproduce
  exactly; in production use `F.floor(F.rand() * N)`.
- **If the dimension is small enough, just broadcast it** (`F.broadcast(customers)`) - no
  shuffle, no skew, no salting. Conditional salting is for when the dimension is too big to
  broadcast but only a few keys are hot.
- **AQE can do this for you.** On Spark 3+, Adaptive Query Execution's skew-join splits a
  join partition over `skewedPartitionFactor` (default 5) times the median **and**
  `skewedPartitionThresholdInBytes` (default 256 MB), and replicates the other side.
  Conditional salting is the manual lever when you want explicit control. This demo sets
  `spark.sql.adaptive.enabled=false` (and disables broadcast) so you see the raw behaviour.

## Files

```
data-skew-salting/
|-- data-skew-salting-README.md   this file
|-- run.sh   bash run.sh -> normal vs conditional salting on a skewed join
|-- requirements.txt   Python dependency (pyspark)
|-- skew_salting.py    the demo
|-- output/
    |-- output.txt   captured expected output
```

---

*Run on PySpark 4.2 (`local[4]`), deterministic and byte-identical across runs.*
