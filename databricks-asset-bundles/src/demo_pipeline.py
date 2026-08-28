# demo_pipeline.py - a minimal Lakeflow (DLT) pipeline. It writes bronze + silver tables into the
# pipeline's target catalog.schema. Two developers whose pipelines share that target overwrite
# each other's bronze/silver - which is exactly the gotcha this repo is about.
import dlt
from pyspark.sql.functions import current_timestamp

@dlt.table(name="bronze", comment="Raw demo rows")
def bronze():
    return spark.range(5).withColumnRenamed("id", "row_id")

@dlt.table(name="silver", comment="Cleaned demo rows")
def silver():
    return dlt.read("bronze").withColumn("loaded_at", current_timestamp())
