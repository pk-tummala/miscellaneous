# `set -euo pipefail`

**In one line:** three small flags that stop a broken shell script from reporting
"success" when it actually failed.

---

## The 30-second background (so the rest makes sense)

Every command your shell runs finishes with an **exit code**: `0` means success,
anything else means failure. Job schedulers and CI systems — Airflow, Control-M,
Jenkins, GitHub Actions — watch that number. `0` shows up as a green tick;
non-zero raises an alert.

(Plain `cron` is the odd one out, and worth knowing: it doesn't act on the exit
code at all. It emails whatever the job *printed*, so a silent failure is
invisible and a chatty success spams you. That's exactly why people wrap cron
jobs in a script that checks `$?` and only alerts on non-zero.)

Now the two bash defaults that cause the trouble:

1. **A script keeps running after a command fails**, and the script's own exit
   code is simply that of its **last** command. If the last line is a successful
   `echo`, the script exits `0` — no matter what went wrong earlier.
2. **A pipeline is judged by its last stage only.** The bash manual puts it
   plainly: *"The exit status of a pipeline is the exit status of the last command
   in the pipeline, unless the `pipefail` option is enabled."* So if the first
   stage dies and the last stage succeeds, the pipeline reports success.

Both defaults are sensible when you're typing commands by hand and can see what
happened. In an unattended, scheduled job — where the exit code is the *only*
thing anyone sees — they're dangerous.

## Run it

```bash
bash run.sh
```

Bash, nothing else — no Python, no venv. Captured output is in
[`output/output.txt`](output/output.txt).

## What you'll see

**Part 1** runs the same load script two ways. `without_flags.sh` has three real
bugs planted in it:

1. It reads a file that doesn't exist — `cat` fails with exit `1`.
2. It prints `$ROW_COUNT`, but the variable that was set is `ROWCOUNT` — a
   one-character typo the eye slides straight past.
3. It runs `cat missing_file | wc -l`. The first stage dies; `wc -l` cheerfully
   counts zero lines and exits `0`.

Two of those are outright command failures (both `cat` calls exit `1`); the
third isn't a failure at all — it's a variable that silently expands to nothing,
which is arguably worse. The script still prints **"done — load complete"** and
exits **`0`**, and records the row count as `0`. To a scheduler, that run was a
success.

Note what that means: the `cat:` errors *are* right there in the log. Nobody reads
the log, because the exit code said the job was fine. That's the whole failure
mode — the evidence exists, but nothing directs anyone to look at it.

`with_flags.sh` is identical except for one added line. It stops at the first bug
and exits **`1`**.

**Part 2** then proves each flag on its own. That part matters: because `-e`
halts the script at bug 1, bugs 2 and 3 are never reached — so the head-to-head
run alone doesn't actually show you what `-u` and `pipefail` do. Part 2 isolates
each flag so you can see all three working.

## What each flag does

| Flag | In plain words | The bug it catches here |
|---|---|---|
| `-e` | Exit as soon as a command fails, instead of carrying on. | The missing-file read the script otherwise ignored. |
| `-u` | Exit if you use a variable that was never set. | The `ROWCOUNT` / `ROW_COUNT` typo — caught instead of printing a blank. |
| `-o pipefail` | Judge a pipeline by **any** failing stage, not just the last. | `cat missing \| wc -l` — the dead first stage that `wc -l`'s success was hiding. |

On `pipefail`, the precise rule from the bash manual is worth knowing: with it
enabled, *"the return value of a pipeline is the value of the last (rightmost)
command to exit with a non-zero status, or zero if all commands in the pipeline
exit successfully."* It's disabled by default.

## The honest caveat

`set -e` is insurance, not a force field, and it cuts **both** ways.

**It's deliberately ignored in several places.** Per the bash manual, the shell
does not exit when the failing command is part of the test in an `if` statement,
part of the list following a `while` or `until`, part of any `&&` or `||` list
except the command following the final one, any command in a pipeline other than
the last, or when the return status is inverted with `!`.

**And it will stop your script on a failure you expected.** A non-zero exit
doesn't always mean something broke — `grep` exits `1` when it simply finds no
match. So `set -e; grep pattern file` kills the script on a perfectly normal
no-match. When you expect a non-zero result, say so explicitly:

```bash
set +e; risky_command; rc=$?; set -e   # turn -e off and handle it yourself
risky_command || true                   # I know this can fail, and I don't care
if ! grep -q pattern file; then ... fi  # a test, so -e ignores it anyway
```

Being explicit about the failures you *tolerate* is the whole point. The flags
just stop you tolerating the ones you never meant to.

## Three more gotchas worth knowing

These aren't in the demo, but they're the ones that bite people who already use
`set -euo pipefail` and assume they're covered. All three verified on bash 5.2.21.

**1. `local`, `export` and `declare` swallow the failure.**

```bash
set -e
f() { local rows=$(command_that_fails); echo "still here"; }   # -e does NOT fire
f
```

The exit status you get is that of `local` (which succeeded), not the command
substitution inside it. A plain `rows=$(command_that_fails)` *does* trigger `-e`
— it's the builtin in front that masks it. Split the declaration from the
assignment when the value comes from a command:

```bash
local rows          # declare
rows=$(command_that_fails)   # assign — now -e sees the real status
```

**2. Calling a function in an `if` disables `-e` for its entire body.**

```bash
set -e
f() { false; echo "kept going"; return 0; }
if f; then ... fi     # everything inside f runs with -e switched off
```

The manual's "part of the test in an `if` statement" exception applies to the
whole function, not just its return value. So a helper that looks protected
isn't, the moment someone calls it in a condition.

**3. `PIPESTATUS` is the finer-grained tool.**

`pipefail` tells you *that* a pipeline failed. `PIPESTATUS` tells you *which
stage* failed — it's an array holding every stage's exit code:

```bash
cat missing_file | wc -l
echo "${PIPESTATUS[@]}"      # -> 1 0   (cat failed, wc succeeded)
```

Capture it immediately — the next command overwrites it. Use `pipefail` as the
blanket safety net, and `PIPESTATUS` when you need to react to a specific stage.

## Files

```
set-euo-pipefail/
├── set-euo-pipefail-README.md   this file
├── run.sh             bash run.sh → both scripts head-to-head, then each flag proved
├── without_flags.sh   three bugs, exits 0, reports success
├── with_flags.sh      identical + one line, exits 1 at the first bug
├── output/
│   └── output.txt     captured expected output (committed)
└── data/              runtime scratch the demo creates — git-ignored,
                       safe to delete: `rm -rf data` resets the demo
```

Every folder in this repo follows the same layout: committed **inputs** in
`config/`, the committed **captured output** in `output/`, and anything a run
generates in `data/` — which is git-ignored and disposable. Nothing a demo needs
is ever written to `data/`.

---

*Verified on bash 5.2.21 / GNU grep 3.11. Flag semantics quoted from the
[GNU Bash Reference Manual](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html).*
