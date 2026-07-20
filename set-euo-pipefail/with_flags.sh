#!/usr/bin/env bash
# with_flags.sh - the identical script, with three characters of insurance.
#
#   set -e           exit the moment any command fails
#   set -u           exit if an unset variable is referenced
#   set -o pipefail  a pipeline fails if ANY stage fails, not just the last
#
set -euo pipefail

SRC_DIR="data/inbound"
mkdir -p "$SRC_DIR"
echo "id,amount"      >  "$SRC_DIR/today.csv"
echo "1,100"          >> "$SRC_DIR/today.csv"

echo "  [1] extracting..."
cat "$SRC_DIR/yesterday.csv" > /tmp/extract.csv 2>/dev/null

echo "  [2] counting rows..."
ROWCOUNT=$(wc -l < /tmp/extract.csv)
echo "      rows found: $ROW_COUNT"

echo "  [3] loading..."
cat /tmp/does_not_exist.csv 2>/dev/null | grep -c "" > /tmp/loaded.txt

echo "  [4] done - load complete"
