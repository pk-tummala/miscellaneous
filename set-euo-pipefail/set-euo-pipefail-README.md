# `set -euo pipefail`

**In one line:** three tiny flags that stop a broken shell script from reporting
"success" when it actually failed.

---

## The 30-second background (so the rest makes sense)

Every command your shell runs finishes with an **exit code**: `0` means success,
anything else means failure. Schedulers — cron, Airflow, Control-M, a CI job —
watch that number. `0` shows up as a green tick; non-zero fires an alert.

Here's the problem: **by default, a bash script keeps running after a command
fails, and reports the exit code of only its *last* command.** So a script can
fail three times in the middle, reach the end, exit `0`, and the scheduler happily
marks it green. Nobody investigates — because nobody investigates a job that
succeeded.

This folder is the same script twice — once without the flags, once with — so you
can watch that lie happen and then watch it get fixed.

## Run it

```bash
bash run.sh
```

Bash, nothing else — no Python, no venv. Captured output is in
[`output/output.txt`](output/output.txt).

## What you'll see

`without_flags.sh` is a normal-looking load script with three real bugs planted in
it:

1. It reads a file that doesn't exist.
2. It prints `$ROW_COUNT` — but the variable was actually set as `ROWCOUNT` (a
   one-character typo that a human eye slides right past).
3. It runs a pipeline whose first command dies.

All three fail. And yet the script prints **"done — load complete"** and exits
**`0`**. To the scheduler, that run was a success.

`with_flags.sh` is byte-for-byte identical except for one added line —
`set -euo pipefail` at the top. It stops at the very first bug and exits **`1`**.
Same code, same bugs, completely different outcome.

## What each flag does

| Flag | In plain words | The bug it catches here |
|---|---|---|
| `-e` | Stop the moment any command fails, instead of carrying on. | The missing-file read that the script otherwise ignored. |
| `-u` | Stop if you use a variable that was never set. | The `ROWCOUNT` / `ROW_COUNT` typo — caught instantly instead of printing a blank. |
| `-o pipefail` | In a pipeline (`a \| b \| c`), fail if **any** stage fails — not just the last one. | `cat missing \| grep -c ""` — `cat` dies, but `grep` succeeds, so the pipeline "passes" without this. |

Both defaults bash ships with — keep going after errors, and judge a pipeline by
its last command — make sense when you're typing commands by hand and can see what
happened. In an **unattended, scheduled job**, where the only thing anyone sees is
that exit code, they're dangerous.

## The honest caveat

`set -e` is insurance, not a force field. Bash deliberately ignores it when a
failure is *already* being handled — inside an `if` condition, on the left of an
`&&`, or when a function's result is being tested. It also won't save you from a
command that "fails successfully," like `grep` finding no matches (that's a normal,
expected non-match, not an error).

So when you genuinely expect a command to fail, say so explicitly:

```bash
set +e; risky_command; rc=$?; set -e   # turn -e off, handle the result yourself
risky_command || true                   # or: I know this can fail, and I don't care
```

Being explicit about the failures you *tolerate* is the whole point. The flags
just stop you from tolerating the ones you never meant to.

## Files

```
set-euo-pipefail/
├── set-euo-pipefail-README.md   this file
├── run.sh             bash run.sh → runs both scripts, prints the exit codes
├── without_flags.sh   three bugs, exits 0, reports success
├── with_flags.sh      identical + one line, exits 1 at the first bug
└── output/
    └── output.txt     captured expected output
```
