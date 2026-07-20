# `set -euo pipefail`

Your shell script failed in the middle and exited `0`. The scheduler marked it
green. Nobody investigated, because nobody investigates a job that succeeded.

This folder is the same script twice — once without the flags, once with — so you
can watch the lie happen.

## Run it

```bash
bash run.sh
```

Bash. Nothing else. Captured output is in [`output.txt`](output.txt).

## What you'll see

`without_flags.sh` contains three real bugs:

1. It reads a file that doesn't exist.
2. It prints `$ROW_COUNT` — a typo, the variable set was `ROWCOUNT`.
3. It runs a pipeline whose first stage dies.

All three fail. The script prints **"done — load complete"** and exits **`0`**.

`with_flags.sh` is byte-identical apart from one line. It stops at bug one and
exits **`1`**.

## The three flags

| Flag | What it does | The bug it catches |
|---|---|---|
| `-e` | Exit on the first command that fails | The failed extract that carried on |
| `-u` | Exit if an unset variable is referenced | The `ROWCOUNT` / `ROW_COUNT` typo |
| `-o pipefail` | A pipeline fails if *any* stage fails, not just the last | `cat missing \| grep -c ""` returning 0 |

Default bash keeps going after a failure and reports a pipeline's exit status
from its **last** command only. Both defaults make sense for an interactive
shell. Both are dangerous in a scheduled job.

## The honest caveat

`-e` is not a force field. It's deliberately ignored when a command's failure is
already being handled — inside an `if` condition, on the left of `&&`, or when a
function's result is being tested. It also won't save you from a command that
fails *successfully*, like `grep` finding no matches.

When you genuinely expect something to fail, say so:

```bash
set +e; risky_command; rc=$?; set -e   # handle it yourself
risky_command || true                   # or explicitly don't care
```

Being explicit about the failures you tolerate is the whole point. The flags
just stop you tolerating the ones you never meant to.

## Files

```
set-euo-pipefail/
├── set-euo-pipefail-README.md   this file
├── run.sh             ./run.sh → runs both, prints the exit codes
├── without_flags.sh   three bugs, exits 0, reports success
├── with_flags.sh      identical + one line, exits 1 at the first bug
└── output/
    └── output.txt     captured expected output
```
