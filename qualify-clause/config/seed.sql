-- seed.sql — five sales rows, small enough to check every result by eye.
DROP TABLE IF EXISTS sales;
CREATE TABLE sales (region VARCHAR, rep VARCHAR, amount INTEGER);
INSERT INTO sales VALUES
  ('North', 'Ana', 100),
  ('North', 'Ben',  90),
  ('North', 'Cy',   60),
  ('South', 'Dee', 200),
  ('South', 'Eli',  50);
