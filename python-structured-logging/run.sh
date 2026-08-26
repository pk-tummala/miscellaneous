#!/usr/bin/env bash
#==============================================================================
# run.sh - Logging done right in Python: structured logs with context.
# Requires: python3 only. No pip, no venv, no account - standard library.
# PIPELINE_RUN_ID stands in for the run id an orchestrator would inject; it is
# pinned here so the captured output reproduces.
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
PIPELINE_RUN_ID="${PIPELINE_RUN_ID:-run-2f9c1a}" python3 structured_logging.py
