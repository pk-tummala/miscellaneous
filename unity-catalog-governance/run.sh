#!/usr/bin/env bash
#==============================================================================
# run.sh - Unity Catalog: governance you build in, not bolt on.
#
#   bash run.sh            fresh build + demo (namespace, grants + inheritance, ownership, lineage)
#   bash run.sh teardown   drop everything the demo created
#
# Assumes ONLY the Databricks CLI + a profile (default: vic-dev). Self-provisions a serverless SQL
# warehouse. Idempotent. Captures the build run to output/output.txt.
#==============================================================================
set -o pipefail
cd "$(dirname "$0")"

PROFILE="${DATABRICKS_PROFILE:-vic-dev}"; PROFILE_ARG="-p $PROFILE"
CAT="gov_demo"; SCH="sales"; WH_NAME="gov_demo_wh"
OUT="output/output.txt"; mkdir -p output

command -v databricks >/dev/null 2>&1 || { echo "Databricks CLI required" >&2; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "jq required"             >&2; exit 1; }

# preflight: the profile must be authenticated (access tokens expire)
ME="$(databricks current-user me $PROFILE_ARG -o json 2>/dev/null | jq -r '.userName // empty')"
if [ -z "$ME" ]; then
  echo "Profile '$PROFILE' is not authenticated (the token may have expired)." >&2
  echo "Re-authenticate, then re-run:" >&2
  echo "  databricks auth login --profile $PROFILE" >&2
  exit 1
fi

# resolve or create a small serverless SQL warehouse (idempotent by name)
WAREHOUSE_ID="${WAREHOUSE_ID:-}"
if [ -z "$WAREHOUSE_ID" ]; then
  WAREHOUSE_ID="$(databricks warehouses list $PROFILE_ARG -o json | jq -r --arg n "$WH_NAME" \
    'if type=="array" then . else .warehouses end | map(select(.name==$n)) | .[0].id // empty')"
fi
if [ -z "$WAREHOUSE_ID" ]; then
  echo "Creating serverless SQL warehouse '$WH_NAME' ..."
  WAREHOUSE_ID="$(databricks warehouses create $PROFILE_ARG -o json --json \
    '{"name":"gov_demo_wh","cluster_size":"2X-Small","min_num_clusters":1,"max_num_clusters":1,"auto_stop_mins":10,"enable_serverless_compute":true,"warehouse_type":"PRO"}' | jq -r '.id')"
fi
[ -n "$WAREHOUSE_ID" ] || { echo "Could not resolve or create a warehouse" >&2; exit 1; }

run_sql() {   # $1 = SQL ; prints result rows if any ; returns non-zero on error
  local bf resp sid state
  bf="$(mktemp)"
  jq -nc --arg w "$WAREHOUSE_ID" --arg s "$1" '{warehouse_id:$w, statement:$s, wait_timeout:"50s", on_wait_timeout:"CONTINUE"}' > "$bf"
  resp="$(databricks api post /api/2.0/sql/statements $PROFILE_ARG --json "@$bf")"; rm -f "$bf"
  sid="$(printf '%s' "$resp" | jq -r '.statement_id')"; state="$(printf '%s' "$resp" | jq -r '.status.state')"
  while [ "$state" = "PENDING" ] || [ "$state" = "RUNNING" ]; do
    sleep 2; resp="$(databricks api get "/api/2.0/sql/statements/${sid}" $PROFILE_ARG)"
    state="$(printf '%s' "$resp" | jq -r '.status.state')"
  done
  if [ "$state" != "SUCCEEDED" ]; then
    echo "  ! $(printf '%s' "$resp" | jq -r '.status.error.message // "unknown error"' | head -1)" >&2; return 1
  fi
  printf '%s' "$resp" | jq -er '.result.data_array' >/dev/null 2>&1 && printf '%s' "$resp" | jq -r '.result.data_array[] | @tsv' | sed 's/^/    /'
  return 0
}

