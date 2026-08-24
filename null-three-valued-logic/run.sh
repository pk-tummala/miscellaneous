#!/usr/bin/env bash
#==============================================================================
# run.sh - NULL is not a value: the NOT IN trap and three-valued logic (DuckDB).
# Requires: python3 + python3-venv. First run installs duckdb into a local .venv.
#           No account, no server - DuckDB is embedded.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
. .venv/bin/activate
python3 -c "import duckdb" 2>/dev/null || pip install -q duckdb
python3 run_demo.py
