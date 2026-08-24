-- NULL is not a value: the NOT IN trap, and three-valued logic (SQL / DuckDB)
-- Intent: keep orders whose customer is NOT in the excluded list -> expect 1, 3, 5.

-- ============================ setup ============================
CREATE TABLE orders(customer_id INTEGER);
INSERT INTO orders VALUES (1),(2),(3),(4),(5);

CREATE TABLE excluded_customers(customer_id INTEGER);
INSERT INTO excluded_customers VALUES (2),(4),(NULL);   -- one NULL slipped in

-- @@ 1. NOT IN  (the trap - looks right, returns ZERO rows)
SELECT customer_id
FROM orders
WHERE customer_id NOT IN (SELECT customer_id FROM excluded_customers)
ORDER BY customer_id;

-- @@ 2. NOT EXISTS  (NULL-safe fix - the one to reach for)
SELECT customer_id
FROM orders o
WHERE NOT EXISTS (
  SELECT 1 FROM excluded_customers e WHERE e.customer_id = o.customer_id
)
ORDER BY customer_id;

-- @@ 3. NOT IN + IS NOT NULL  (fix by filtering the NULLs out of the subquery)
SELECT customer_id
FROM orders
WHERE customer_id NOT IN (
  SELECT customer_id FROM excluded_customers WHERE customer_id IS NOT NULL
)
ORDER BY customer_id;

-- @@ 4. Three-valued logic: any comparison with NULL is UNKNOWN, not TRUE/FALSE
SELECT '1 = NULL'            AS expr, (1 = NULL)             AS result
UNION ALL SELECT '1 <> NULL',            (1 <> NULL)
UNION ALL SELECT 'NULL = NULL',          (NULL = NULL)
UNION ALL SELECT '1 IN (2,4,NULL)',      (1 IN (2,4,NULL))
UNION ALL SELECT '1 NOT IN (2,4,NULL)',  (1 NOT IN (2,4,NULL));
