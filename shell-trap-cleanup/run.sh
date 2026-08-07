#!/usr/bin/env bash
#==============================================================================
# run.sh - shows the difference a cleanup trap makes when a job dies mid-run.
#   Part 1: a naive job is killed -> its lock survives -> the next run is blocked.
#   Part 2: a job with `trap cleanup EXIT` is killed -> it tidies up -> next run
#           starts clean.
# Pure bash, no account, nothing to install.  Usage: bash run.sh
#==============================================================================
set -uo pipefail
cd "$(dirname "$0")"

DATA="data"; rm -rf "$DATA"; mkdir -p "$DATA"   # disposable scratch (gitignored)
LOCK="$DATA/job.lock"

wait_for_lock() { for _ in $(seq 1 50); do [ -e "$LOCK" ] && return 0; sleep 0.1; done; }
present() { [ -e "$LOCK" ] && echo "YES" || echo "no"; }
bar="======================================================================"

echo "$bar"
echo "TRAP & CLEANUP - what happens to the lock file when a job dies at 3am"
echo "$bar"

echo ""
echo "--- PART 1: the naive job (no cleanup) gets killed mid-run ---"
bash job_naive.sh "$DATA" 30 & p=$!; wait_for_lock
kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
echo "  [job killed]  lock file still there? -> $(present)"
echo "  the next run:"
bash job_naive.sh "$DATA" 30 || true
echo "  => stuck. nothing runs again until a human deletes the lock by hand."
rm -f "$DATA"/*                                  # a human cleans up the mess

echo ""
echo "--- PART 2: the safe job (trap cleanup EXIT) gets killed mid-run ---"
bash job_safe.sh "$DATA" 30 & p=$!; wait_for_lock
kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
echo "  [job killed]  lock file still there? -> $(present)"
echo "  the next run:"
bash job_safe.sh "$DATA" 1 || true
echo "  => started clean. no stale lock, no pager, no human needed."

echo ""
echo "$bar"
echo "trap cleanup EXIT runs on normal exit, on errors, and on a kill (SIGTERM)."
echo "Add 'trap ... INT TERM' for a prompt Ctrl-C / kill. The only thing nothing"
echo "can catch is kill -9 (SIGKILL) - the OS stops you before any trap can run."
echo "$bar"
