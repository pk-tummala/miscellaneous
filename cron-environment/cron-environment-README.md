# cron isn't your shell: why the job works by hand and dies at 3am

**In one line:** cron runs your job in a bare environment — a minimal `PATH` and none
of the variables your login shell loaded from `~/.bashrc`. The same script that runs by
hand can't find `python`, `aws`, or your env vars under cron.

---

## The 3am failure, in one script

`report.sh` is a nightly job:

```bash
echo "target env: ${REPORT_ENV:-<unset>}"
reportgen "$REPORT_ENV"      # reportgen lives in the project's ./bin
```

Run it by hand and it works. Schedule it in cron and at 3am it fails with `reportgen:
command not found` (exit 127), and `REPORT_ENV` is unset. Nothing about the script
changed — the *environment* did.

When you open a terminal you get a **login, interactive** shell that sources
`/etc/profile` and `~/.bashrc`, giving you a fat `PATH` (with `./bin`, `/usr/local/bin`,
your venv) plus every variable those files export. **cron sources none of that.** Per
`crontab(5)`, the daemon sets up only a handful of variables automatically: `SHELL` (to
`/bin/sh`), and `LOGNAME` and `HOME` from the crontab owner's `/etc/passwd` line. `PATH`
is minimal — typically just `/usr/bin:/bin`. Everything else your terminal had is gone.

So two things break: **commands aren't found** (`reportgen` is in `./bin`, not on cron's
`PATH`), and **variables are unset** (`REPORT_ENV` came from `~/.bashrc`).

> `reportgen` is a stand-in for anything not on cron's minimal `PATH` — your venv
> `python`, `aws`, a `pyenv`/`nvm` shim, or a tool in a project `bin/`.

## Run the demo

```bash
bash run.sh
```

Pure bash — no cron daemon needed. It runs `report.sh` two ways, reproducing cron's bare
environment with `env -i`. Captured output is in [`output/output.txt`](output/output.txt):

1. **By hand** (tools on `PATH`, env loaded): `reportgen: built the prod report`.
2. **The way cron runs it** (`env -i PATH=/usr/bin:/bin`): `target env: <unset>` and
   `reportgen: command not found`, exit 127.
3. **`report_fixed.sh`** under that same bare env: works, because it declares its own
   `PATH` and sources its own env file.

[`crontab.example`](crontab.example) shows the schedule both ways — the naive line that
fails, and the fixed block with `SHELL`, `PATH` and the var declared.

`env -i` is also how you *reproduce* a cron failure on your own terminal: run your script
under it and you'll hit the same bare-environment failures cron would. (It's a close
stand-in — cron also sets `SHELL` and `LOGNAME`, but the minimal `PATH` and missing vars
are what bite.)

## Two more traps in the same family

- **cron's shell is `/bin/sh`, not bash.** `crontab(5)` sets `SHELL=/bin/sh`. Bash-only
  syntax (`[[ ]]`, arrays, `set -o pipefail`) run *inline* by cron can fail. A
  `#!/usr/bin/env bash` shebang protects a *script*; set `SHELL=/bin/bash` in the crontab
  if cron runs bash syntax inline.
- **Sourcing `~/.bashrc` won't save you.** Most `~/.bashrc` files begin with
  `[[ $- != *i* ]] && return`, which exits immediately in a non-interactive shell. cron
  is non-interactive, so the file returns before exporting anything. Use a *dedicated*
  env file instead.

## The fix: declare the environment, don't inherit it

- **Set `PATH` explicitly** — in the script (`export PATH=...`) or as a `PATH=` line in
  the crontab. Or call commands by **absolute path**.
- **Load config from a dedicated env file** you `source` in the script (not `~/.bashrc`).
- **Set `SHELL=/bin/bash`** in the crontab if you rely on bash.
- **Redirect output to a log** — `>> /var/log/report.log 2>&1`. cron emails stdout/stderr
  to the owner; on most servers nobody reads that, so a failure is silent otherwise.
- **Test under `env -i`** before you trust it to a scheduler.

## It's not just cron

The root cause — *a scheduled, non-interactive context is not your login shell* — shows
up anywhere jobs run without your profile: **Airflow's BashOperator**, **systemd timers**,
and **CI runners**. Same discipline: declare `PATH` and env explicitly.

## Files

```
cron-environment/
├── cron-environment-README.md   this file
├── run.sh              bash run.sh → runs report.sh by hand, then the way cron does
├── report.sh           the job as first written (dies under cron)
├── report_fixed.sh     declares its own PATH + sources its own env (runs anywhere)
├── crontab.example     the schedule, both ways: the naive line and the fixed block
├── bin/
│   └── reportgen       a stand-in for any command not on cron's minimal PATH
├── config/
│   └── report.env      the env cron won't load for you
└── output/
    └── output.txt      captured demo output
```

---

*Run on GNU bash 5.2 (Ubuntu 24.04). cron auto-setting only `SHELL=/bin/sh`, `LOGNAME`
and `HOME`, and not sourcing login files, is from the `crontab(5)` man page; the minimal
default `PATH` (typically `/usr/bin:/bin`) and the non-interactive `~/.bashrc` guard are
standard, documented cron behaviour.*
