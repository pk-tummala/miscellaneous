#!/usr/bin/env python3
"""Lazy evaluation & actions in Spark: transformations plan, actions execute - and without cache,
every action re-runs the whole lineage. Verified against the Spark RDD Programming Guide."""
import time, warnings
warnings.filterwarnings("ignore")
from pyspark.sql import SparkSession, functions as F
from pyspark.sql.types import LongType

spark = (SparkSession.builder.master("local[2]").appName("lazy")
         .config("spark.sql.shuffle.partitions", "4")
         .config("spark.ui.showConsoleProgress", "false")
         .config("spark.sql.execution.arrow.pyspark.enabled", "false")
         .config("spark.log.level", "FATAL")
         .getOrCreate())
spark.sparkContext.setLogLevel("FATAL")
sc = spark.sparkContext
# warm up JVM + Catalyst + codegen for the operators used below, so Part A times only plan construction
_ = spark.range(1).withColumn("sq", F.col("id")*F.col("id")).where("sq >= 0").count()

print("PART A - transformations plan; the action executes")
t = time.perf_counter()
plan = (spark.range(0, 20_000_000).withColumn("sq", F.col("id") * F.col("id")).where("sq % 2 = 0"))
t_build = (time.perf_counter() - t) * 1000
t = time.perf_counter(); n = plan.count(); t_act = (time.perf_counter() - t) * 1000
print(f"  build the transformation chain: {t_build:8.1f} ms   (nothing computed - just a plan)")
print(f"  the count() action ({n:,} rows): {t_act:8.1f} ms   (this is where the work happened)")
print()

print("PART B - without cache, every action re-runs the whole lineage")
acc = sc.accumulator(0)
@F.udf(LongType())
def counted(x):
    acc.add(1); return x
df2 = spark.range(0, 5).withColumn("sq", counted("id"))
print(f"  transform built, no action:     UDF ran {acc.value} times   (lazy - nothing ran)")
df2.collect(); print(f"  after action 1 (collect):       UDF ran {acc.value} times")
df2.collect(); print(f"  after action 2 (collect):       UDF ran {acc.value} times   <- re-ran the whole lineage")
print("  ... now with .cache():")
acc2 = sc.accumulator(0)
@F.udf(LongType())
def counted2(x):
    acc2.add(1); return x
df3 = spark.range(0, 5).withColumn("sq", counted2("id")).cache()
df3.collect(); print(f"  after action 1 (materialises):  UDF ran {acc2.value} times")
df3.collect(); print(f"  after action 2 (from cache):    UDF ran {acc2.value} times   <- served from cache, no re-run")
print()

print("PART C - a bug in a transformation surfaces only at the action")
@F.udf(LongType())
def boom(x):
    if x == 3:
        raise ValueError("row 3 is bad")
    return x
dfb = spark.range(0, 5).withColumn("b", boom("id"))
print("  built dfb with a faulty transformation - no error yet (lazy)")
try:
    dfb.collect()
    print("  (unexpected: no error)")
except Exception as e:
    print(f"  the action raised: {type(e).__name__}   <- the bug appeared only when the action ran")
print()

print("=" * 72)
print(" Transformations PLAN (instant, lazy).  Actions EXECUTE (do the work).")
print(" Reused DataFrame + multiple actions -> cache(), or you recompute the lineage each time.")
print("=" * 72)
spark.stop()
