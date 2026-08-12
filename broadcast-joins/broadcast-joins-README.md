# Broadcast joins: stop shuffling the big side

**In one line:** a regular join shuffles *both* tables across the network by the join
key. If one side is small enough, broadcast it to every executor instead — then the big
side never moves. Read the physical plan and you can see the shuffle disappear.

---

## Run it

```bash
bash run.sh
```

Needs `python3`, `python3-venv`, and a JDK (PySpark runs on the JVM). On WSL Ubuntu
24.04: `sudo apt install -y default-jdk python3-venv`. First run installs PySpark into a
local `.venv`. Captured output is in [`output/output.txt`](output/output.txt).

## The default: sort-merge shuffles everything

`fact.join(dim, "dim_id")` on a dimension above the broadcast threshold plans as a
**sort-merge join**. Both inputs get an `Exchange hashpartitioning(dim_id)` — Spark
repartitions *both* tables by the join key so matching keys land on the same task, then
sorts and merges. That's two full shuffles across the network, on every run:

```
SortMergeJoin [dim_id], [dim_id], Inner
  Exchange hashpartitioning(dim_id, 8)   <- the fact is shuffled
  Exchange hashpartitioning(dim_id, 8)   <- the dim is shuffled
```

When the fact is huge, moving it across the cluster dominates the job.

## The fix: broadcast the small side

If one side fits in memory, you don't need to move the big side at all. Broadcast the
small side to every executor, and each executor joins its local slice of the big table
against the in-memory copy — a **broadcast hash join**:

```python
from pyspark.sql.functions import broadcast
fact.join(broadcast(dim), "dim_id")
```

```
BroadcastHashJoin [dim_id], [dim_id], Inner, BuildRight
  BroadcastExchange   <- only the dim is sent to each executor
```

The `BroadcastExchange` is on the dim only. There is **no Exchange on the fact** — the
big side never moves. Same result, one shuffle instead of two, and the expensive one
(the fact) eliminated.

## Three ways it triggers

1. **Automatically** — Spark broadcasts a side whose estimated size is under
   `spark.sql.autoBroadcastJoinThreshold` (**default 10 MB**).
2. **Manually** — the `broadcast()` hint forces it, even above the threshold (the demo
   uses this after disabling auto-broadcast, so you can see both plans).
3. **At runtime** — with Adaptive Query Execution (**on by default**), Spark can flip a
   sort-merge join to a broadcast one once it sees the *actual* post-filter size. (The
   demo turns AQE off so the static plan reads cleanly.)

## How big is too big — the honest part

Broadcasting isn't free; it trades **network for memory**, and "small" has hard edges:

- **The small side is collected to the *driver* first**, then shipped out. So a
  too-large broadcast runs the **driver** out of memory, not the executors — and it can
  trip `spark.driver.maxResultSize` (default **1 GB**) before that.
- **Every executor holds a full copy** in memory for the life of the join.
- **Hard ceiling: Spark cannot broadcast a relation larger than 8 GB** — over that it
  throws `Cannot broadcast the table that is larger than 8.0 GiB`, whatever you set the
  threshold to.

So should you broadcast a 2 GB dimension? Picture broadcasting as photocopying the small
table and handing a full copy to every worker machine, so the big table never has to be
moved. Those copies have to fit in memory — first on the **driver** (the machine that
coordinates the job and sends out the copies), then on every worker that holds one.

2 GB is big for that. Spark flatly refuses to broadcast anything over **8 GB**. And by
default the driver will only gather up to **1 GB** (`spark.driver.maxResultSize`), so a
2 GB broadcast fails until you raise that. It can still be the right call when
broadcasting 2 GB saves you from shuffling a fact table that's *far* bigger — but only
when your machines have the memory to spare, and only as a deliberate decision.

Rule of thumb when you're starting out: broadcast tables that are genuinely small — a few
MB up to tens of MB (Spark already does this for you automatically under 10 MB). For
anything bigger, check the memory first, or just let the normal sort-merge join do its
job.

## Files

```
broadcast-joins/
├── broadcast-joins-README.md   this file
├── run.sh               bash run.sh → prints the plan before and after broadcasting
├── requirements.txt     Python dependency (pyspark)
├── broadcast_joins.py   builds a fact + dim, shows both physical plans
└── output/
    └── output.txt       captured expected output
```

---

*Plans produced on PySpark 4.2 (`local[2]`). The join operators and `Exchange`/
`BroadcastExchange` nodes are read straight from the physical plan
(`queryExecution.executedPlan`); only volatile expression and plan ids are stripped so
the output is stable. The 10 MB default threshold and the 8 GB broadcast ceiling is Spark behaviour.*
