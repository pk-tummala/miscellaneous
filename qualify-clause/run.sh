#!/usr/bin/env bash
#==============================================================================
# run.sh - QUALIFY vs the subquery, proved on DuckDB. Reads config/queries.sql
#          (one source of truth), runs each block, and shows the result — or the
#          error, for the block that is meant to fail.
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
        else:
            line += word + " "
    out.append(line.rstrip())
    return "\n".join(out)

raw = open("config/queries.sql").read()
blocks = [b for b in re.split(r'(?=-- @label:)', raw) if '@label:' in b]

bar = "=" * 78
print(bar)
print("QUALIFY - FILTER A WINDOW FUNCTION WITHOUT A SUBQUERY")
print("Task: keep the top-selling rep per region.")
print(bar)

for b in blocks:
    label = re.search(r'-- @label:\s*(.+)', b).group(1).strip()
    note  = re.search(r'-- @note:\s*(.+)', b).group(1).strip()
    expect_error = '@expect_error' in b
    sql = "\n".join(l for l in b.splitlines() if not l.strip().startswith("-- @")).strip()
    print("\n" + "-" * 78)
    print(label)
    print("-" * 78)
    for l in sql.splitlines():
        print("   " + l)
    print()
    try:
        rel = con.sql(sql)
        print(fmt(rel))
    except Exception as e:
        if expect_error:
            print("   -> rejected: " + str(e).splitlines()[0])
        else:
            raise
    print()
    print(wrap("takeaway: " + note))

print("\n" + bar)
print("QUALIFY is not standard SQL - it started in Teradata and is supported by")
print("Snowflake, Databricks, BigQuery and DuckDB. On Postgres or MySQL you still")
print("wrap the window in a subquery, exactly like block 2.")
print(bar)
PYCODE
