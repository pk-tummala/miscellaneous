# Setup — WSL Ubuntu 24.04 + IntelliJ

The baseline for running this repo's demos on Windows via **WSL (Ubuntu 24.04)**,
edited in **IntelliJ IDEA**. Every step below was run on Ubuntu 24.04 / Python
3.12 — it's tested, not guessed.

## 1. One-time system setup

Ubuntu 24.04 ships Python 3.12, but two things trip people up: the `venv` module
isn't always installed, and Ubuntu **refuses system-wide `pip install`** (PEP 668,
the `externally-managed-environment` error). Install the essentials once and both
problems go away:

```bash
sudo apt update
sudo apt install -y python3 python3-venv git
```

That's everything the Python demos need. Shell-only demos need nothing beyond
bash, which WSL already has. (PySpark demos will additionally need Java — see §5.)

## 2. Clone into the WSL filesystem — not `/mnt/c`

Working under your Linux home is much faster than the mounted Windows drive, and
avoids file-permission quirks:

```bash
cd ~
git clone https://github.com/pk-tummala/miscellaneous.git
cd miscellaneous
```

## 3. Run any demo

Each folder is self-contained. `cd` into it and run its script with `bash`:

```bash
cd merge-four-engines
bash run.sh
```

Using `bash run.sh` avoids a common gotcha: a **zip download strips the execute
bit**, and files created on the Windows side of WSL often aren't executable
either, so `./run.sh` can fail with `Permission denied`. `bash run.sh` works
regardless. (If you cloned with `git`, the execute bit is preserved and `./run.sh`
works too — or make any script executable once with `chmod +x run.sh`.)

On the **first** run, `run.sh`:

1. checks `python3` is present (and prints the `apt` command if it isn't),
2. creates a local `.venv/` **inside that folder**,
3. installs the folder's `requirements.txt` into that venv — nothing system-wide,
4. runs the demo and prints the result.

Later runs reuse `.venv/` and start instantly. `.venv/` is git-ignored, so it's
never committed. To reset a demo completely: `rm -rf .venv` and run again.

Shell-only demos skip all of that — no Python, no venv:

```bash
cd set-euo-pipefail && bash run.sh
cd daily-job-status-automation && bash daily_job_status_report.sh
```

## 4. Open in IntelliJ IDEA

IntelliJ works directly against the WSL project — no copying to Windows.

1. **File → Open**, and browse to the WSL path (newer builds use `wsl.localhost`,
   older ones `wsl$`):

   ```
   \\wsl.localhost\Ubuntu-24.04\home\<you>\miscellaneous
   ```

   Or, from the WSL terminal inside the repo, launch straight into it if you have
   the launcher: `idea .`

2. IntelliJ uses its **WSL target** automatically. The built-in **Terminal** tab
   opens a bash shell inside Ubuntu — run the `bash run.sh` commands there, exactly
   as in §3.

3. **For Python code intelligence** on a folder (autocomplete, run/debug):
   run `bash run.sh` once so the venv exists, then
   **Settings → Project → Python Interpreter → Add Interpreter → Existing**, and
   point it at that folder's `.venv/bin/python`.
   - IntelliJ IDEA needs the bundled **Python** plugin enabled
     (Settings → Plugins). PyCharm has it out of the box.

4. If IntelliJ tries to index the venv, right-click `.venv` →
   **Mark Directory as → Excluded**.

## 5. PySpark demos (as the series grows)

PySpark needs a JVM (which pip can't install) plus a ~300 MB download. Those
folders check for Java and say so in their own README, with a hint like:

```bash
sudo apt install -y openjdk-17-jre-headless
```

## Why a per-folder `.venv`?

Ubuntu 24.04 marks the system Python "externally managed" (PEP 668), so a bare
`pip install` is refused — and even where it isn't, it would quietly pollute your
global Python. A local `.venv` sidesteps both: it's isolated, disposable
(`rm -rf .venv` to reset), and honest about each demo's dependencies via its
`requirements.txt`.
