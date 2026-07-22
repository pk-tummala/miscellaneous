# miscellaneous

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Languages](https://img.shields.io/badge/languages-SQL%20%7C%20Python%20%7C%20Bash-1f425f.svg)
![Status](https://img.shields.io/badge/status-active-success.svg)

Runnable data-engineering patterns, gotchas and utilities — each one small enough
to read in a sitting and self-contained enough to clone and run in seconds.

Some folders are working utilities I've built and used. Most are minimal, runnable
demonstrations of a single idea — a SQL pattern, a Spark internal, a shell habit, a
cloud technique — the kind of thing that's easy to assert in a post and far more
convincing when you can run it and watch it happen.

Each folder stands alone: its own README, its own sample data, its own captured
output. Nothing here depends on anything else here.

## Scope

The repo grows alongside an ongoing data-engineering writing series — each piece
that includes code drops its runnable snippet here. It spans four areas:

- **SQL & data modelling** — the ANSI core and the dialect differences (Oracle ·
  Teradata · Snowflake · Delta), window functions, dimensional modelling
- **Python & PySpark** — pipeline craft, Spark internals, testing
- **Shell, orchestration & platform** — the glue: bash, scheduling, Hadoop, HDFS
- **Cloud data platforms** — AWS, Snowflake and Databricks

Most demos run on nothing but **bash** (shell demos) or **Python 3 + a local
`.venv`** (Python demos) — no account, no cluster. Each Python demo's `run.sh`
creates its own `.venv` on first run and installs into it, so nothing lands in
your system Python. A few cloud techniques genuinely need a Snowflake /
Databricks / AWS account (and PySpark demos need Java); those ship the real code,
sample data and **captured real output**, clearly labelled, so you can read
exactly what happens without one. No demo here fakes a result.

New to the repo? See [`SETUP.md`](SETUP.md) for a tested WSL Ubuntu 24.04 +
IntelliJ walkthrough.

## Contents

Each folder has its own README with the exact command to run it (most are `./run.sh`).

### SQL & data modelling
| Folder | What it does |
|--------|--------------|
| [`merge-four-engines/`](merge-four-engines/merge-four-engines-README.md) | The same idempotent upsert in Oracle, Teradata, Snowflake and Delta — plus a runnable proof of the one condition idempotency depends on, and what happens when you break it. |

### Python & PySpark
| Folder | What it does |
|--------|--------------|
| [`config-driven-python/`](config-driven-python/config-driven-python-README.md) | Keep the settings that change between test and live out of your code, so the same pipeline runs anywhere. Shows the four places a setting can come from — and which one wins. |

### Shell, orchestration & platform
| Folder | What it does |
|--------|--------------|
| [`daily-job-status-automation/`](daily-job-status-automation/daily-job-status-automation-README.md) | A pure-shell tool that queries DataStage master sequences and emails a RAG colour-coded daily status report. Runs in a self-contained demo mode out of the box. |
| [`set-euo-pipefail/`](set-euo-pipefail/set-euo-pipefail-README.md) | The same load script twice — one exits 0 after three failures and reports success, the other doesn't. Three characters of insurance. |

_New folders land as the series continues._

## Philosophy

Three ideas run through everything here.

**Runnable proof over assertion.** A claim about data engineering is cheap; a
folder you can run and watch is not. Every demo ships the code, its sample data and
its captured output — so the point is demonstrated, not just described.

**Fundamentals outlast the stack.** Engines change every few years; the reasons
behind them — set-based thinking, avoiding the shuffle, idempotency, reading less
data — don't. The focus here is the transferable idea, not the vendor button. And
when a problem's requirements and boundaries are clearly known, a small,
well-bounded tool beats a complex one every time.

**Show what breaks, not just the happy path.** The useful part is usually the
failure: the duplicate key that quietly corrupts a MERGE, the script that exits 0
after failing. Several demos deliberately break, because the gotcha is the lesson.

## Author

**Pavan Kumar Tummala** — Senior Data Engineering professional, Melbourne
[LinkedIn](https://www.linkedin.com/in/pavan-k-tummala/) · [GitHub](https://github.com/pk-tummala)

## License

Released under the [MIT License](LICENSE).
