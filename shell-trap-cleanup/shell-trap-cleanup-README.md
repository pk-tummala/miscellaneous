# trap & cleanup: scripts that tidy up after themselves

**In one line:** a job that creates a lock file or a temp file should remove them
*however* it exits — and `trap cleanup EXIT` is how you guarantee that, even when the
job dies mid-run.

---

## The 3am problem

Your scheduled job takes a lock so two copies never run at once:

```bash
[ -e "$LOCK" ] && { echo "already running"; exit 3; }
echo "$$" > "$LOCK"
# ... do the work ...
rm -f "$LOCK"        # release it at the end
```

At 3am the job dies mid-run — the box is OOM-killed, the pod is evicted, a `kill`
lands, someone hits Ctrl-C. It never reaches that `rm`. The lock file is left behind.
The next run sees the lock, assumes a copy is still running, and **refuses to start**.
Nothing runs again until a human notices and deletes the file by hand.

The bug isn't the lock. It's that cleanup was written as *the last line*, so anything
that skips the last line skips the cleanup.

## The fix: `trap cleanup EXIT`

Move cleanup into a function and register it with `trap` on `EXIT`:

```bash
cleanup() { rm -f "$LOCK" "$TMP"; }
trap cleanup EXIT
```

Now `cleanup` runs **on exit from the shell** — and per the bash manual that means on
normal completion, on `exit N`, on a `set -e` error, and after a trapped signal's
handler exits. So the lock is released on the ordinary ways a job dies — it finishes,
it errors, or it's killed — instead of only on the happy path.

## Make it robust: also catch Ctrl-C and kill

Add explicit handlers for the two signals a job usually dies from, so they exit
promptly (and with the conventional codes), still routing through the `EXIT` trap:

```bash
cleanup() { rm -f "$LOCK" "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT     # Ctrl-C
trap 'exit 143' TERM    # kill / scheduler timeout / pod eviction
```

- **`INT`** — Ctrl-C. This one matters: a non-interactive script waiting on a child
  (a `sleep`, a long command) does **not** reliably act on `SIGINT` from `EXIT` alone,
  so the explicit `INT` trap is what guarantees Ctrl-C runs your cleanup. (In a
  terminal, `^C` goes to the whole process group.)
- **`TERM`** — the default `kill`, and what schedulers and orchestrators send to stop
  a job. (`trap cleanup EXIT` catches this one on its own, but trapping it keeps the
  exit code clean.)

The one thing you **cannot** catch is `kill -9` (`SIGKILL`) — or `SIGSTOP`. The bash
manual is explicit: those signals can't be trapped, blocked, or ignored; the OS stops
the process before any trap can run. Note the **OOM killer sends `SIGKILL`** too, so a
truly out-of-memory job can still leak its lock — no trap can save it. That's a case
for a lock that self-expires (a heartbeat/TTL), not for a cleanup trap.

(A signal-terminated script exits with status `128 + N` — `130` for Ctrl-C, `143` for
`SIGTERM`, `137` for `SIGKILL` — which is how you tell in logs *how* a job died.)

## Three rules that make it reliable

1. **Set the trap early** — right after you define `cleanup`, and *before* you create
   the lock or temp file. A resource created before the trap is armed can still leak.
2. **Make cleanup idempotent** — use `rm -f` (never errors if the file's already gone),
   because cleanup can run more than once in edge cases.
3. **Don't lose the exit code** — if cleanup does real work, capture `rc=$?` as its
   first line and `exit "$rc"` at the end, so a failure still surfaces as a failure.

## Run the demo

```bash
bash run.sh
```

Pure bash — nothing to install, no account. It runs two jobs and kills each one
mid-run:

- **`job_naive.sh`** — cleanup on the last line only. Killed → lock survives → the next
  run is blocked.
- **`job_safe.sh`** — `trap cleanup EXIT` (+ `INT`/`TERM`). Killed → cleanup runs anyway
  → the next run starts clean.

Captured output is in [`output/output.txt`](output/output.txt). The two job scripts are
the bits to copy.

## Files

```
shell-trap-cleanup/
├── shell-trap-cleanup-README.md   this file
├── run.sh              bash run.sh → kills each job mid-run and shows the difference
├── job_naive.sh        the job WITHOUT a cleanup trap (leaves its lock behind)
├── job_safe.sh         the job WITH `trap cleanup EXIT` (tidies up on any exit)
└── output/
    └── output.txt      captured demo output
```

---

*The demo was run on GNU bash 5.2 (Ubuntu 24.04).*
