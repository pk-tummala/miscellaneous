-- seed.sql — five sales rows, small enough to verify every result by eye.
-- Each rep sells on a distinct day (so a running total is a clean cumulative
-- sum), and North's Ana and Ben tie on amount (so the ranking demo has a tie).
DROP TABLE IF EXISTS sales;
CREATE TABLE sales (region VARCHAR, rep VARCHAR, sale_day INTEGER, amount INTEGER);
INSERT INTO sales VALUES
  ('North', 'Ana', 1, 100),
  ('North', 'Ben', 2, 100),
  ('North', 'Cy',  3,  60),
  ('South', 'Dee', 1, 200),
  ('South', 'Eli', 2,  50);
