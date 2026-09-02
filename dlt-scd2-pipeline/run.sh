#!/usr/bin/env bash
#==============================================================================
# run.sh - brand-new, self-provisioning, idempotent demo.
#
# Assumes ONLY: the Databricks CLI + a connection profile (default: vic-dev).
# It provisions everything else - a small serverless SQL warehouse, the catalog,
# the schema and the grants - then seeds, runs the DLT pipeline and prints the contrast.
# Re-runnable: every step is idempotent and the pipeline is full-refreshed each run.
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${DATABRICKS_PROFILE:-vic-dev}"     # your connection in ~/.databrickscfg
PROFILE_ARG="-p $PROFILE"
CATALOG="dlt_scd2_demo"; SCHEMA="demo"; SRC="${CATALOG}.${SCHEMA}.cdc_source"
WH_NAME="scd2_demo_wh"
OUT="output/output.txt"; mkdir -p output

command -v databricks >/dev/null 2>&1 || { echo "Databricks CLI required" >&2; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "jq required"             >&2; exit 1; }

# ---- who am I (for grants) ----
ME="$(databricks current-user me $PROFILE_ARG -o json | jq -r '.userName')"

# ---- resolve or CREATE a small serverless SQL warehouse (idempotent by name) ----
WAREHOUSE_ID="${WAREHOUSE_ID:-}"
if [ -z "$WAREHOUSE_ID" ]; then
  WAREHOUSE_ID="$(databricks warehouses list $PROFILE_ARG -o json \
    | jq -r --arg n "$WH_NAME" 'if type=="array" then . else .warehouses end | map(select(.name==$n)) | .[0].id // empty')"
fi
if [ -z "$WAREHOUSE_ID" ]; then
  echo "Creating serverless SQL warehouse '$WH_NAME' ..."
  WAREHOUSE_ID="$(databricks warehouses create $PROFILE_ARG -o json --json \
    '{"name":"scd2_demo_wh","cluster_size":"2X-Small","min_num_clusters":1,"max_num_clusters":1,"auto_stop_mins":10,"enable_serverless_compute":true,"warehouse_type":"PRO"}' \
    | jq -r '.id')"
fi
[ -n "$WAREHOUSE_ID" ] || { echo "Could not resolve or create a warehouse" >&2; exit 1; }

# ---- run one SQL statement via the Statement Execution API (auto-starts the warehouse) ----
run_sql() {
  local bf resp sid state
  bf="$(mktemp)"
  jq -nc --arg w "$WAREHOUSE_ID" --arg s "$1" \
     '{warehouse_id:$w, statement:$s, wait_timeout:"50s", on_wait_timeout:"CONTINUE"}' > "$bf"
  resp="$(databricks api post /api/2.0/sql/statements $PROFILE_ARG --json "@$bf")"; rm -f "$bf"
  sid="$(printf '%s' "$resp"  | jq -r '.statement_id')"
  state="$(printf '%s' "$resp" | jq -r '.status.state')"
  while [ "$state" = "PENDING" ] || [ "$state" = "RUNNING" ]; do
    sleep 2
    resp="$(databricks api get "/api/2.0/sql/statements/${sid}" $PROFILE_ARG)"
    state="$(printf '%s' "$resp" | jq -r '.status.state')"
  done
  [ "$state" = "SUCCEEDED" ] || { echo "  SQL FAILED (${state}): $(printf '%s' "$resp" | jq -r '.status.error.message // "unknown"')" >&2; return 1; }
  printf '%s' "$resp" | jq -er '.result.data_array' >/dev/null 2>&1 && \
    printf '%s' "$resp" | jq -r '.result.data_array[] | @tsv' | sed 's/^/    /'
  return 0
}

{
  echo "=================================================================="
  echo " native SCD2 with AUTO CDC  |  profile=${PROFILE}  warehouse=${WAREHOUSE_ID}"
  echo " user=${ME}"
  echo "=================================================================="

  echo ""
  echo "--- 0. Provision catalog + schema + grants (idempotent) ---"
  run_sql "CREATE CATALOG IF NOT EXISTS ${CATALOG}"
  run_sql "GRANT USE CATALOG, CREATE SCHEMA ON CATALOG ${CATALOG} TO \`${ME}\`" || echo "  (catalog grant skipped - already owner)"
  run_sql "CREATE SCHEMA IF NOT EXISTS ${CATALOG}.${SCHEMA}"
  run_sql "GRANT USE SCHEMA, CREATE TABLE, SELECT, MODIFY ON SCHEMA ${CATALOG}.${SCHEMA} TO \`${ME}\`" || echo "  (schema grant skipped - already owner)"

  echo ""
  echo "--- 1. Seed the CDC feed (source columns + a pipeline-added ingested_at, pre-set for a reproducible out-of-order case) ---"
  run_sql "CREATE OR REPLACE TABLE ${SRC} (order_id INT, order_status STRING, order_updated_at TIMESTAMP, operation STRING, ingested_at TIMESTAMP)"
  run_sql "INSERT INTO ${SRC} (order_id, order_status, order_updated_at, operation, ingested_at) VALUES
             (1,'SHIPPED','2026-09-01T10:00:00','UPSERT','2026-09-01T11:00:00'),
             (1,'PENDING','2026-09-01T09:00:00','UPSERT','2026-09-01T11:05:00'),
             (2,'PENDING','2026-09-01T09:10:00','UPSERT','2026-09-01T11:02:00'),
             (NULL,'GARBAGE','2026-09-01T09:20:00','UPSERT','2026-09-01T11:03:00')"
  echo "  order_id=1 SHIPPED(src 10:00, ingested 11:00) and PENDING(src 09:00, ingested 11:05 - out of order), order_id=2, a NULL-key row"

  echo ""
  echo "--- 2. Deploy + run the serverless DLT pipeline (full refresh = clean, reproducible build) ---"
  databricks bundle deploy -t dev $PROFILE_ARG
  databricks bundle run scd2_pipeline -t dev --full-refresh-all $PROFILE_ARG

  echo ""
  echo "--- 3. The contrast: the CURRENT row of each dimension ---"
  echo "\$ SELECT dimension, order_id, order_status, order_updated_at FROM ${CATALOG}.${SCHEMA}.scd2_contrast ORDER BY dimension, order_id"
  run_sql "SELECT dimension, order_id, order_status, order_updated_at FROM ${CATALOG}.${SCHEMA}.scd2_contrast ORDER BY dimension, order_id NULLS LAST"

  echo ""
  echo "=================================================================="
  echo " naive:   order_id=1 -> PENDING (won on ingestion/arrival order) + a NULL-key row"
  echo " guarded: order_id=1 -> SHIPPED (correct - sequenced by order_updated_at), garbage dropped by expectations"
  echo "=================================================================="
} 2>&1 | tee "${OUT}"

echo ""
echo "Captured to ${OUT}"
echo "Teardown:  (drop everything the demo created)"
echo "  DROP CATALOG IF EXISTS ${CATALOG} CASCADE;   (run via the SQL editor or the API)"
echo "  databricks warehouses delete ${WAREHOUSE_ID} ${PROFILE_ARG}"
