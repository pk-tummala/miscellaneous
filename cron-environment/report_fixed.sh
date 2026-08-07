#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HERE/bin:/usr/bin:/bin"   # our tool lives in ./bin — put it on PATH
source "$HERE/config/report.env"        # load our env from a dedicated file (not ~/.bashrc)
echo "  target env: ${REPORT_ENV:-<unset>}"
reportgen "${REPORT_ENV:-<unset>}"
