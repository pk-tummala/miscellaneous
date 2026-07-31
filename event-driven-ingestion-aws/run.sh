#!/usr/bin/env bash
#==============================================================================
# run.sh - runnable proof of event-driven vs polling file ingestion, using the
#          Linux kernel's inotify (the local analog of S3 -> EventBridge).
#          No AWS account needed.
# Requires: python3 + python3-venv. A local .venv is created on first run.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 1; }
if [ ! -d .venv ]; then
  echo "First run: creating a local .venv..." >&2
  python3 -m venv .venv || { echo "Need python3-venv: sudo apt install -y python3-venv"; exit 1; }
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt || { echo "pip install failed (needs network)"; exit 1; }
fi

rm -rf data && mkdir -p data           # fresh, disposable runtime state each run
.venv/bin/python local_event_vs_poll.py
