#!/usr/bin/env bash
#==============================================================================
# run.sh - narrow vs wide Spark transformations, shown with real explain() plans.
# Requires: python3 + python3-venv + a JRE (Java 17+). PySpark installs into a
#           local .venv on first run. No cluster needed.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

command -v java >/dev/null 2>&1 || {
  echo "Java (JRE 17+) not found - PySpark needs it."
  echo "  WSL Ubuntu:  sudo apt update && sudo apt install -y openjdk-17-jre-headless"
  exit 1
}
if [ ! -d .venv ]; then
  echo "First run: creating a local .venv and installing PySpark (a minute or so)..." >&2
  python3 -m venv .venv || { echo "Need python3-venv: sudo apt install -y python3-venv"; exit 1; }
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt || { echo "pip install failed (needs network)"; exit 1; }
fi

.venv/bin/python narrow_vs_wide.py 2> /dev/null
