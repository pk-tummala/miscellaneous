# Config-driven Python

**In one line:** keep the values that change between your laptop and the real
production system *out* of your code and *in* a separate settings file — so you
never have to edit the program just to run it somewhere else (and never leave a
password sitting in your code).

---

## The problem

Almost every data pipeline hits this. You're building a job that has to run in two
places: a **test** area while you build it, and the real **live** (production)
system once it goes out. The two need slightly different values — a different
folder to read from, a different batch size, a different database name.

The tempting thing is to write those values straight into the code:

```python
if environment == "prod":
    source_path = "s3://prod-bucket/inbound"
    batch_size  = 50000
    password    = "S3cr3t!"          # now in your Git history forever
else:
    source_path = "/tmp/test"
    batch_size  = 100
```

It runs. But look at what you've quietly signed up for:

- **Every value change means a code change** — edit the file, re-test, re-deploy,
  for something as small as a batch size.
- **Every new environment adds another branch** to that `if/else`, and they drift
  apart until nobody's sure which value is real.
- **A secret is now in the code.** The moment that's committed, it's in the history
  — copied to every clone, visible to everyone with access, and painful to remove.

## The fix

Take the values that change **out** of the code and put them in a settings file.
The code just asks for a setting — it doesn't know or care where it's running:

```python
source_path = settings["source_path"]
batch_size  = settings["batch_size"]
password    = os.environ["DB_PASSWORD"]   # from the environment, never the file
```

…and the settings live in a plain, readable file (`config/config.yaml`):

```yaml
defaults:
  batch_size: 1000
  target_table: customer_dim

environments:
  test:
    source_path: /tmp/test
  prod:
    source_path: s3://prod-bucket/inbound
    batch_size: 50000
```

Now the **same code runs everywhere**. To change a value you edit the settings, not
the program. Add a new environment? Add a few lines of settings — no new `if/else`.

## Run it

```bash
bash run.sh
```

The first run creates a local `.venv/` in this folder and installs PyYAML into it —
nothing system-wide, so Ubuntu 24.04's PEP 668 block never bites. One-time
prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

Full WSL + IntelliJ walkthrough: [`../SETUP.md`](../SETUP.md). Captured output is in
[`output/output.txt`](output/output.txt).

`run.sh` runs the **same** `pipeline.py` four times — test, live, live with an
environment-variable override, and live with a command-line override. The file is
never edited, and it never once mentions "test" or "live".

## "But sometimes I need to change one value for one run"

You can — without touching the settings file. A setting can come from **four
places**, and the **most specific one wins**:

| # | Where the setting comes from | What it's for |
|---|------------------------------|---------------|
| 1 | **Defaults** (in the settings file) | The base values, true everywhere. |
| 2 | **This environment's settings** (in the settings file) | What's genuinely different about test vs live. |
| 3 | **An environment variable** (e.g. `PIPELINE_BATCH_SIZE=99`) | How an automated scheduler or container slips a value in at run time. |
| 4 | **A command-line flag** (e.g. `--batch-size 1`) | How *you* override a single run by hand, without editing anything. |

They stack from least specific to most specific. A value set at level 4 beats the
same value at level 1.

Think of **ordering coffee**: the menu has a default size, a particular store might
default to large, but if you ask for a small, you get a small. The most specific
instruction — you, right now — wins over the store, which wins over the menu.

Here's the exact same idea in the demo. Running the live environment but overriding
`batch_size` on the command line:

```
$ python3 pipeline.py --env prod --batch-size 1

  setting       value                       came from
  --------------------------------------------------------------
  source_path   s3://example-prod/inbound   prod settings      <- level 2
  target_table  customer_dim                default            <- level 1
  batch_size    1                           command line       <- level 4 wins
  log_level     WARNING                     prod settings      <- level 2
```

`batch_size` came from the command line (level 4) and won. Everything else fell
back to the most specific place it *was* set.

## See where every value came from

Notice that last column — **`came from`**. The program prints, next to each
setting, exactly which of the four places it ended up using.

That sounds small; it's the whole game at 2 a.m. When a run misbehaves and someone
swears the settings are right, you don't guess which of four places won — you read
the column. Without it, "why is `batch_size` 1 in production?" is a 30-minute
investigation. With it, it's one glance: *command line*.

## Secrets are not settings

Look again at what's **missing** from `config/config.yaml`: the password.

Settings files get committed to Git, copied into tickets, pasted into chat. A
password in there leaks by a hundred small accidents. So credentials never live in
the settings file — they come from the **environment** instead (and in production,
from a secret manager that injects them as environment variables):

```python
password = os.environ["DB_PASSWORD"]   # never settings["password"]
```

The rule to remember: **the settings file is for settings; the environment is for
secrets.** Never blur the two.

## Try it yourself

Change one line and watch the `came from` column move:

```bash
# override a value just for this run — the file is untouched
PIPELINE_BATCH_SIZE=7 bash run.sh          # env-variable override (level 3)
```

Or edit `config/config.yaml`, change `batch_size` under `prod`, and re-run — the
code doesn't change, only the number does.

## Files

```
config-driven-python/
├── config-driven-python-README.md   this file
├── run.sh              bash run.sh → creates .venv, runs it four ways
├── pipeline.py         the pipeline — knows nothing about any environment
├── requirements.txt    Python dependency (pyyaml)
├── config/
│   └── config.yaml     defaults + per-environment settings (no secrets)
└── output/
    └── output.txt      captured expected output
```
