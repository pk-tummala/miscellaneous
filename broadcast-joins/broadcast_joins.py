"""
Broadcast joins: stop shuffling the big side.
A regular (sort-merge) join shuffles BOTH tables across the network by the join
key. If one side is small enough, broadcast it to every executor instead - then
the big side never moves. We read the physical plan before and after to prove it.
Runs locally on a tiny dataset; the mechanics are identical at scale.
"""
import re
from pyspark.sql import SparkSession
from pyspark.sql.functions import broadcast, col, concat, lit

spark = (SparkSession.builder.master("local[2]").appName("broadcast-joins")
         .config("spark.sql.shuffle.partitions", "8")
         .config("spark.sql.adaptive.enabled", "false")   # show the static plan clearly
         .getOrCreate())
spark.sparkContext.setLogLevel("ERROR")

# a large fact and a small dimension, joined on dim_id
fact = spark.range(0, 2_000_000).select(col("id").alias("order_id"), (col("id") % 200).alias("dim_id"))
dim  = spark.range(0, 200).select(col("id").alias("dim_id"), concat(lit("region_"), col("id")).alias("region"))

def key_plan(df):
    """Pull the join-relevant operators out of the physical plan, in tree order,
    with volatile ids normalised so the output is stable run to run."""
    s = df._jdf.queryExecution().executedPlan().toString()
    out = []
    for ln in s.splitlines():
        if any(k in ln for k in ("SortMergeJoin", "BroadcastHashJoin", "Exchange ", "BroadcastExchange")):
            ln = re.sub(r"#\d+L?", "", ln)                 # drop expression ids  (dim_id#2L -> dim_id)
            ln = re.sub(r",?\s*\[plan_id=\d+\]", "", ln)    # drop plan ids
            ln = re.sub(r"^\s*[:+\-]*\s*", "", ln)          # drop tree-branch glyphs
            out.append(ln.strip())
    return out

bar = "=" * 74
print(bar); print("BROADCAST JOINS - stop shuffling the big side"); print(bar)
print("\nfact  = 2,000,000 rows   (the big side)")
print("dim   =       200 rows   (the small side)")
print("join  = fact JOIN dim ON dim_id")

print("\n" + "-"*74)
print("1. Regular join (dimension above the broadcast threshold) -> SORT-MERGE")
print("-"*74)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", -1)   # force the sort-merge baseline
smj = fact.join(dim, "dim_id")
for l in key_plan(smj): print("   " + l)
print("\n   Both sides get an Exchange (hash-partitioned by dim_id) - i.e. BOTH")
print("   tables are shuffled across the network before they can be joined.")

print("\n" + "-"*74)
print("2. Broadcast the small side -> BROADCAST HASH JOIN")
print("-"*74)
print("   fact.join(broadcast(dim), \"dim_id\")")
bhj = fact.join(broadcast(dim), "dim_id")
for l in key_plan(bhj): print("   " + l)
print("\n   Only the dim gets a BroadcastExchange (sent to every executor). There")
print("   is NO Exchange on the fact - the 2,000,000-row side never moves.")

# prove both produce the same result
n_smj = smj.count(); n_bhj = bhj.count()
print("\n" + "-"*74)
print(f"3. Same answer either way: sort-merge {n_smj:,} rows == broadcast {n_bhj:,} rows")
print("-"*74)

print("\n" + bar)
print("A broadcast join trades network for memory: ship the small side once to")
print("each executor so the big side isn't shuffled. Spark auto-broadcasts under")
print("spark.sql.autoBroadcastJoinThreshold (default 10MB); broadcast() forces it.")
print("Ceiling: Spark cannot broadcast a relation larger than 8GB, and the small")
print("side is collected to the DRIVER first - so 'small' means small.")
print(bar)
spark.stop()
