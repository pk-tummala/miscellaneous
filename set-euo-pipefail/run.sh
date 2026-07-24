#!/usr/bin/env bash
#==============================================================================
# run.sh - the same script, twice. One lies about succeeding. One doesn't.
#          Then: each of the three flags proved on its own.
# Requires: bash. Nothing else.
# Usage:    bash run.sh
#==============================================================================
cd "$(dirname "$0")"
mkdir -p data          # all runtime scratch for this demo lives here

line() { printf '=%.0s' {1..70}; echo; }
rule() { printf -- '-%.0s' {1..70}; echo; }

line; echo "set -euo pipefail - why a broken script can still report success"; line

echo
echo "PART 1 - the same load script, run two ways"
echo
echo ">>> WITHOUT the flags"
rule
bash without_flags.sh
rc=$?
rule
echo "exit code: $rc"
if [ "$rc" -eq 0 ]; then
  echo ">>> Two commands failed outright, a third silently produced nothing."
  echo ">>> It printed 'load complete' and exited 0 anyway."
  echo ">>> A scheduler reads that 0 and marks the run GREEN."
fi

echo
echo ">>> WITH set -euo pipefail"
rule
bash with_flags.sh
rc=$?
rule
echo "exit code: $rc"
if [ "$rc" -ne 0 ]; then
  echo ">>> Stopped at the FIRST failure and exited non-zero."
  echo ">>> A scheduler reads that and raises an ALERT."
fi

echo
line
echo "PART 2 - each flag on its own"
line
cat <<'TXT'

Note what just happened above: -e stopped the script at bug 1, so bugs 2 and 3
were never reached. That is correct behaviour - but it means you have not yet
SEEN what -u and pipefail do. So here is each flag, isolated and proved.

TXT

echo ">>> -e   stop as soon as a command fails"
rule
echo '   $ cat missing_file; echo "still running"          # no -e'
bash -c 'cat data/no_such_file_demo 2>/dev/null; echo "   still running  <- carried on after the failure"'
echo
echo '   $ set -e; cat missing_file; echo "still running"  # with -e'
bash -c 'set -e; cat data/no_such_file_demo 2>/dev/null; echo "   still running"'
echo "   (nothing printed - the script stopped) exit code: $?"

echo
echo ">>> -u   stop if a variable was never set"
rule
echo '   $ ROWCOUNT=5; echo "rows: $ROW_COUNT"             # no -u   (typo!)'
printf '#!/usr/bin/env bash\nROWCOUNT=5\necho "   rows: [$ROW_COUNT]  <- empty, and no complaint"\n' > data/u_off.sh
bash data/u_off.sh
echo
echo '   $ set -u; ROWCOUNT=5; echo "rows: $ROW_COUNT"     # with -u'
printf '#!/usr/bin/env bash\nset -u\nROWCOUNT=5\necho "   rows: [$ROW_COUNT]"\n' > data/u_on.sh
bash data/u_on.sh 2>&1 | sed 's/^/   /'
bash data/u_on.sh >/dev/null 2>&1
echo "   exit code: $?"
rm -f data/u_off.sh data/u_on.sh

echo
echo ">>> -o pipefail   judge a pipeline by ANY failing stage"
rule
echo '   $ cat missing_file | wc -l                        # no pipefail'
bash -c 'cat data/no_such_file_demo 2>/dev/null | wc -l > data/pf_demo.txt; echo "   exit code: $?  <- SUCCESS, and it wrote $(cat data/pf_demo.txt) rows"'
echo
echo '   $ set -o pipefail; cat missing_file | wc -l       # with pipefail'
bash -c 'set -o pipefail; cat data/no_such_file_demo 2>/dev/null | wc -l > /dev/null; echo "   exit code: $?  <- the dead first stage is now visible"'

echo
line
cat <<'TXT'
WHY THIS HAPPENS (straight from the bash manual)

  * By default, a script keeps going after a command fails, and the script's
    exit code is simply that of its LAST command. Here that was a successful
    echo - so the script exited 0.

  * By default, "the exit status of a pipeline is the exit status of the last
    command in the pipeline". A dead first stage is invisible if the last
    stage succeeds. With pipefail, the pipeline reports the rightmost
    non-zero status instead - so the failure surfaces.

  * By default, an unset variable expands to an empty string. -u turns that
    into an error, which is what catches the ROWCOUNT / ROW_COUNT typo.

THE HONEST CAVEAT

  -e is insurance, not a force field. Bash deliberately IGNORES it when a
  failure is already being handled: inside an if condition, in a while/until
  test, on the left of && or ||, in any pipeline stage except the last, or
  when the result is negated with !.

  And -e cuts both ways: a command that legitimately returns non-zero will
  also kill your script. grep exits 1 when it simply finds no match, so
  "set -e; grep pattern file" stops the script on a perfectly normal
  no-match. When you expect a non-zero result, say so explicitly:

      set +e; risky_command; rc=$?; set -e
      risky_command || true
      if ! grep -q pattern file; then ...; fi

  Being explicit about the failures you tolerate is the whole point. The
  flags stop you tolerating the ones you never meant to.
TXT
line
