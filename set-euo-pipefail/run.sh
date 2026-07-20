#!/usr/bin/env bash
#==============================================================================
# run.sh - the same script, twice. One lies. One doesn't.
# Requires: bash. Nothing else.
# Usage:    ./run.sh
#==============================================================================
cd "$(dirname "$0")"
chmod +x without_flags.sh with_flags.sh

line() { printf '=%.0s' {1..68}; echo; }
rule() { printf -- '-%.0s' {1..68}; echo; }

line; echo "set -euo pipefail - why your shell script lies about success"; line

echo
echo ">>> WITHOUT the flags"
rule
./without_flags.sh
rc=$?
rule
echo "exit code: $rc"
if [ $rc -eq 0 ]; then
  echo ">>> The scheduler sees 0. It marks this run GREEN."
  echo ">>> Three commands failed. It reported 'load complete'."
fi

echo
echo
echo ">>> WITH set -euo pipefail"
rule
./with_flags.sh
rc=$?
rule
echo "exit code: $rc"
if [ $rc -ne 0 ]; then
  echo ">>> Non-zero. The scheduler sees a FAILURE and alerts."
  echo ">>> It stopped at the first real problem instead of pretending."
fi

echo
line
cat <<'TXT'
Same logic. Same bugs. One line of difference.

  -e            stop on the first failing command
  -u            stop when an unset variable is used (catches typos)
  -o pipefail   a pipeline is only as successful as its weakest stage

Without them, this script:
  - failed to read a missing file          -> carried on
  - printed an unset variable as empty     -> carried on
  - ran a pipeline whose first stage died  -> carried on
  - exited 0 and announced "load complete"

That green tick in your scheduler is the most expensive lie in data
engineering, because nobody investigates a job that succeeded.

One caveat worth knowing: -e is deliberately ignored in some contexts (an if
condition, a && chain, a function in a test). It is insurance, not a force
field. When you genuinely expect a command to fail, say so explicitly:

  set +e; risky_command; rc=$?; set -e
  # or
  risky_command || true
TXT
line
