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

line; echo "CONFIG-DRIVEN PYTHON - the same code, run four different ways"; line

echo; echo ">>> 1. TEST environment - just the defaults"
echo "    \$ python3 pipeline.py --env dev"
"$PY" pipeline.py --env dev

echo; echo ">>> 2. LIVE environment - same command, different settings"
echo "    \$ python3 pipeline.py --env prod"
"$PY" pipeline.py --env prod

echo; echo ">>> 3. LIVE, with a quick override from the environment (how a scheduler slips a value in)"
echo "    \$ PIPELINE_BATCH_SIZE=99 PIPELINE_DB_PASSWORD=hunter2 python3 pipeline.py --env prod"
PIPELINE_BATCH_SIZE=99 PIPELINE_DB_PASSWORD=hunter2 "$PY" pipeline.py --env prod

echo; echo ">>> 4. LIVE, with a one-off override typed on the command line"
echo "    \$ python3 pipeline.py --env prod --batch-size 1 --dry-run"
"$PY" pipeline.py --env prod --batch-size 1 --dry-run

line
cat <<'TXT'
Four different behaviours - and the program was never edited. Only the
settings changed. It never once mentions "test" or "live".

A setting can come from four places. The most specific one wins:

  default  ->  this environment's settings  ->  environment variable  ->  command line
  (base value)                                                          (wins)

The "came from" column tells you which one won for every setting - so when a
run misbehaves, you look instead of guessing.

And the password never appears in the settings file. Secrets come from the
environment. The settings file is for settings, not passwords.
TXT
line
