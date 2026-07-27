#!/usr/bin/env bash
#==============================================================================
# run.sh - the window-function mental model, proved on DuckDB.
#          Reads config/queries.sql (one source of truth), runs each block,
#          prints the SQL, the result, and the takeaway.
# Requires: python3 + python3-venv (WSL Ubuntu: sudo apt install -y python3-venv).
#           A local .venv is created on first run; system Python is untouched.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

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

"$PY" - <<'PYCODE'
import re, duckdb

con = duckdb.connect()
con.execute(open("config/seed.sql").read())

def fmt(rel):
    cols = list(rel.columns)
    rows = [["" if v is None else str(v) for v in r] for r in rel.fetchall()]
    grid = [cols] + rows
    w = [max(len(g[i]) for g in grid) for i in range(len(cols))]
    def isnum(i):
        vals = [r[i] for r in rows if r[i] != ""]
        try: return bool(vals) and all(float(v) == float(v) for v in vals)
        except ValueError: return False
    num = [isnum(i) for i in range(len(cols))]
    def cell(row, i): return row[i].rjust(w[i]) if num[i] else row[i].ljust(w[i])
    return "\n".join("  " + "  ".join(cell(r, i) for i in range(len(cols))).rstrip() for r in grid)

def wrap(text, width=74, indent="   "):
    out, line = [], indent
    for word in text.split():
        if len(line) + len(word) + 1 > width:
            out.append(line.rstrip()); line = indent + word + " "
        else:
            line += word + " "
    out.append(line.rstrip())
    return "\n".join(out)

raw = open("config/queries.sql").read()
# split into blocks on the @label marker
blocks = re.split(r'(?=-- @label:)', raw)
blocks = [b for b in blocks if '@label:' in b]

bar = "=" * 78
print(bar)
print("WINDOW FUNCTIONS - THE MENTAL MODEL")
print("For each row, a window function looks at a WINDOW of related rows")
print("and returns a value - without collapsing your rows into groups.")
print(bar)

for b in blocks:
    label = re.search(r'-- @label:\s*(.+)', b).group(1).strip()
    note  = re.search(r'-- @note:\s*(.+)', b).group(1).strip()
    sql = "\n".join(l for l in b.splitlines() if not l.strip().startswith("-- @")).strip()
    print("\n" + "-" * 78)
    print(label)
    print("-" * 78)
    for l in sql.splitlines():
        print("   " + l)
    print()
    print(fmt(con.sql(sql)))
    print()
    print(wrap("takeaway: " + note))

print("\n" + bar)
print("THE ONE-SENTENCE MODEL")
print(bar)
print(wrap("PARTITION BY chooses which rows are in the window. ORDER BY orders "
           "them. For an AGGREGATE (SUM, AVG, COUNT), a frame then decides how "
           "much of that ordered set to include - and by default ORDER BY "
           "shrinks it to 'everything up to this row', which is why you get a "
           "running total. Ranking (ROW_NUMBER, RANK) and LAG/LEAD ignore the "
           "frame - they always see the whole ordered partition."))
PYCODE
