#!/usr/bin/env bash
#==============================================================================
# run.sh - the same script, run by hand vs the way cron runs it.
#   By hand it works. Under cron's bare environment (reproduced with `env -i`,
#   no daemon needed) the tool isn't found and the env var is gone. The fixed
#   script declares its own PATH and env and runs the same either way.
# Pure bash, no account. Usage: bash run.sh
#==============================================================================
set -uo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
chmod +x bin/reportgen 2>/dev/null || true   # a command on PATH needs the exec bit
bar="======================================================================"

echo "$bar"
echo "CRON ISN'T YOUR SHELL - the same script, by hand vs under cron"
echo "$bar"
echo ""
echo "The job (report.sh):"
echo "    echo \"target env: \$REPORT_ENV\""
echo "    reportgen \"\$REPORT_ENV\"        # reportgen lives in ./bin"

echo ""
echo "--- 1. You run it by hand (your login shell) ---"
echo "  \$ ./report.sh"
PATH="$HERE/bin:$PATH" REPORT_ENV="prod" bash report.sh
echo "  => works: your PATH includes ./bin, and REPORT_ENV came from ~/.bashrc."

echo ""
echo "--- 2. cron runs the SAME script at 3am (bare env, minimal PATH) ---"
echo "  # crontab:  0 3 * * * /opt/etl/report.sh"
echo "  # reproduced with: env -i PATH=/usr/bin:/bin HOME=\$HOME bash report.sh"
env -i PATH="/usr/bin:/bin" HOME="$HOME" bash report.sh 2>&1; rc=$?
echo "  -> exit $rc"
echo "  => cron can't find reportgen (not on /usr/bin:/bin), and REPORT_ENV is gone."

echo ""
echo "--- 3. The fix: report_fixed.sh declares its own PATH + env ---"
echo "  # same bare env as cron:"
env -i PATH="/usr/bin:/bin" HOME="$HOME" bash report_fixed.sh 2>&1; rc=$?
echo "  -> exit $rc"
echo "  => runs the same by hand or under cron."

echo ""
echo "$bar"
echo "The fix: declare the environment, don't inherit it."
echo "  - set PATH in the script (or the crontab), or use absolute paths"
echo "  - source a DEDICATED env file (not ~/.bashrc - it exits early when"
echo "    non-interactive, so sourcing it does nothing)"
echo "  - set SHELL=/bin/bash in the crontab if you use bash (cron uses /bin/sh)"
echo "  - redirect output to a log (>> report.log 2>&1) so a 3am failure isn't silent"
echo "See crontab.example for the schedule, both ways."
echo "$bar"
