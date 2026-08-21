#!/usr/bin/env bash
#==============================================================================
# run.sh - 10 awk one-liners every data engineer should own.
#          Builds a small deterministic CSV + a lookup table, then runs each
#          one-liner and prints the command with its result. awk streams line
#          by line, so the SAME one-liners run on an 8GB file in constant memory.
# Requires: awk (standard on Linux/macOS; on Windows use WSL or Git Bash). No
#           account, no pip, no build.
# Usage:    bash run.sh
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
command -v awk >/dev/null 2>&1 || { echo "awk is required (standard on Linux/macOS; Windows: WSL or Git Bash)"; exit 1; }

# ---------------------------------------------------------------------------
# OPTIONAL stress test - prove it scales:  bash run.sh stress [GB]   (default 8)
# STREAMS generated rows straight through awk - nothing is written to disk, so
# there is no big file to fill the OS page cache or to clean up afterwards. The
# consumer runs under a 200MB memory cap (ulimit -v); if it were loading the
# data instead of streaming, it would be killed instantly.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "stress" ]; then
  GB="${2:-2}"
  rows=$(( GB * 22500000 ))                    # ~22.5M rows per GB (~41 bytes/row)
  echo "Streaming ~${GB}GB of generated rows THROUGH awk (nothing written to disk)."
  echo "Memory stays flat at ANY size - that is the point. Generation is CPU-bound (~20-40s/GB)."
  t0=$(date +%s)
  awk -v n="$rows" 'BEGIN{
    OFS=",";
    split("US,UK,IN,AU,DE",C,","); split("widget,gadget,gizmo,doohickey",P,",");
    for(i=1;i<=n;i++) print i,"2024-02-02",C[(i%5)+1],"cust_" sprintf("%04d",(i%500)+1),P[(i%4)+1],((i*37)%1000)+1,((i*13)%200);
  }' | ( ulimit -v 204800; awk -F',' '
        $7>100 {m++}
        {s[$3]+=$6}
        END{ print "  rows with score>100: " m; print "  total amount per country:"; for(k in s) print "    "k" "s[k]; }
      ' )
  echo "  elapsed: $(( $(date +%s)-t0 ))s for ~${GB}GB, with awk RAM capped at 200MB throughout."
  echo "  Nothing was written to disk. The cap proves awk streamed the data, never loaded it."
  exit 0
fi


# fact table: 100,000 orders, 7 columns, generated deterministically (values
# derived from the row number, not random), so the numbers reproduce.
# columns: 1 order_id 2 order_date 3 country 4 customer_id 5 product 6 amount 7 score
awk 'BEGIN{
  OFS=",";
  print "order_id,order_date,country,customer_id,product,amount,score";
  split("US,UK,IN,AU,DE", C, ","); split("widget,gadget,gizmo,doohickey", P, ",");
  for(i=1;i<=100000;i++){
    print i, "2024-" sprintf("%02d",(i%12)+1) "-" sprintf("%02d",(i%28)+1), \
          C[(i%5)+1], "cust_" sprintf("%04d",(i%500)+1), P[(i%4)+1], \
          ((i*37)%1000)+1, ((i*13)%200);
  }
}' > orders.csv
# small lookup table for the two-file join (country -> region)
printf 'country,region\nUS,Americas\nUK,EMEA\nDE,EMEA\nIN,APAC\nAU,APAC\n' > regions.csv

bar(){ printf '%s\n' "----------------------------------------------------------------------"; }
echo "======================================================================"
echo "10 awk one-liners every data engineer should own"
echo "======================================================================"
echo "Sample: orders.csv - $(awk 'END{print NR-1}' orders.csv) rows, 7 columns; regions.csv - 5-row lookup."
echo "awk streams line by line, so the same one-liners run on an 8GB file."
echo ""

