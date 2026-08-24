#!/usr/bin/env python3
"""Run three_valued_logic.sql against DuckDB and print each labelled query with its result."""
import duckdb, re, pathlib

sql = pathlib.Path("three_valued_logic.sql").read_text()
setup, *blocks = re.split(r"^-- @@ ", sql, flags=re.MULTILINE)
con = duckdb.connect()
con.execute(setup)  # everything before the first @@ marker

def show(rows):
    if not rows: return "   (0 rows)"
    out = []
    for r in rows:
        cells = ["UNKNOWN" if v is None else str(v) for v in r]
        out.append("   " + " | ".join(cells))
    return "\n".join(out)

bar = "=" * 70
print(bar); print("NULL is not a value: the NOT IN trap (three-valued logic)"); print(bar)
print("orders.customer_id            : 1, 2, 3, 4, 5")
print("excluded_customers.customer_id: 2, 4, NULL   <- one NULL slipped in")
print("Intent: orders whose customer is NOT excluded  ->  expect 1, 3, 5\n")

labels = {
 "1": ("NOT IN  (the trap)", "Nothing errored. One NULL returned zero rows."),
 "2": ("NOT EXISTS  (NULL-safe fix)", "Correct: 1, 3, 5."),
 "3": ("NOT IN + IS NOT NULL  (filter the NULLs)", "Correct: 1, 3, 5."),
 "4": ("Three-valued logic: comparisons with NULL", "Every one is UNKNOWN - never TRUE."),
}
for blk in blocks:
    num = blk.split(".", 1)[0].strip()
    query = blk.split("\n", 1)[1]
    title, note = labels.get(num, (blk.splitlines()[0], ""))
    rows = con.execute(query).fetchall()
    print("-" * 70)
    print(f"{num}. {title}")
    print(show(rows))
    print(f"   -> {note}\n")

print(bar)
print("WHERE keeps a row only when the predicate is TRUE.")
print("UNKNOWN (any NULL comparison) is dropped, just like FALSE - silently.")
print(bar)
