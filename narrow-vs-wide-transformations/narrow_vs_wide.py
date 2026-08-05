"""
narrow_vs_wide.py
-----------------
Which Spark transformations shuffle, and which don't — shown with real
`explain()` plans. A shuffle shows up in the physical plan as an "Exchange".
Narrow transformations have none; wide ones do.

Runs on local Spark, no cluster. The data is tiny and its values don't matter —
what matters is the shape of the plan. We load the sample rows into 4 partitions
so the wide transformations genuinely have data to move around.
"""
import json, os, re
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, sum as _sum

BASE = os.path.dirname(os.path.abspath(__file__))
rows = [(r["region"], r["product"], r["amount"])
        for r in json.load(open(os.path.join(BASE, "config", "sales.json")))]

spark = (SparkSession.builder.appName("narrow-vs-wide").master("local[2]")
         .config("spark.ui.enabled", "false")
         .config("spark.sql.shuffle.partitions", "4")
         .getOrCreate())
spark.sparkContext.setLogLevel("ERROR")

# 4 partitions, and it's a plain Scan (no Exchange in the base itself)
df = spark.createDataFrame(spark.sparkContext.parallelize(rows, 4),
                           ["region", "product", "amount"])

def plan(d):
    return d._jdf.queryExecution().executedPlan().toString()

def shuffles(d):
    return "Exchange" in plan(d)

def clean(d, keep=6):
    # normalise the non-deterministic plan_id=NNN so the output is repeatable
    txt = re.sub(r'plan_id=\d+', 'plan_id=*', plan(d))
    lines = [l for l in txt.splitlines() if l.strip() and "isFinalPlan" not in l]
    return "\n".join("     " + l for l in lines[:keep])

bar = "=" * 72
print(bar)
print("NARROW vs WIDE TRANSFORMATIONS - does it shuffle?")
print("A shuffle moves data across the cluster. It is the expensive part,")
print("and in the physical plan it shows up as an \"Exchange\".")
print(bar)

narrow = [("filter",     df.filter(col("amount") > 100)),
          ("select",     df.select("region", "amount")),
          ("withColumn", df.withColumn("gst", col("amount") * 0.1)),
          ("union",      df.union(df)),
          ("coalesce",   df.coalesce(2))]
wide   = [("groupBy + agg", df.groupBy("region").agg(_sum("amount"))),
          ("distinct",      df.select("region").distinct()),
          ("orderBy",       df.orderBy("amount")),
          ("join",          df.join(df.select("region").distinct(), "region")),
          ("repartition",   df.repartition(8))]

print("\nNARROW - each input partition feeds one output, no shuffle:")
for name, d in narrow:
    print(f"  {name:14s} {'shuffle' if shuffles(d) else 'no shuffle'}")
print("\nWIDE - needs a shuffle (data crosses the network):")
for name, d in wide:
    print(f"  {name:14s} {'shuffle' if shuffles(d) else 'no shuffle'}")

print("\n" + "-" * 72)
print("See it in the plan - the wide one has an Exchange, the narrow one doesn't:")
print("\n  filter (narrow):")
print(clean(df.filter(col("amount") > 100), keep=3))
print("\n  groupBy (wide):")
print(clean(df.groupBy("region").agg(_sum("amount")), keep=6))

print("\n" + "-" * 72)
print("THE TRAP - these two look almost identical, but only one shuffles:")
print("\n  df.coalesce(2)    (narrow - just merges partitions in place)")
print(clean(df.coalesce(2), keep=2))
print("\n  df.repartition(2) (wide - a full shuffle)")
print(clean(df.repartition(2), keep=2))

print("\n" + bar)
print("The rule: if it shuffles, Spark writes to disk and moves data over the")
print("network - that's a stage boundary, and it's what makes jobs slow at scale.")
print("Narrow chains pipeline together for free. Everything else is detail.")
print(bar)
spark.stop()
