"""
Conditional salting: salt only the skewed key, not the whole table.

Plain salting fixes a skewed join by giving every row a random salt and replicating the
other side across all N salts. It works - but it fans out the ENTIRE small side N times,
even for the thousands of normal keys that were never skewed. That is wasted shuffle.

Conditional salting salts ONLY the keys that are actually skewed (found dynamically) and
replicates only those rows on the small side. Normal keys pass through untouched. Same
skew fix, a fraction of the overhead.

Scenario: orders (2,000,000 rows) joined to a customers dimension. One big account,
ACME_CORP, owns 80% of the orders - all of which land on one task in a plain join.

Deterministic, T1 (runs anywhere). The demo salts on order_id % N so the numbers reproduce
exactly; in production you'd use F.floor(F.rand() * N). A join skews because it has no
map-side pre-aggregation (a plain groupBy(sum/count) would not need salting - Spark
pre-aggregates that for you).
"""
from pyspark.sql import SparkSession, functions as F

spark = (SparkSession.builder.master("local[4]").appName("conditional-salting")
         .config("spark.sql.shuffle.partitions", "64")
         .config("spark.sql.adaptive.enabled", "false")
         .config("spark.sql.autoBroadcastJoinThreshold", "-1")
         .config("spark.ui.showConsoleProgress", "false").getOrCreate())
spark.sparkContext.setLogLevel("ERROR")

N = 16          # salt buckets
THRESHOLD = 10000  # a key with more rows than this is treated as skewed

# fact + dimension
whale = spark.range(0, 1_600_000).select(
    F.col("id").alias("order_id"), F.lit("ACME_CORP").alias("customer_id"),
    ((F.col("id") % 500) + 1).alias("amount"))
regular = spark.range(1_600_000, 2_000_000).select(
    F.col("id").alias("order_id"),
    F.concat(F.lit("cust_"), F.lpad((((F.col("id") - 1_600_000) % 4000) + 1).cast("string"), 5, "0")).alias("customer_id"),
    ((F.col("id") % 500) + 1).alias("amount"))
orders = whale.unionByName(regular)
customers = (orders.select("customer_id").distinct()
             .withColumn("segment", F.when(F.col("customer_id") == "ACME_CORP", "WHOLESALE").otherwise("RETAIL")))
total, dim_rows = orders.count(), customers.count()

bar = "=" * 74
print(bar); print("CONDITIONAL SALTING: salt only the skewed key, not the whole table"); print(bar)
print(f"orders ({total:,}) JOIN customers ({dim_rows:,}) ON customer_id.")

# 1. the skew
print("\n--- 1. The skew ---")
whale_orders = orders.filter("customer_id = 'ACME_CORP'").count()
print(f"  ACME_CORP owns {whale_orders:,} of {total:,} orders ({100*whale_orders//total}%).")
print(f"  A plain join puts all {whale_orders:,} on one task - the straggler.")

# 2. find skewed keys dynamically
skewed = [r["customer_id"] for r in
          orders.groupBy("customer_id").count().filter(f"count > {THRESHOLD}").collect()]
print(f"\n--- 2. Find skewed keys dynamically (count > {THRESHOLD:,}) ---")
print(f"  skewed keys: {skewed}")

# 3. NORMAL salting: salt every key, fan out the WHOLE dimension
o_norm = orders.withColumn("salt", F.col("order_id") % N)
c_norm = customers.withColumn("salt", F.explode(F.array(*[F.lit(i) for i in range(N)])))
norm_dim = c_norm.count()
norm_busy = o_norm.groupBy("customer_id", "salt").count().agg(F.max("count")).collect()[0][0]
norm_join = o_norm.join(c_norm, ["customer_id", "salt"]).count()
print("\n--- 3. NORMAL salting: salt EVERY key, fan out the WHOLE dimension ---")
print(f"  salt = order_id % {N} for all orders; explode ALL {dim_rows:,} customers x {N}")
print(f"  customers dimension: {dim_rows:,} -> {norm_dim:,} rows   ({norm_dim // dim_rows}x bigger)")
print(f"  busiest join task: {norm_busy:,} rows   (skew fixed)")

# 4. CONDITIONAL salting: salt ONLY the skewed keys
o_cond = orders.withColumn(
    "salt", F.when(F.col("customer_id").isin(skewed), F.col("order_id") % N).otherwise(F.lit(0)))
c_pass = customers.filter(~F.col("customer_id").isin(skewed)).withColumn("salt", F.lit(0))
c_fan = customers.filter(F.col("customer_id").isin(skewed)).withColumn("salt", F.explode(F.array(*[F.lit(i) for i in range(N)])))
c_cond = c_pass.unionByName(c_fan)
cond_dim = c_cond.count()
cond_busy = o_cond.groupBy("customer_id", "salt").count().agg(F.max("count")).collect()[0][0]
cond_join = o_cond.join(c_cond, ["customer_id", "salt"]).count()
print("\n--- 4. CONDITIONAL salting: salt ONLY the skewed keys ---")
print(f"  salt = order_id % {N} for skewed keys; salt = 0 for everyone else")
print(f"  explode ONLY skewed rows x {N}; the {dim_rows - 1:,} normal customers pass through")
print(f"  customers dimension: {dim_rows:,} -> {cond_dim:,} rows   (+{cond_dim - dim_rows})")
print(f"  busiest join task: {cond_busy:,} rows   (skew fixed)")

# 5. contrast
print("\n--- 5. Same fix, far less overhead ---")
print(f"  both fix the skew:    busiest task {whale_orders:,} -> {cond_busy:,}")
print(f"  dimension shuffled:   normal {norm_dim:,}  vs  conditional {cond_dim:,}  (~{round(norm_dim / cond_dim)}x smaller)")
print(f"  join result:          {norm_join:,} rows, identical: {norm_join == cond_join == total}")

print("\n" + bar)
print("Conditional salting: only the hot key pays. Normal keys pass through untouched.")
print(bar)
spark.stop()