bar; echo "1. Extract a column, with a condition"
echo "   awk -F',' 'NR>1 && \$7 > 100 {print \$4}' orders.csv"
echo "   -> customer_id (col 4) where score (col 7) > 100. First 3:"
awk -F',' 'NR>1 && $7>100 {print "   "$4; if(++c==3) exit}' orders.csv
echo "   ($(awk -F',' 'NR>1 && $7>100 {n++} END{print n}' orders.csv) rows match)"; echo ""

bar; echo "2. Conditional sum"
echo "   awk -F',' 'NR>1 && \$3==\"US\" {s+=\$6} END{print s}' orders.csv"
echo "   -> total amount for US: $(awk -F',' 'NR>1 && $3=="US" {s+=$6} END{print s}' orders.csv)"; echo ""

bar; echo "3. Group-by count (piped to sort for stable order)"
echo "   awk -F',' 'NR>1 {c[\$3]++} END{for(k in c) print k, c[k]}' orders.csv | sort"
echo "   -> orders per country:"
awk -F',' 'NR>1 {c[$3]++} END{for(k in c) print "   "k" "c[k]}' orders.csv | sort; echo ""

bar; echo "4. Group-by sum"
echo "   awk -F',' 'NR>1 {s[\$3]+=\$6} END{for(k in s) print k, s[k]}' orders.csv | sort"
echo "   -> total amount per country:"
awk -F',' 'NR>1 {s[$3]+=$6} END{for(k in s) print "   "k" "s[k]}' orders.csv | sort; echo ""

bar; echo "5. Count rows matching a filter"
echo "   awk -F',' 'NR>1 && \$7>100 {n++} END{print n}' orders.csv"
echo "   -> rows with score > 100: $(awk -F',' 'NR>1 && $7>100 {n++} END{print n}' orders.csv)"; echo ""

bar; echo "6. Dedup without sorting (keeps first-seen order)"
echo "   awk -F',' 'NR>1 && !seen[\$4]++ {print \$4}' orders.csv"
echo "   -> unique customers, in first-seen order. First 3:"
awk -F',' 'NR>1 && !seen[$4]++ {print "   "$4; if(++c==3) exit}' orders.csv
echo "   ($(awk -F',' 'NR>1 && !seen[$4]++ {n++} END{print n}' orders.csv) unique customers)"; echo ""

bar; echo "7. Average"
echo "   awk -F',' 'NR>1 {s+=\$6; n++} END{printf \"%.2f\\n\", s/n}' orders.csv"
echo "   -> average amount: $(awk -F',' 'NR>1 {s+=$6;n++} END{printf "%.2f", s/n}' orders.csv)"; echo ""

bar; echo "8. Min / max of a column"
echo "   awk -F',' 'NR>1 {if(\$6>mx)mx=\$6} END{print mx}' orders.csv"
echo "   -> max amount: $(awk -F',' 'NR>1 {if($6>mx)mx=$6} END{print mx}' orders.csv)  min amount: $(awk -F',' 'NR>1 {if(mn==""||$6<mn)mn=$6} END{print mn}' orders.csv)"; echo ""

bar; echo "9. Derive a new column (add a value band)"
echo "   awk -F',' 'BEGIN{OFS=\",\"} NR>1 {print \$0, (\$6>=100?\"high\":\"low\")}' orders.csv"
echo "   -> each row with a trailing high/low flag. First 3:"
awk -F',' 'BEGIN{OFS=","} NR>1 {print "   "$0, ($6>=100?"high":"low"); if(++c==3) exit}' orders.csv; echo ""

bar; echo "10. Two-file lookup / join (enrich orders with region)"
echo "   awk -F',' 'NR==FNR{r[\$1]=\$2; next} FNR>1{print \$4, r[\$3]}' regions.csv orders.csv"
echo "   -> customer_id and its region, joined on country. First 3:"
awk -F',' 'NR==FNR{r[$1]=$2; next} FNR>1{print "   "$4, r[$3]; if(++c==3) exit}' regions.csv orders.csv; echo ""

echo "======================================================================"
echo "awk holds only the group keys in memory (5 countries, 500 customers),"
echo "never the whole file - which is why it scales to files you can't open."
echo "======================================================================"
