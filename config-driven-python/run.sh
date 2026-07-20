#!/usr/bin/env bash
#==============================================================================
# run.sh - the same code, four environments, zero code changes.
# Requires: python3 + python3-venv (WSL Ubuntu: sudo apt install -y python3-venv).
#           A local .venv is created on first run; system Python is untouched.
# Usage:    ./run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# --- bootstrap: isolated .venv (created once, reused after) ------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found."
  echo "  WSL Ubuntu:  sudo apt update && sudo apt install -y python3 python3-venv"
  exit 1
fi
if [ ! -d .venv ]; then
  echo "First run: creating a local .venv (nothing installed system-wide)..."
  python3 -m venv .venv 2>/dev/null || {
    echo "Could not create the virtual environment."
    echo "  WSL Ubuntu:  sudo apt install -y python3-venv"
    exit 1
  }
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt || {
    echo "Could not install dependencies - is PyPI reachable? (needs network)"
    exit 1
  }
fi
PY=.venv/bin/python
# ----------------------------------------------------------------------------

line() { printf '=%.0s' {1..68}; echo; }

line; echo "CONFIG-DRIVEN PYTHON - one codebase, four resolutions"; line

echo; echo ">>> 1. dev (the default)"
echo "    \$ python3 pipeline.py --env dev"
"$PY" pipeline.py --env dev

echo; echo ">>> 2. prod - same command, different env block"
echo "    \$ python3 pipeline.py --env prod"
"$PY" pipeline.py --env prod

echo; echo ">>> 3. prod, with an env-var override (how a scheduler does it)"
echo "    \$ PIPELINE_BATCH_SIZE=99 PIPELINE_DB_PASSWORD=hunter2 python3 pipeline.py --env prod"
PIPELINE_BATCH_SIZE=99 PIPELINE_DB_PASSWORD=hunter2 "$PY" pipeline.py --env prod

echo; echo ">>> 4. prod, with a CLI override (how you do it at 2am)"
echo "    \$ python3 pipeline.py --env prod --batch-size 1 --dry-run"
"$PY" pipeline.py --env prod --batch-size 1 --dry-run

line
cat <<'TXT'
Four different behaviours. pipeline.py was never edited, and never once
mentions dev, test or prod.

  defaults  ->  config[env]  ->  env vars  ->  CLI flags
  (lowest precedence)                          (highest)

Note the last column: every value tells you where it came from. When a run
misbehaves at 2am, that column is the whole investigation.

And the password never appears in config.yaml. Secrets come from the
environment - config is for settings, not credentials.
TXT
line
