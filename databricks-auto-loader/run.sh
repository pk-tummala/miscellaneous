#!/usr/bin/env bash
#==============================================================================
# run.sh - runnable proof of Auto Loader's core behaviour, using OPEN-SOURCE
#          Spark Structured Streaming (no Databricks account needed).
#          Shows: a checkpoint means each re-run processes only NEW files and
#          never re-reads the lake.
# Requires: python3 + python3-venv + a JRE (Java 17+). PySpark is installed into
#           a local .venv on first run; system Python is untouched.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

command -v java >/dev/null 2>&1 || {
  echo "Java (JRE 17+) not found - PySpark needs it."
  echo "  WSL Ubuntu:  sudo apt update && sudo apt install -y openjdk-17-jre-headless"
  exit 1
}
if [ ! -d .venv ]; then
  echo "First run: creating a local .venv and installing PySpark (this can take a minute)..." >&2
  python3 -m venv .venv || { echo "Need python3-venv: sudo apt install -y python3-venv"; exit 1; }
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt || { echo "pip install failed (needs network)"; exit 1; }
fi

# fresh state each run so the demo is repeatable; Spark's JVM logs go to a
# disposable file so the console shows only the demo output.
rm -rf data
mkdir -p data
.venv/bin/python local_incremental_demo.py 2> data/spark.log
