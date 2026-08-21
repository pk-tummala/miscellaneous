# 10 awk one-liners every data engineer should own

**In one line:** the file is 8 GB, you need column 4 where column 7 > 100, and it won't open
in a text editor or fit in pandas. `awk` streams it line by line and gives you the answer in
one line of shell - no imports, no cluster, no waiting.

---

## Run it

```bash
bash run.sh
```

Only needs `awk` (standard on Linux and macOS; on Windows use WSL or Git Bash). No account,
no pip, no build. `run.sh` generates a small deterministic `orders.csv` and runs every
one-liner below; captured output is in [`output/output.txt`](output/output.txt).

To prove it scales, `bash run.sh stress` *streams* ~2 GB of generated rows straight through awk under a 200 MB
memory cap - nothing is written to disk, so there is no file to fill the OS page cache or to
clean up. Memory stays flat at any size, so a couple of GB is enough to see it; pass a bigger
number (e.g. `stress 8`) for a longer run.

## The sample

`orders.csv` - 100,000 rows, 7 comma-separated columns:

```
order_id, order_date, country, customer_id, product, amount, score
```

A tiny `regions.csv` (country -> region) is generated too, for the join in #10. The demo
files are small so you can see them, but nothing here loads a file into memory - so the same
commands run on an 8 GB file the same way (more on that at the end).

## The one-liners

**1. Extract a column, with a condition** - the whole reason to reach for awk.

```bash
awk -F',' 'NR>1 && $7 > 100 {print $4}' orders.csv
```

`-F','` splits on commas; `$4`, `$7` are fields; `NR>1` skips the header. Prints the
customer_id of every row whose score is over 100 (49,500 of them here).

**2. Conditional sum** - a filtered total, no spreadsheet.

```bash
awk -F',' 'NR>1 && $3=="US" {s+=$6} END{print s}' orders.csv
```

Accumulate `amount` while `country` is US; print once at the `END`. Result: 9,970,000.

**3. Group-by count** - a pivot table in 40 characters.

```bash
awk -F',' 'NR>1 {c[$3]++} END{for(k in c) print k, c[k]}' orders.csv | sort
```

`c[$3]++` is an associative array keyed by country. Each country here has 20,000 orders.
(awk's array iteration order is unspecified, so pipe through `sort` for stable output.)

**4. Group-by sum** - totals per key.

```bash
awk -F',' 'NR>1 {s[$3]+=$6} END{for(k in s) print k, s[k]}' orders.csv | sort
```

Same idea, summing `amount` per country instead of counting.

**5. Count rows matching a filter** - one pass, one process, and it can test a numeric
column (`$7>100`) that `grep` can't express directly.

```bash
awk -F',' 'NR>1 && $7>100 {n++} END{print n}' orders.csv
```

Result: 49,500 rows with score over 100.

**6. Dedup without sorting** - keeps first-seen order, one pass.

```bash
awk -F',' 'NR>1 && !seen[$4]++ {print $4}' orders.csv
```

`!seen[$4]++` is true only the first time a value appears, so duplicates are dropped without
a `sort -u` (and without reordering). 500 unique customers here. For whole-line dedup:
`awk '!seen[$0]++' file`.

**7. Average** - sum and count in one pass, formatted.

```bash
awk -F',' 'NR>1 {s+=$6; n++} END{printf "%.2f\n", s/n}' orders.csv
```

Result: 500.50.

**8. Min / max of a column** - a running comparison, no sort.

```bash
awk -F',' 'NR>1 {if($6>mx) mx=$6} END{print mx}' orders.csv
```

Keep the largest value seen so far; print it at the `END`. Max amount here is 1000 (min, with
`if(mn=="" || $6<mn) mn=$6`, is 1).

**9. Derive a new column** - add a computed field, re-emit the row.

```bash
awk -F',' 'BEGIN{OFS=","} NR>1 {print $0, ($6>=100 ? "high" : "low")}' orders.csv
```

`OFS=","` sets the output separator; the ternary tags each row `high` or `low` by amount and
prints the original line plus the new field. This is the everyday ETL move: add a derived
column in one pass.

**10. Two-file lookup / join** - the pattern that separates people who own awk.

```bash
awk -F',' 'NR==FNR{r[$1]=$2; next} FNR>1{print $4, r[$3]}' regions.csv orders.csv
```

`NR==FNR` is true only while the FIRST file is being read, so the first block builds a lookup
(`country -> region`) and `next` skips to the following line. Once the second file starts,
`NR==FNR` is false, so each order prints its customer_id and the region looked up by country.
A hash join across two files, in one line.

## Why this scales to files you can't open

awk reads **one line at a time** and never holds the whole file in memory. For filtering,
extraction, and running totals (1, 2, 5, 7) memory is constant no matter how big the file
is. For the group-by lines (3, 4, 6) awk keeps only the **distinct keys** in memory - here 5
countries and 500 customers, a few kilobytes - not the 100,000 rows. That is why the same
one-liner that runs on this 4 MB file runs just as happily on 8 GB or 800 GB: the cost is
the number of distinct groups, not the size of the file.

**This is tested, not asserted.** `bash run.sh stress` *streams* generated rows (2 GB by
default, or pass a size like `stress 8`) straight into awk **with memory capped at 200 MB** (`ulimit -v`) - nothing is written to
disk. If awk were loading the data it would be killed instantly; instead it streams through
and the run stays at a few MB of RAM (measured: the generator's peak RSS is ~2 MB). It is
CPU-bound at roughly 15-30 seconds per GB. Because nothing hits disk, there is no big file
and no OS page cache to fill - which is the right way to run this on a laptop.

A few habits worth keeping:
- `NR>1` skips a header row; `NR` is the current line number, `NF` the field count.
- Set the separator with `-F','` (or `-F'\t'` for TSV); default is any whitespace.
- Everything accumulates in the body and prints once in `END` - one pass over the data.

## Files

```
awk-one-liners/
|-- awk-one-liners-README.md   this file
|-- run.sh   bash run.sh -> generates orders.csv + regions.csv, runs every one-liner
|-- output/
    |-- output.txt   captured expected output
```

---

*Tested with mawk 1.3.4 (the default awk on Debian/Ubuntu); the one-liners are POSIX awk
and run on gawk and macOS/BSD awk too.
`run.sh` generates its data deterministically (values derived from the row number), so the
output is byte-identical across runs. orders.csv and regions.csv are regenerated on each
run and are not committed.*
