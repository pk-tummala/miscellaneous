#!/usr/bin/env bash
# without_flags.sh - a load script written the way most of them are written.
# No set flags. Three real bugs are planted in it. Read it before you run it.

SRC_DIR="data/inbound"
mkdir -p "$SRC_DIR"        # runtime scratch lives under data/

# Today's file landed fine. The job also needs YESTERDAY's file to compute a
# delta - and that one never arrived. This is the everyday scenario: the
# upstream was late, and the job runs anyway.
printf 'id,amount\n1,100\n' > "$SRC_DIR/today.csv"

echo "  [1] extracting yesterday's file..."
# BUG 1: this file does not exist, so cat fails and exits 1.
# The error goes to the log - but nothing checks the exit code, so it carries on.
cat "$SRC_DIR/yesterday.csv" > data/extract.csv

echo "  [2] counting rows..."
# BUG 2: a typo. The variable that gets SET is ROWCOUNT.
# The variable that gets PRINTED is ROW_COUNT - which was never set.
# By default an unset variable quietly expands to an empty string.
ROWCOUNT=$(wc -l < data/extract.csv)
echo "      rows found: $ROW_COUNT"

echo "  [3] loading..."
# BUG 3: the FIRST stage of this pipeline dies (missing file, exit 1), but the
# LAST stage - wc -l - happily counts zero lines and exits 0. By default a
# pipeline reports only the LAST command's status, so this reads as success
# and the row count is silently written as 0.
 cat data/does_not_exist.csv | wc -l > data/loaded.txt

echo "  [4] done - load complete"
