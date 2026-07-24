#!/usr/bin/env bash
# with_flags.sh - the identical script, with one line of insurance added.
#
#   set -e           exit as soon as a command fails
#   set -u           exit if an unset variable is referenced
#   set -o pipefail  judge a pipeline by ANY failing stage, not just the last
#
set -euo pipefail

SRC_DIR="data/inbound"
mkdir -p "$SRC_DIR"        # runtime scratch lives under data/

# Today's file landed fine. The job also needs YESTERDAY's file to compute a
# delta - and that one never arrived. This is the everyday scenario: the
# upstream was late, and the job runs anyway.
printf 'id,amount\n1,100\n' > "$SRC_DIR/today.csv"

echo "  [1] extracting yesterday's file..."
cat "$SRC_DIR/yesterday.csv" > data/extract.csv

echo "  [2] counting rows..."
ROWCOUNT=$(wc -l < data/extract.csv)
echo "      rows found: $ROW_COUNT"

echo "  [3] loading..."
 cat data/does_not_exist.csv | wc -l > data/loaded.txt
echo "      rows loaded: $(cat data/loaded.txt)"

echo "  [4] done - load complete"
