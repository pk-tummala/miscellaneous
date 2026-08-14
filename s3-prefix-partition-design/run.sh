#!/usr/bin/env bash
#==============================================================================
# run.sh - how your folder/partition layout decides scan cost. Writes the same
#          rows partitioned by dt and flat, then runs one filtered query on each
#          and shows the plan (partition pruning vs full scan) and the bytes read.
# Requires: python3 + python3-venv + a JDK (PySpark runs on the JVM). First run
#           creates a local .venv and installs PySpark.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
command -v java >/dev/null 2>&1 || { echo "Java (JDK) is required for PySpark. Try: sudo apt install -y default-jdk"; exit 1; }
if [ ! -d .venv ]; then
  echo "First run: creating a local .venv and installing PySpark (a few minutes)..." >&2
  python3 -m venv .venv || { echo "Need python3-venv: sudo apt install -y python3-venv"; exit 1; }
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt || { echo "pip install failed (needs network)"; exit 1; }
fi
exec .venv/bin/python partition_pruning.py
