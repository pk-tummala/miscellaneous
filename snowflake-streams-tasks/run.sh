#!/usr/bin/env bash
#==============================================================================
# run.sh - one click: build the self-healing CDC pipeline, break it, watch it heal.
#
# Needs the Snowflake CLI (snow) with a connection in ~/.snowflake/config.toml.
# Uses your default connection, or pass one:   SF_CONN=<connection> bash run.sh
# Tasks are serverless, so nothing else to name. Writes a clean log to output/output.txt.
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CONN="${SF_CONN:-}"
CONN_ARG=""; [ -n "$CONN" ] && CONN_ARG="--connection $CONN"
OUT="output/output.txt"
mkdir -p output

command -v snow >/dev/null 2>&1 || {
  echo "Snowflake CLI (snow) required: https://docs.snowflake.com/en/developer-guide/snowflake-cli" >&2; exit 1; }

run_sql() { snow sql --filename "$1" $CONN_ARG; }

{
  echo "=================================================================="
  echo " self-healing Streams & Tasks CDC  |  connection: ${CONN:-<default from config.toml>}"
  echo "=================================================================="
  echo ""
  echo "--- 1. Build the pipeline + the cdc_watchdog_task that heals it ---"
  run_sql 01_pipeline.sql
  echo ""
  echo "--- 2. Break it (suspend the CDC task), then watch it heal ---"
  run_sql 02_demo.sql
  echo ""
  echo "=================================================================="
  echo " state_before = suspended  ->  cdc_watchdog_task ran  ->  state_after = started"
  echo " The stream never went stale, and the backlog was processed. Self-healed."
  echo "=================================================================="
} 2>&1 | tee "${OUT}"

echo ""
echo "Captured to ${OUT}"
