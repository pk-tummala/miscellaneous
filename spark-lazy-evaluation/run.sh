#!/usr/bin/env bash
#==============================================================================
# run.sh - Spark lazy evaluation & actions: transformations plan, actions execute.
# Runs anywhere with python3 + a JRE (Java 8/11/17/21); auto-installs pyspark. Local mode.
# Idempotent (fresh SparkSession each run). Captures this run's output to output/output.txt.
#==============================================================================
set -o pipefail
cd "$(dirname "$0")"
OUT="output/output.txt"; mkdir -p output

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
java -version >/dev/null 2>&1 || { echo "A JRE (Java 8/11/17/21) is required for PySpark" >&2; exit 1; }
if ! python3 -c "import pyspark" 2>/dev/null; then
  echo "installing pyspark (first run only) ..."
  python3 -m pip install --quiet pyspark 2>/dev/null \
    || python3 -m pip install --quiet --break-system-packages pyspark
fi

# JVM/Spark startup logs go to stderr; the demo prints everything meaningful to stdout
python3 lazy_evaluation.py 2>/dev/null | tee "$OUT"
echo ""
echo "Captured to $OUT"
