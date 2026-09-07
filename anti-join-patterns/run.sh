#!/usr/bin/env bash
#==============================================================================
# run.sh - NOT EXISTS vs anti-join vs NOT IN: three ways to ask "what's missing".
# Same answer, until a NULL - then only NOT EXISTS and LEFT JOIN/IS NULL are right.
# Runs anywhere (needs only python3; auto-installs duckdb). Idempotent (in-memory DB).
# Captures this run's output to output/output.txt.
#==============================================================================
set -o pipefail
cd "$(dirname "$0")"
OUT="output/output.txt"; mkdir -p output

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
# idempotent: install duckdb only if it is not importable
if ! python3 -c "import duckdb" 2>/dev/null; then
  echo "installing duckdb ..."
  python3 -m pip install --quiet duckdb 2>/dev/null \
    || python3 -m pip install --quiet --break-system-packages duckdb 2>/dev/null \
    || python3 -m pip install --quiet --user duckdb
fi

{ python3 anti_join_patterns.py; } 2>&1 | tee "$OUT"
echo ""
echo "Captured to $OUT"
