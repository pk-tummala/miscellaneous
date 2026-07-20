#!/usr/bin/env bash
# without_flags.sh - a load script written the way most of them are written.
# No set flags. Read it and try to spot the three lies before you run it.

SRC_DIR="data/inbound"
mkdir -p "$SRC_DIR"
echo "id,amount"      >  "$SRC_DIR/today.csv"
echo "1,100"          >> "$SRC_DIR/today.csv"

echo "  [1] extracting..."
# LIE 1: this file does not exist. cat fails, prints to stderr, script marches on.
cat "$SRC_DIR/yesterday.csv" > /tmp/extract.csv 2>/dev/null

echo "  [2] counting rows..."
# LIE 2: $ROW_COUNT is never set (typo: ROWCOUNT vs ROW_COUNT).
# Unset variable expands to empty string. No error.
ROWCOUNT=$(wc -l < /tmp/extract.csv)
echo "      rows found: $ROW_COUNT"

echo "  [3] loading..."
# LIE 3: the pipeline's first command fails, but the exit status is grep's.
# grep succeeds on empty input (finds nothing, but the pipe itself is fine).
cat /tmp/does_not_exist.csv 2>/dev/null | grep -c "" > /tmp/loaded.txt

echo "  [4] done - load complete"
