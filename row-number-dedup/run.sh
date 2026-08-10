#!/usr/bin/env bash
#==============================================================================
# run.sh - the latest-row-per-key dedup, and the tie-break that makes it correct.
#          Reads config/queries.sql (one source of truth), runs each block on
#          DuckDB, and shows the result.
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

.venv/bin/python - <<'PYCODE'
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
        else: line += word + " "
    out.append(line.rstrip()); return "\n".join(out)

raw = open("config/queries.sql").read()
blocks = [b for b in re.split(r'(?=-- @label:)', raw) if '@label:' in b]
bar = "=" * 78
print(bar); print("ROW_NUMBER() DEDUP - THE LATEST RECORD PER KEY (AND THE TIE-BREAK)")
print("Keep one row per customer: the newest. The tie-break is the part people miss.")
print(bar)
for b in blocks:
    label = re.search(r'-- @label:\s*(.+)', b).group(1).strip()
    note  = re.search(r'-- @note:\s*(.+)', b).group(1).strip()
    sql = "\n".join(l for l in b.splitlines() if not l.strip().startswith("-- @")).strip()
    print("\n" + "-" * 78); print(label); print("-" * 78)
    for l in sql.splitlines(): print("   " + l)
    print()
    print(fmt(con.sql(sql)))
    print(); print(wrap("takeaway: " + note))
print("\n" + bar)
print("Dedup rule: ORDER BY your recency column PLUS a unique tie-breaker; use")
print("ROW_NUMBER. When to reach for each (they only differ on ties):")
print("  ROW_NUMBER  -> keep exactly one per key (dedup). Robust to ties.")
print("  RANK        -> top-N with ties, competition-style: gaps show how many")
print("                 are ahead (1, 1, 3).")
print("  DENSE_RANK  -> top-N distinct values, no gaps (1, 1, 2): e.g. rows in")
print("                 the top 3 distinct salary bands.")
print(bar)
PYCODE
