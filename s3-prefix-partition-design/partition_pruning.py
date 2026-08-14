"""
Partition layout decides scan cost - before you write a single query.
Same rows written two ways: partitioned by dt (Hive-style dt=.../ folders) and flat
(dt is just a column). One filtered query on each. The partitioned layout lets the
engine PRUNE whole folders; the flat one must open everything. Local parquet here
mirrors exactly what S3 + Athena/Spark do at scale - you pay per byte scanned.
"""
import re, os, shutil
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, expr

spark = (SparkSession.builder.master("local[2]").appName("partition-pruning")
         .config("spark.sql.adaptive.enabled", "false")
         .config("spark.ui.showConsoleProgress", "false").getOrCreate())
spark.sparkContext.setLogLevel("ERROR")

BASE = "/tmp/s3_demo"
PART, FLAT = f"{BASE}/events_partitioned", f"{BASE}/events_flat"
shutil.rmtree(BASE, ignore_errors=True)

# 50,000 events across 10 days, 4 regions
df = (spark.range(0, 50000)
      .withColumn("dt", expr("date_format(date_add(to_date('2024-01-01'), cast(id % 10 as int)), 'yyyy-MM-dd')"))
      .withColumn("region", expr("concat('r', cast(id % 4 as int))"))
      .withColumn("amount", (col("id") * 7 % 1000).cast("double")))

df.repartition("dt").write.mode("overwrite").partitionBy("dt").parquet(PART)  # dt=.../ folders
df.coalesce(1).write.mode("overwrite").parquet(FLAT)                          # one flat file

def du(path):
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(path)
               for f in fs if f.endswith(".parquet"))

def scan_line(df):
    s = df._jdf.queryExecution().executedPlan().toString()
    line = [l for l in s.splitlines() if "FileScan" in l][0]
    line = re.sub(r"#\d+", "", line)  # strip volatile expression ids
    pf = re.search(r"PartitionFilters: (\[[^\]]*\])", line)
    dfl = re.search(r"DataFilters: (\[[^\]]*\])", line)
    return (pf.group(1) if pf else None), (dfl.group(1) if dfl else "[]")

Q = "dt = '2024-01-05'"
part = spark.read.parquet(PART).filter(Q)
flat = spark.read.parquet(FLAT).filter(Q)
days = sorted(d for d in os.listdir(PART) if d.startswith("dt="))

bar = "=" * 74
print(bar); print("PARTITION LAYOUT DECIDES SCAN COST - before you write a single query"); print(bar)
print("Same 50,000 rows, 10 days, written two ways. One query: WHERE dt = '2024-01-05'.")

print("\n--- Layout A: partitioned by dt  (Hive-style dt=.../ folders) ---")
print("  s3://bucket/events/")
print(f"    {days[0]}/   {days[1]}/   ...   {days[-1]}/     ({len(days)} folders)")
print("  (aws s3 ls s3://bucket/events/ would list exactly these dt= prefixes)")

print("\n--- Layout B: flat  (dt is just a column inside the files) ---")
print("  s3://bucket/events/")
print("    part-00000-*.parquet          (no folders to skip)")

print("\n--- What the query planner does with 'WHERE dt = 2024-01-05' ---")
pf_a, df_a = scan_line(part)
pf_b, df_b = scan_line(flat)
print(f"  A partitioned:  PartitionFilters: {pf_a}")
print(f"                  DataFilters:      {df_a}    -> prunes 9 of 10 folders, unread")
print(f"  B flat:         PartitionFilters: (none - dt is not a partition column)")
print(f"                  DataFilters:      {df_b}   -> opens every file, filters rows")

pa, fb = du(f"{PART}/dt=2024-01-05"), du(FLAT)
print("\n--- What each query actually READS (Athena bills per byte scanned) ---")
print(f"  A partitioned:  {pa:>7,} bytes   (dt=2024-01-05/ only - 1 of 10 days)")
print(f"  B flat:         {fb:>7,} bytes   (the whole table)")
print(f"  => partitioning scans ~{pa/fb*100:.0f}% of the data: ~{fb/pa:.0f}x less read, ~{fb/pa:.0f}x cheaper.")

print(f"\n  rows returned either way: {part.count()} (identical result, very different cost)")
print("\n" + bar)
print("Partition by the column you filter on most - usually a date. The folder")
print("layout someone chose months ago fixed this query's cost before you typed WHERE.")
print(bar)
spark.stop()
