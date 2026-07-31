"""
local_incremental_demo.py
-------------------------
A RUNNABLE, open-source proof of the ONE behaviour at the heart of Auto Loader:
a checkpoint means a re-run processes only the NEW files and never re-reads what
it already ingested.

This uses plain Spark Structured Streaming (the open-source foundation Auto Loader
is built on), so it runs on any laptop with no Databricks account. It deliberately
does NOT use `cloudFiles` — that is Databricks-only. What Auto Loader adds ON TOP
of what you see here is covered in auto_loader_databricks.py and the README:
scalable file discovery (incremental listing / file notifications) and schema
inference + evolution.
"""
import os, shutil
from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, LongType, StringType

BASE    = os.path.dirname(os.path.abspath(__file__))
CONFIG  = os.path.join(BASE, "config")
DATA    = os.path.join(BASE, "data")
LANDING = os.path.join(DATA, "landing")     # runtime scratch — the "lake" files land here
OUT     = os.path.join(DATA, "out")         # the target table (parquet)
CKPT    = os.path.join(DATA, "ckpt")        # the checkpoint — the memory of what's done

spark = (SparkSession.builder
         .appName("auto-loader-local-proof")
         .master("local[2]")
         .config("spark.ui.enabled", "false")
         .config("spark.sql.shuffle.partitions", "1")
         .config("spark.sql.warehouse.dir", os.path.join(DATA, "warehouse"))
         .getOrCreate())
spark.sparkContext.setLogLevel("ERROR")

# A fixed schema keeps this demo deterministic. (Auto Loader can INFER and EVOLVE
# the schema for you — that's one of the things it adds; see the README.)
schema = StructType([
    StructField("sale_id", LongType()),
    StructField("suburb",  StringType()),
    StructField("price",   LongType()),
])

def stage(drop):
    """Copy one committed sample file from config/ into the landing folder,
    simulating a new file arriving in the lake."""
    os.makedirs(LANDING, exist_ok=True)
    shutil.copy(os.path.join(CONFIG, drop), os.path.join(LANDING, drop))

def files_in_landing():
    return sorted(f for f in os.listdir(LANDING)) if os.path.isdir(LANDING) else []

def process_new_files():
    """Read whatever is in landing, write new rows to the target, and STOP
    (Trigger.AvailableNow = process everything available right now, then finish).
    The checkpoint records which files were processed so the next run skips them."""
    q = (spark.readStream.schema(schema).json(LANDING)
         .writeStream.format("parquet")
         .option("path", OUT)
         .option("checkpointLocation", CKPT)
         .trigger(availableNow=True)
         .start())
    q.awaitTermination()
    return sum(p["numInputRows"] for p in q.recentProgress)   # rows THIS run touched

def total_rows():
    try:
        return spark.read.parquet(OUT).count()
    except Exception:
        return 0

rounds = [
    ("day1.json", "Day 1: a file with two records lands"),
    ("day2.json", "Day 2: a new file lands (one record)"),
    ("day3.json", "Day 3: a new file lands (two records)"),
    (None,        "Re-run: no new file"),
]

bar = "=" * 70
print(bar)
print("CHECKPOINTED INGESTION - only new files are processed on each run")
print("(open-source Structured Streaming; the core idea Auto Loader is built on)")
print(bar)

for drop, title in rounds:
    if drop:
        stage(drop)
    print("\n" + "-" * 70)
    print(title)
    print("-" * 70)
    print("  files now in the lake :", ", ".join(files_in_landing()))
    processed = process_new_files()
    print("  rows processed THIS run:", processed)
    print("  total rows in target   :", total_rows())

print("\n" + bar)
print("Read the 'rows processed THIS run' column: after day 1 it was 2, then each")
print("run touched ONLY the newly-arrived file (1, then 2), and the final re-run")
print("with no new files processed 0 - the checkpoint skipped everything already")
print("ingested. The lake is never re-read.")

# ---------------------------------------------------------------------------
# Round 5: a file that was ALREADY processed re-lands under the SAME name, now
# with an edited record and a brand-new one. Auto Loader tracks files by PATH
# and ingests each once, so by default (cloudFiles.allowOverwrites = false) it
# ignores the re-landed file. The open-source file source behaves the same way.
# ---------------------------------------------------------------------------
print("\n" + "-" * 70)
print("Same filename re-lands - edited record + a new one")
print("-" * 70)
shutil.copy(os.path.join(CONFIG, "day1_edited.json"), os.path.join(LANDING, "day1.json"))
print("  overwrote day1.json: sale_id 1 price 850000 -> 900000, plus a new sale_id 6")
processed = process_new_files()
print("  rows processed THIS run:", processed)
print("  total rows in target   :", total_rows())
target = spark.read.parquet(OUT)
price1 = target.where("sale_id = 1").collect()[0]["price"]
has6   = target.where("sale_id = 6").count()
print(f"  sale_id 1 price in target: {price1}   <- the edit to 900000 was IGNORED")
print(f"  sale_id 6 rows in target : {has6}        <- the new record was IGNORED")

print("\n" + bar)
print("Same filename, edited contents -> processed 0. Auto Loader ingests a file")
print("once, by its path, and treats it as immutable. To re-read modified files set")
print("cloudFiles.allowOverwrites=true (it re-reads the WHOLE file and appends, so")
print("you dedupe yourself); to APPLY updates, land new files and MERGE on a key.")
print("See the README, and auto_loader_databricks.py for the cloudFiles version.")
print(bar)

spark.stop()
