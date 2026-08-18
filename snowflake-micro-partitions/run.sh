#!/usr/bin/env bash
#==============================================================================
# run.sh - runs micro_partitions_demo.sql against YOUR Snowflake account with
#          the Snowflake CLI (snow) and writes the captured results straight
#          into output/output.txt. No manual copy/paste.
#
# Requires: a Snowflake account, plus the Snowflake CLI installed and a
#           connection configured:
#              pip install snowflake-cli
#              snow connection add        (set one as default, or name it)
#
# Usage:    bash run.sh                 (uses your default connection)
#           bash run.sh my_connection   (uses a named connection)
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p output

if ! command -v snow >/dev/null 2>&1; then
  echo "Snowflake CLI ('snow') not found on PATH."
  echo "  Install:   pip install snowflake-cli"
  echo "  Configure: snow connection add"
  echo "Using legacy SnowSQL instead? Run:"
  echo "  snowsql -c <conn> -f micro_partitions_demo.sql -o output_file=output/output.txt -o quiet=true -o friendly=false"
  exit 1
fi

CONN_ARG=""
[ "${1:-}" != "" ] && CONN_ARG="-c $1"

echo "Running micro_partitions_demo.sql via Snowflake CLI (this builds 20M rows, ~1-2 min)..."
snow sql $CONN_ARG -f micro_partitions_demo.sql > output/output.txt 2>&1

echo "Done. Captured results are in output/output.txt"
echo "Look for the clustering-info table and the partitions_scanned / partitions_total table."
