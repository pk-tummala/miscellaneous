#!/usr/bin/env bash
#==============================================================================
# run.sh - one command, end to end and idempotent:
#   1. setup.sh -> ensure the shared catalog + grants exist (skips cleanly if already present)
#   2. validate -> prove dev mode isolated my pipeline NAME but the write TARGET is mine to set
#   3. deploy   -> create [dev <me>] demo_pipeline
#   4. run      -> the pipeline writes bronze/silver into dab_sandbox.demo_<me> (a few minutes)
#   5. verify   -> those tables live in MY schema, nobody else's
#
# Needs an authenticated Databricks CLI (profile defaults to vic-dev). Idempotent - re-run
# any time; each developer writes to their own schema, so no one overwrites anyone.
# Writes a clean, sectioned log to output/output.txt.
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-vic-dev}"
TARGET="${TARGET:-dev}"
CATALOG="${CATALOG:-dab_sandbox}"
OUT="output/output.txt"
mkdir -p output

command -v databricks >/dev/null 2>&1 || { echo "databricks CLI is required" >&2; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "jq is required"             >&2; exit 1; }

{
  echo "=================================================================="
  echo " dab_isolation_demo  |  per-developer write target  |  profile: ${PROFILE}"
  echo "=================================================================="

  echo ""
  echo "--- 1. Setup: ensure the shared catalog + grants exist (idempotent) ---"
  PROFILE="${PROFILE}" CATALOG="${CATALOG}" WAREHOUSE_ID="${WAREHOUSE_ID:-}" bash ./setup.sh

  echo ""
  echo "--- 2. Proof: dev mode isolated the NAME; the write TARGET is what I set ---"
  V="$(databricks bundle validate -t "${TARGET}" -p "${PROFILE}" -o json)"
  NAME="$(printf '%s' "$V" | jq -r '.resources.pipelines.demo_pipeline.name')"
  CAT="$(printf '%s' "$V"  | jq -r '.resources.pipelines.demo_pipeline.catalog')"
  SCH="$(printf '%s' "$V"  | jq -r '.resources.pipelines.demo_pipeline.schema')"
  echo "  pipeline name : ${NAME}          <- dev mode prefixed this"
  echo "  writes to     : ${CAT}.${SCH}    <- dev mode did NOT touch this; I set it per developer"

  echo ""
  echo "--- 3. Deploy: create the pipeline ---"
  echo "\$ databricks bundle deploy -t ${TARGET} -p ${PROFILE}"
  databricks bundle deploy -t "${TARGET}" -p "${PROFILE}"

  echo ""
  echo "--- 4. Run: the pipeline writes bronze/silver into ${CAT}.${SCH} (takes a few minutes) ---"
  echo "\$ databricks bundle run demo_pipeline -t ${TARGET} -p ${PROFILE}"
  databricks bundle run demo_pipeline -t "${TARGET}" -p "${PROFILE}"

  echo ""
  echo "--- 5. Verify: the tables live in MY schema ---"
  echo "\$ databricks tables list ${CAT} ${SCH} -p ${PROFILE}"
  databricks tables list "${CAT}" "${SCH}" -p "${PROFILE}" -o json \
    | jq -r '.[] | "  table: " + .full_name'

  echo ""
  echo "=================================================================="
  echo " Done. Another developer's pipeline writes to dab_sandbox.demo_<them> -"
  echo " same catalog, different schema, so their bronze/silver never touch mine."
  echo "=================================================================="
} 2>&1 | tee "${OUT}"

echo ""
echo "Captured to ${OUT}"
