#!/usr/bin/env bash
#==============================================================================
# run.sh - "rm $file deleted two files. The filename had a space in it."
#
# An unquoted $var is WORD-SPLIT on IFS (space/tab/newline) and then GLOB-expanded.
# Quote it - "$var", "$@", "${arr[@]}" - and pair with set -u.
# Runs anywhere (bash only). Safe: everything happens in a throwaway temp dir.
# Idempotent. Captures this run's output to output/output.txt.
#==============================================================================
set -o pipefail
cd "$(dirname "$0")"
OUT="output/output.txt"; mkdir -p output
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

hr(){ printf '\n=== %s ===\n' "$1"; }
mkfiles(){ : > "Q3 report.csv"; : > "Q3"; : > "report.csv"; }
count(){ echo "received $# arg(s): $(printf '[%s] ' "$@")"; }
pass_unquoted(){ count $@;  }   # BUG: unquoted - each arg re-split
pass_quoted(){   count "$@"; }  # FIX: quoted - args preserved
file="Q3 report.csv"

{
  hr '1. A space in a filename:  rm $file   vs   rm "$file"'
  ( mkdir -p "$work/bug" && cd "$work/bug" && mkfiles
    rm $file 2>/dev/null || true                    # BUG: word-split into two args -> 'Q3' 'report.csv'
    echo "  rm \$file    -> survivors: $(ls | sed 's/.*/[&]/' | tr '\n' ' ')  (deleted the WRONG two; target survived)" )
  ( mkdir -p "$work/fix" && cd "$work/fix" && mkfiles
    rm "$file"                                       # FIX: one argument -> exactly the target
    echo "  rm \"\$file\"  -> survivors: $(ls | sed 's/.*/[&]/' | tr '\n' ' ')  (deleted exactly the target)" )

  hr '2. Passing arguments:  $@   vs   "$@"'
  echo "  args: \"Q3 report.csv\" \"April data.csv\""
  printf '  $@    -> '; pass_unquoted "Q3 report.csv" "April data.csv"
  printf '  "$@"  -> '; pass_quoted   "Q3 report.csv" "April data.csv"

  hr '3. A value that contains a glob:  echo $v   vs   echo "$v"'
  ( mkdir -p "$work/glob" && cd "$work/glob" && : > a.csv && : > b.csv && : > c.csv
    v="*.csv"
    echo "  echo \$v    -> $(echo $v)   (glob-expanded to matching files)"
    echo "  echo \"\$v\"  -> $(echo "$v")           (literal, as intended)" )

  hr '4. set -u catches the typo before it targets the wrong path'
  echo "  intent: rm -rf \"/srv/\$target/cache\"  - but you typed \$taget"
  echo "  no set -u: \$taget is empty -> rm -rf \"/srv//cache\"  (silent, dangerous)"
  err="$( ( set -u; : "$taget" ) 2>&1 || true )"
  echo "  set -u:    ${err##*: }  <- caught, script stops"

  echo ""
  echo "=================================================================="
  echo ' Always quote: "$var"  "$@"  "${arr[@]}".  Add set -u.  Unquoted = word-split + glob.'
  echo "=================================================================="
} 2>&1 | tee "$OUT"

echo ""
echo "Captured to $OUT"
