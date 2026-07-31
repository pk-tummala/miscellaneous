"""
emr_serverless_job.py
---------------------
The PySpark job EMR Serverless runs for each new file. The Step Functions state
machine passes the s3:// path of the object that just landed as the first argument
(built from the EventBridge event's bucket name + object key).

This is ordinary Spark: it reads the one new file, does a light transform, and
appends it to the curated zone. It runs on EMR Serverless (or any Spark). The Spark
logic here is exercised locally in this repo's test; only the s3:// I/O needs AWS.
"""
import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, current_timestamp

source_path = sys.argv[1]                       # e.g. s3://<bucket>/incoming/listing.json
bucket      = source_path.split("/")[2]         # reuse the same bucket
target_path = f"s3://{bucket}/curated/listings/" # curated zone (then loaded to Snowflake)

spark = SparkSession.builder.appName("carsales-ingest").getOrCreate()

df = (
    spark.read.json(source_path)
    .withColumn("price", col("price").cast("long"))
    .withColumn("ingested_at", current_timestamp())
)

df.write.mode("append").parquet(target_path)
print(f"ingested {df.count()} row(s) from {source_path} -> {target_path}")
spark.stop()
