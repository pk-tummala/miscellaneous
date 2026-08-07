#!/usr/bin/env bash
#==============================================================================
# job_safe.sh - the same job, but it tidies up after itself with a trap.
#
# trap cleanup EXIT  -> cleanup runs on ANY exit: normal, error (set -e), exit N,
#                       and a kill/SIGTERM. So the lock and temp file are always
#                       released, even when the job dies mid-run.
# The extra INT/TERM traps make Ctrl-C and kill exit promptly with the
# conventional codes (130 / 143), still routing through the EXIT trap.
# The one thing nothing can catch is kill -9 (SIGKILL) - the OS just stops you.
#==============================================================================
set -uo pipefail
WORKDIR="${1:?usage: job_safe.sh <workdir> [seconds]}"
SECONDS_TO_WORK="${2:-30}"
LOCK="$WORKDIR/job.lock"
TMP="$WORKDIR/work.tmp"

cleanup() {
  rm -f "$LOCK" "$TMP"
  echo "  job_safe: cleanup ran (lock + temp removed)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -e "$LOCK" ]; then
  echo "  job_safe: lock exists -> refusing to start (already running)"
  exit 3
fi

echo "$$" > "$LOCK"
echo "scratch data" > "$TMP"
echo "  job_safe: acquired lock, working..."
sleep "$SECONDS_TO_WORK"

echo "  job_safe: finished"   # cleanup() still runs after this, via the EXIT trap
