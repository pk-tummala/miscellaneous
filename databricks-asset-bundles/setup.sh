#!/usr/bin/env bash
#==============================================================================
# setup.sh - ensure the shared sandbox catalog exists and the team has CREATE SCHEMA on it.
#
# Fully idempotent and check-then-act, so it is safe to run on its own OR to be called from
# run.sh on every deploy:
#   - catalog already exists  -> skips creation (no SQL warehouse needed)
#   - grant already in place   -> skips the grant (so a non-admin re-run does not fail)
# Only the FIRST run (creating the catalog) needs a SQL warehouse (auto-picked, or WAREHOUSE_ID=)
# and catalog-create / grant privileges.
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-vic-dev}"
CATALOG="${CATALOG:-dab_sandbox}"
GRANTEE="${GRANTEE:-account users}"

command -v databricks >/dev/null 2>&1 || { echo "databricks CLI is required" >&2; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "jq is required"             >&2; exit 1; }

# 1. Catalog - create only if missing (Default-Storage workspaces need SQL for this).
if databricks catalogs get "$CATALOG" -p "$PROFILE" >/dev/null 2>&1; then
  echo "  catalog $CATALOG: already exists"
else
  echo "  catalog $CATALOG: creating"
  WAREHOUSE_ID="${WAREHOUSE_ID:-}"
  if [ -z "$WAREHOUSE_ID" ]; then
    WAREHOUSE_ID="$(databricks warehouses list -p "$PROFILE" -o json \
      | jq -r 'if type=="array" then . else .warehouses end | .[0].id // empty')"
  fi
  [ -n "$WAREHOUSE_ID" ] || { echo "  no SQL warehouse to create the catalog - set WAREHOUSE_ID=<id>" >&2; exit 1; }
  bf="$(mktemp)"
  jq -nc --arg w "$WAREHOUSE_ID" \
     --arg s "CREATE CATALOG IF NOT EXISTS $CATALOG COMMENT 'Shared developer sandbox - each developer gets their own schema'" \
     '{warehouse_id:$w, statement:$s, wait_timeout:"50s", on_wait_timeout:"CONTINUE"}' > "$bf"
  resp="$(databricks api post /api/2.0/sql/statements -p "$PROFILE" --json "@$bf")"; rm -f "$bf"
  sid="$(printf '%s' "$resp" | jq -r '.statement_id')"
  state="$(printf '%s' "$resp" | jq -r '.status.state')"
  while [ "$state" = "PENDING" ] || [ "$state" = "RUNNING" ]; do
    sleep 2
    resp="$(databricks api get "/api/2.0/sql/statements/$sid" -p "$PROFILE")"
    state="$(printf '%s' "$resp" | jq -r '.status.state')"
  done
  [ "$state" = "SUCCEEDED" ] || { echo "  create failed ($state): $(printf '%s' "$resp" | jq -r '.status.error.message // "unknown"')" >&2; exit 1; }
  echo "  catalog $CATALOG: created"
fi

# 2. Grant USE CATALOG + CREATE SCHEMA to the team - only if not already present (CLI, no warehouse).
if databricks grants get catalog "$CATALOG" -p "$PROFILE" -o json 2>/dev/null \
   | jq -e --arg p "$GRANTEE" '.privilege_assignments[]? | select(.principal==$p) | .privileges | (index("USE_CATALOG") and index("CREATE_SCHEMA"))' >/dev/null 2>&1; then
  echo "  grant on $CATALOG to '$GRANTEE': already in place"
else
  gb="$(jq -nc --arg p "$GRANTEE" '{changes:[{principal:$p, add:["USE_CATALOG","CREATE_SCHEMA"]}]}')"
  databricks grants update catalog "$CATALOG" -p "$PROFILE" --json "$gb" >/dev/null
  echo "  grant USE CATALOG, CREATE SCHEMA on $CATALOG to '$GRANTEE': applied"
fi
