# scd2_pipeline.py
# Native SCD Type 2 with Databricks AUTO CDC (formerly APPLY CHANGES / apply_changes).
# A CDC feed is a log of CHANGES, so an order_id appears once per change. AUTO CDC keeps the latest
# as current using sequence_by - so the only question that matters is which column tells it the true
# order. Use the SOURCE's change timestamp (order_updated_at), not your ingestion time.
# The API removes the hand-written plumbing; choosing this column is where experience comes in.
import dlt
from pyspark.sql.functions import col, expr

SOURCE = "dlt_scd2_demo.demo.cdc_source"   # from source: order_id, order_status, order_updated_at, operation
                                           # + ingested_at (added by the pipeline on arrival; pre-set here for a reproducible demo)

# =============================================================================================
# NAIVE - sequence by INGESTION time (when our pipeline saw the row). The trap.
# =============================================================================================
@dlt.view
def cdc_raw():
    return spark.readStream.table(SOURCE)

dlt.create_streaming_table("dim_orders_naive")
dlt.create_auto_cdc_flow(
    target       = "dim_orders_naive",
    source       = "cdc_raw",
    keys         = ["order_id"],
    sequence_by  = col("ingested_at"),        # WRONG: arrival order. When delivery order != source order, the wrong change wins.
    stored_as_scd_type = 2,
)

# =============================================================================================
# GUARDED - sequence by the ORDER's own updated timestamp (every feed has one) + input checks.
# =============================================================================================
@dlt.table
@dlt.expect_all_or_drop({
    "valid_key":       "order_id IS NOT NULL",
    "valid_timestamp": "order_updated_at IS NOT NULL",   # no source time = cannot order it = reject it
})
def cdc_clean():
    return spark.readStream.table(SOURCE)

dlt.create_streaming_table("dim_orders_guarded")
dlt.create_auto_cdc_flow(
    target       = "dim_orders_guarded",
    source       = "cdc_clean",
    keys         = ["order_id"],
    sequence_by  = col("order_updated_at"),               # RIGHT: when the order changed at the SOURCE, not when we ingested it.
    apply_as_deletes = expr("operation = 'DELETE'"),      # close deleted orders out of "current"
    stored_as_scd_type = 2,
    track_history_except_column_list = ["ingested_at"],    # do not spawn a version on ingestion noise
)

# =============================================================================================
# The contrast: the CURRENT row (__END_AT IS NULL) of each dimension, side by side.
# =============================================================================================
@dlt.table
def scd2_contrast():
    naive = (dlt.read("dim_orders_naive").where("__END_AT IS NULL")
             .selectExpr("'naive (no checks)' AS dimension", "order_id", "order_status", "order_updated_at"))
    guarded = (dlt.read("dim_orders_guarded").where("__END_AT IS NULL")
               .selectExpr("'guarded (checks)' AS dimension", "order_id", "order_status", "order_updated_at"))
    return naive.unionByName(guarded)
