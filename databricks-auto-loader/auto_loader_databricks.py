# Databricks notebook source
# ============================================================================
# auto_loader_databricks.py  —  the REAL Auto Loader ingestion.
#
# This is Databricks code: it uses the `cloudFiles` source, which only exists on
# Databricks. It will NOT run on a plain laptop (that's what local_incremental_demo.py
# is for — it proves the checkpoint behaviour with open-source Spark). Paste this
# into a Databricks notebook or job to run it, and capture the real output there.
#
# Every option below is from the official Databricks Auto Loader documentation
# (docs.databricks.com / learn.microsoft.com, verified July 2026).
# ============================================================================

# --- paths (Unity Catalog Volumes) ------------------------------------------
# A volume path is  /Volumes/<catalog>/<schema>/<VOLUME>/<directories...>
# The segment right after the schema is the VOLUME NAME, and the volume must
# ALREADY EXIST — you cannot create it just by referencing it in a path (that's
# the UC_VOLUME_NOT_FOUND error). Everything DEEPER is ordinary directories: you
# upload files into the source one, and Auto Loader creates _schemas / _checkpoints
# itself. So point all three at sub-directories INSIDE one existing volume.
#
# Edit these three names to match your workspace. Here: catalog "main", schema
# "bronze", and an existing volume named "landing".
catalog = "main"
schema  = "bronze"
volume  = "landing"          # <-- must already exist in Unity Catalog

vol_root        = f"/Volumes/{catalog}/{schema}/{volume}"
source_path     = f"{vol_root}/suburb_sales/"           # upload your JSON files here
schema_location = f"{vol_root}/_schemas/suburb_sales/"   # Auto Loader creates this
checkpoint      = f"{vol_root}/_checkpoints/suburb_sales/"  # and this
target          = f"{catalog}.{schema}.suburb_sales"

# --- read: incremental discovery + schema inference/evolution ----------------
df = (
    spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "json")
    # schemaLocation turns on schema inference AND evolution. Auto Loader stores
    # the inferred schema under a _schemas dir here and tracks changes over time.
    .option("cloudFiles.schemaLocation", schema_location)
    # addNewColumns is the DEFAULT when you don't supply your own schema. Note the
    # real mechanism: when a NEW column appears, the stream STOPS with an
    # UnknownFieldException, writes the updated schema to schemaLocation, and picks
    # up the new column on the NEXT run. Run this as a Databricks Job so it restarts
    # automatically. (Type mismatches and other data that doesn't fit the current
    # schema are captured in the auto-added _rescued_data column instead of being
    # dropped — but new columns specifically trigger the exception, they are not
    # rescued.) Use "rescue" instead if you want the stream to never stop.
    .option("cloudFiles.schemaEvolutionMode", "addNewColumns")
    # OPTIONAL — file discovery. Directory listing is the default. For high volume,
    # switch to event-driven discovery so Auto Loader is NOTIFIED of new files
    # instead of listing the bucket. Uncomment to use file notification mode:
    # .option("cloudFiles.useNotifications", "true")
    # Note: Auto Loader ingests each file once, by its path, and assumes files are
    # immutable. A same-name file that's overwritten with edits is skipped by default
    # (cloudFiles.allowOverwrites=false). To APPLY updates, land new files and MERGE
    # on a key in foreachBatch — see the README's "same file re-lands" section.
    .load(source_path)
)

# --- write: checkpointed, exactly-once, batch-style --------------------------
# trigger(availableNow=True): discover everything waiting, process it (across as
# many micro-batches as needed), then stop — ideal for a scheduled job.
# The checkpoint records every processed file, so a restart resumes exactly where
# it left off and never re-reads an ingested file.
(
    df.writeStream
    .option("checkpointLocation", checkpoint)
    # let the Delta target accept the new columns schema evolution discovers
    .option("mergeSchema", "true")
    .trigger(availableNow=True)
    .toTable(target)
)

# COMMAND ----------

# Inspect exactly which files Auto Loader has discovered/processed (the state that
# lets it skip them next run) with the cloud_files_state table-valued function:
#   %sql SELECT * FROM cloud_files_state('/Volumes/main/bronze/landing/_checkpoints/suburb_sales/')
# and the target table:
#   display(spark.table(target))
