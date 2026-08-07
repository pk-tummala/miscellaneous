#!/usr/bin/env bash
#==============================================================================
# job_naive.sh - a job that takes a lock and a temp file, and does NOT clean up.
# If it dies mid-run (crash, kill, Ctrl-C), the lock is left behind and the next
# run refuses to start. This is the 3am-pager version.
#==============================================================================
set -uo pipefail
WORKDIR="${1:?usage: job_naive.sh <workdir> [seconds]}"
SECONDS_TO_WORK="${2:-30}"
LOCK="$WORKDIR/job.lock"
TMP="$WORKDIR/work.tmp"

# crude lock: if the file is here, assume another run owns it
if [ -e "$LOCK" ]; then
  echo "  job_naive: lock exists -> refusing to start (already running)"
  exit 3
fi

echo "$$" > "$LOCK"          # claim the lock
echo "scratch data" > "$TMP" # a temp file we should clean up
echo "  job_naive: acquired lock, working..."
sleep "$SECONDS_TO_WORK"

# cleanup only happens if we reach here - a crash or kill skips it entirely
rm -f "$LOCK" "$TMP"
echo "  job_naive: finished, lock released"
