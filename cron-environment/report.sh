#!/usr/bin/env bash
# A nightly reporting job. Works when you run it by hand; dies under cron, because
# it assumes the PATH (with ./bin) and REPORT_ENV that your login shell had.
echo "  target env: ${REPORT_ENV:-<unset>}"
reportgen "${REPORT_ENV:-<unset>}"
