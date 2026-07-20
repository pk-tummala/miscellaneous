#!/usr/bin/env bash
#==============================================================================
# run.sh - MERGE, four engines: the runnable proof.
#
#   1. seed the target + staging tables
#   2. run the MERGE  -> show the target
#   3. run the SAME MERGE again -> show the target is IDENTICAL (idempotent)
#   4. run it against a source with duplicate keys -> show what breaks
#
# Requires: python3 + python3-venv (WSL Ubuntu: sudo apt install -y python3-venv).
#           A local .venv is created on first run and DuckDB installed into it -
#           your system Python is never touched (and PEP 668 never bites).
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

"$PY" - <<'PYCODE'
import duckdb, hashlib

con = duckdb.connect()

def fmt(query):
    """Pretty-print a result with no pandas dependency (duckdb only)."""
    rel = con.sql(query)
    cols = list(rel.columns)
    rows = [["" if v is None else str(v) for v in r] for r in rel.fetchall()]
    grid = [cols] + rows
    w = [max(len(g[i]) for g in grid) for i in range(len(cols))]
    def isnum(i):
        vals = [r[i] for r in rows if r[i] != ""]
        try:
            return bool(vals) and all(float(v) == float(v) for v in vals)
        except ValueError:
            return False
    num = [isnum(i) for i in range(len(cols))]
    def cell(row, i): return row[i].rjust(w[i]) if num[i] else row[i].ljust(w[i])
    return "\n".join("  ".join(cell(r, i) for i in range(len(cols))).rstrip() for r in grid)

def show(label):
    print(f"\n{label}")
    print(fmt("SELECT * FROM customer_dim ORDER BY customer_id"))

def fingerprint():
    rows = con.sql("SELECT * FROM customer_dim ORDER BY customer_id").fetchall()
    return hashlib.md5(str(rows).encode()).hexdigest()[:12]

seed  = open("config/seed.sql").read()
merge = open("config/merge_demo.sql").read()

print("=" * 68)
print("ONE IDEMPOTENT MERGE, FOUR ENGINES")
print("Runnable proof - DuckDB (ANSI MERGE, same shape as Oracle/Snowflake/Delta)")
print("=" * 68)

con.execute(seed)
show("[1] BEFORE - the target dimension")
print("\n    Today's staging delta:")
print(fmt("SELECT * FROM customer_stg ORDER BY customer_id"))

# --- first merge -----------------------------------------------------------
con.execute(merge)
show("[2] AFTER 1st MERGE - Bob updated, Dan inserted, Alice untouched")
fp1 = fingerprint()
print(f"\n    fingerprint: {fp1}")

# --- second merge, same source --------------------------------------------
con.execute(merge)
show("[3] AFTER 2nd MERGE - same source, run again")
fp2 = fingerprint()
print(f"\n    fingerprint: {fp2}")

print("\n" + "-" * 68)
if fp1 == fp2:
    print("IDEMPOTENT: the 2nd run changed nothing. Same input -> same state.")
else:
    print("NOT IDEMPOTENT: the 2nd run altered the target.")
print("-" * 68)

# --- the trap: duplicate keys in the source --------------------------------
print("\n" + "=" * 68)
print("THE TRAP - when the SOURCE has two rows for one key")
print("=" * 68)

print("\nSOURCE staging table (customer_stg_dupes) - the SAME key twice,")
print("with different values. This is the bug, sitting in the incoming data:")
print(fmt("SELECT * FROM customer_stg_dupes ORDER BY balance"))

print("\nTARGET customer_dim has exactly ONE row for customer_id = 2")
print("(it's a dimension - one row per key):")
print(fmt("SELECT * FROM customer_dim WHERE customer_id = 2"))

print("\nBoth SOURCE rows match that ONE target row, so MERGE has to pick a")
print("winner for the UPDATE. Running it...")

dupe_merge = merge.replace("customer_stg", "customer_stg_dupes")
try:
    con.execute(dupe_merge)
    result = con.sql("SELECT balance FROM customer_dim WHERE customer_id = 2").fetchone()[0]
    print(f"\nDuckDB did NOT raise an error. Bob's balance is now: {result}")
    print("It silently picked ONE of the two SOURCE rows. Which one is not")
    print("guaranteed - re-run this and it may land on the other value.")
    print("\nTARGET customer_dim after the merge - STILL one Bob, one row per key,")
    print("4 rows, no error. The target was never going to hold two Bobs:")
    print(fmt("SELECT * FROM customer_dim ORDER BY customer_id"))
    print("\nThat's the whole danger: the row count is right, the key is unique,")
    print("nothing errored - but the WRONG value quietly won. A corrupted table")
    print("looks EXACTLY like a healthy one. No tick, red or green, catches it.")
except Exception as e:
    print(f"\nDuckDB raised: {e}")

print("""
The engines DISAGREE here, and this is the whole lesson:

  Oracle      ORA-30926: unable to get a stable set of rows in the source
  Snowflake   errors by default (ERROR_ON_NONDETERMINISTIC_MERGE = TRUE)
  Delta       errors: multiple source rows matched a target row
  DuckDB      silently picks one  <-- you just saw this

Three engines fail loudly. One fails quietly. The quiet one is more dangerous,
because the run goes green and the number is simply wrong.

And no - a PRIMARY KEY does not save you on the tables you'd MERGE into:
  * Whether a PK is even enforced depends on the engine and table type:
      - Oracle, Teradata ................. enforced
      - Snowflake standard tables ........ informational only (NOT enforced)
      - Snowflake HYBRID tables (Unistore) enforced (an OLTP row-store type)
      - Databricks / Delta ............... informational only (NOT enforced)
    So "just add a PK" does nothing on a standard Snowflake or Delta table -
    which is exactly where your customer_dim lives.
  * And even where a PK IS enforced, it only catches a duplicate INSERT. It
    cannot see a non-deterministic UPDATE - MERGE overwriting a good value with
    the wrong one of two matching source rows. Row count stays right, the PK
    stays satisfied, the number is still wrong.

A constraint is a backstop, not a fix.

MERGE is only idempotent if the source has ONE ROW PER KEY.
Dedupe first - always. That's a ROW_NUMBER() away.
""")
PYCODE