# --------------------------------------------------------------------------- teardown
if [ "${1:-}" = "teardown" ]; then
  echo "Tearing down ..."
  run_sql "DROP CATALOG IF EXISTS ${CAT} CASCADE" && echo "  dropped catalog ${CAT}"
  databricks warehouses delete "$WAREHOUSE_ID" $PROFILE_ARG 2>/dev/null && echo "  deleted warehouse ${WAREHOUSE_ID}" || true
  echo "Done."; exit 0
fi


{
  echo "=================================================================="
  echo " Unity Catalog governance  |  profile=${PROFILE}  warehouse=${WAREHOUSE_ID}  owner=${ME}"
  echo "=================================================================="

  echo ""
  echo "--- 1. Three-level namespace: catalog -> schema -> table (created fresh, idempotent) ---"
  run_sql "CREATE CATALOG IF NOT EXISTS ${CAT} COMMENT 'governed lakehouse demo'"
  run_sql "CREATE SCHEMA  IF NOT EXISTS ${CAT}.${SCH} COMMENT 'sales domain'"
  run_sql "CREATE OR REPLACE TABLE ${CAT}.${SCH}.orders_bronze AS
             SELECT * FROM VALUES (1,'ACME',100.00),(2,'BETA',50.00),(3,'GAMMA',20.00) AS t(order_id, customer, amount)"
  echo "  built ${CAT}.${SCH}.orders_bronze  (fully-qualified 3-level name)"

  echo ""
  echo "--- 2. Least-privilege grant + inheritance (in prod: grant to an account GROUP, not a user) ---"
  run_sql "GRANT USE CATALOG ON CATALOG ${CAT} TO \`${ME}\`"
  run_sql "GRANT USE SCHEMA  ON SCHEMA  ${CAT}.${SCH} TO \`${ME}\`"
  run_sql "GRANT SELECT      ON SCHEMA  ${CAT}.${SCH} TO \`${ME}\`"    # inherits to ALL current + future tables
  echo "  granted USE CATALOG + USE SCHEMA + SELECT (read needs all three). SELECT-on-schema inherits to every table:"
  run_sql "SHOW GRANTS ON SCHEMA ${CAT}.${SCH}"

  echo ""
  echo "--- 3. Ownership (every securable has an owner; in prod, own by a group) ---"
  run_sql "SELECT catalog_name, schema_name, schema_owner FROM ${CAT}.information_schema.schemata WHERE schema_name = '${SCH}'"

  echo ""
  echo "--- 4. Lineage comes free: a downstream table, captured automatically by Unity Catalog ---"
  run_sql "CREATE OR REPLACE TABLE ${CAT}.${SCH}.orders_silver AS
             SELECT order_id, customer, amount FROM ${CAT}.${SCH}.orders_bronze WHERE amount >= 50"
  echo "  created orders_silver from orders_bronze -> lineage recorded automatically."
  echo "  \$ SELECT source_table_full_name, target_table_full_name FROM system.access.table_lineage ..."
  run_sql "SELECT source_table_full_name, target_table_full_name FROM system.access.table_lineage
             WHERE target_table_full_name = '${CAT}.${SCH}.orders_silver' AND source_table_full_name IS NOT NULL LIMIT 5" \
    || echo "    (system.access lineage not enabled or not yet populated - lineage still captured; view in Catalog Explorer > Lineage)"

  echo ""
  echo "--- 5. Tighten later without a migration: REVOKE, and the change is instant ---"
  run_sql "REVOKE SELECT ON SCHEMA ${CAT}.${SCH} FROM \`${ME}\`"
  echo "  revoked SELECT. Grants now:"
  run_sql "SHOW GRANTS ON SCHEMA ${CAT}.${SCH}"

  echo ""
  echo "=================================================================="
  echo " Governance was part of the build: named 3-level objects, least-privilege grants that"
  echo " inherit, clear ownership, automatic lineage. Nothing bolted on, nothing to migrate."
  echo "=================================================================="
} 2>&1 | tee "${OUT}"

echo ""
echo "Captured to ${OUT}"
echo "Teardown when done:  bash run.sh teardown   (drops catalog ${CAT} CASCADE + the warehouse)"
