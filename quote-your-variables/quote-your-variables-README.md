# Quote your variables - the space in a filename that broke prod

**In one line:** an unquoted `$var` in bash is **word-split** on `IFS` (space, tab, newline) and then
**glob-expanded**. So `rm $file` on a file named `Q3 report.csv` runs `rm Q3 report.csv` - two
arguments - and deletes the wrong files. Quote it: `"$var"`, `"$@"`, `"${arr[@]}"`. Pair it with
`set -u`. Run `bash run.sh` to watch each trap fire and get fixed.

---

## Why it happens (the order of expansions)

Bash expands a command line in a fixed order: brace -> tilde -> parameter/variable/command/arith ->
**word splitting** -> **filename expansion** -> quote removal. Two of those steps can change the
number of words, and both act on the result of an unquoted expansion:

1. **Word splitting** - "The shell scans the results of parameter expansion, command substitution,
   and arithmetic expansion that did not occur within double quotes for word splitting", splitting on
   each character of `IFS` (default space, tab, newline). So `$file` = `Q3 report.csv` becomes two
   words: `Q3` and `report.csv`.
2. **Filename expansion (globbing)** - each of those words is then scanned for `*`, `?`, `[...]`. A
   value like `*.csv` expands to every matching file; a stray `*` matches everything.

Double quotes stop both: a double-quoted expansion is **not** word-split and **not** glob-expanded,
so `"$file"` stays a single, literal argument.

## The four traps in `run.sh`

**1. A space in a filename**
```bash
file="Q3 report.csv"
rm $file      # BUG: rm Q3 report.csv  -> deletes 'Q3' and 'report.csv', leaves the target
rm "$file"    # FIX: rm 'Q3 report.csv' -> deletes exactly the target
```

**2. Passing arguments: `$@` vs `"$@"`**
`"$@"` is special - it expands to `"$1" "$2" ...`, one word per argument, preserving spaces.
Unquoted `$@` re-splits every argument.
```bash
process(){ for f in "$@"; do handle "$f"; done; }   # correct: 2 files stay 2 files
```
`"$*"` is different again: it joins all parameters into a single word separated by the first
character of `IFS`. For iteration you almost always want `"$@"`.

**3. A value that contains a glob**
```bash
v="*.csv"
echo $v       # BUG: expands to a.csv b.csv c.csv (whatever is in the directory)
echo "$v"     # FIX: the literal *.csv
```

**4. `set -u` catches the typo**
An unset variable normally expands to nothing, so a mistyped `$taget` silently becomes an empty
string - `rm -rf "/srv/$taget/cache"` turns into `rm -rf "/srv//cache"`. `set -u` (nounset) turns
that unset reference into an error and stops the script before it acts on the wrong path.

## The habit

```bash
set -euo pipefail                 # -u: unset var = error; -e: stop on error; pipefail: catch pipe failures
for f in "$@"; do                 # always quote "$@"
  process "$f"                    # always quote "$var"
done
```

- Quote **every** expansion that could hold a path, a value, or user input: `"$var"`, `"$@"`,
  `"${arr[@]}"`, `"$(cmd)"`.
- The safe exceptions (no spaces, no globs) are the shell's own numeric specials: `$#`, `$?`, `$$`,
  `$!`. Quoting them anyway does no harm.
- Iterate files with a glob (`for f in ./*.csv`) or `find ... -print0 | xargs -0`, never `for f in $(ls)`.

## Run it (one click, runs anywhere, idempotent)

```bash
bash run.sh
```

No account, no dependencies beyond bash. Everything happens in a throwaway temp dir that is cleaned
up on exit, so it is safe to re-run. The script tees its own output to `output/output.txt`, so your
local run is captured automatically.

## Files

```
quote-your-variables/
|-- run.sh                the four traps, buggy vs fixed, in a safe temp dir
|-- output/output.txt     captured real run
```