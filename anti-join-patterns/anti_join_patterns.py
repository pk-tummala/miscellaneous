#!/usr/bin/env python3
"""Three (well, four) ways to ask 'what's missing' - and how they diverge on NULLs.
Verified against the DuckDB subqueries docs (three-valued logic for IN / NOT IN)."""
import duckdb

con = duckdb.connect()  # in-memory; deterministic and idempotent
con.execute("""
CREATE TABLE customers(id INTEGER, name VARCHAR);
INSERT INTO customers VALUES (1,'Alice'),(2,'Bob'),(3,'Carol'),(4,'Dave');
CREATE TABLE orders(order_id INTEGER, customer_id INTEGER);
INSERT INTO orders VALUES (10,1),(11,2),(12,NULL);   -- one order has an UNKNOWN customer_id
""")

def fmt(v):
    return "NULL" if v is None else str(v)
def show(label, sql):
    rows = con.execute(sql).fetchall()
    got = ", ".join(fmt(r[0]) if len(r)==1 else f"{fmt(r[0])} {r[1]}" for r in rows) if rows else "(no rows)"
    print(f"  {label:<40} -> {got}")

print("PART 1 - a NULL in the SUBQUERY")
print("data:     orders.customer_id = [1, 2, NULL]     question: which customers have NO order?  (expect 3 Carol, 4 Dave)")
print()
show("NOT EXISTS",
     "SELECT c.id, c.name FROM customers c WHERE NOT EXISTS "
     "(SELECT 1 FROM orders o WHERE o.customer_id = c.id) ORDER BY c.id")
show("LEFT JOIN ... IS NULL (anti-join)",
     "SELECT c.id, c.name FROM customers c LEFT JOIN orders o ON o.customer_id = c.id "
     "WHERE o.order_id IS NULL ORDER BY c.id")
show("EXCEPT (set difference, NULL-safe)",
     "SELECT id FROM customers EXCEPT SELECT customer_id FROM orders ORDER BY id")
show("NOT IN (raw subquery)",
     "SELECT c.id, c.name FROM customers c WHERE c.id NOT IN (SELECT customer_id FROM orders) ORDER BY c.id")
show("NOT IN (WHERE customer_id IS NOT NULL)",
     "SELECT c.id, c.name FROM customers c "
     "WHERE c.id NOT IN (SELECT customer_id FROM orders WHERE customer_id IS NOT NULL) ORDER BY c.id")

print()
print("PART 2 - a NULL in the OUTER (probe) value")
con.execute("""
CREATE TABLE leads(id INTEGER);      INSERT INTO leads VALUES (1),(2),(NULL);   -- a lead with an unknown id
CREATE TABLE contacted(id INTEGER);  INSERT INTO contacted VALUES (1);          -- no NULLs here
""")
print("data:     leads.id = [1, 2, NULL]   contacted.id = [1]   question: which leads were NOT contacted?")
print()
show("NOT EXISTS",
     "SELECT l.id FROM leads l WHERE NOT EXISTS (SELECT 1 FROM contacted c WHERE c.id = l.id) ORDER BY l.id")
show("LEFT JOIN ... IS NULL",
     "SELECT l.id FROM leads l LEFT JOIN contacted c ON c.id = l.id WHERE c.id IS NULL ORDER BY l.id")
show("NOT IN (contacted has NO NULLs)",
     "SELECT l.id FROM leads l WHERE l.id NOT IN (SELECT id FROM contacted) ORDER BY l.id")

print()
print("=" * 72)
print(" Subquery NULL: NOT IN -> zero rows; the others are correct.")
print(" Outer NULL:    NOT IN drops the NULL-keyed row; NOT EXISTS / LEFT JOIN keep it.")
print(" Default to NOT EXISTS - NULL-safe on both sides, and the optimizer anti-joins it.")
print("=" * 72)
