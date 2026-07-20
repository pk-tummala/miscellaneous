# Config-driven Python

If your code knows which environment it's running in, it isn't portable — it's
just lucky. This is the pattern that takes the environment out of the code and
puts it where it belongs.

## Run it

```bash
bash run.sh
```

The first run creates a local `.venv/` in this folder and installs PyYAML into it
— nothing system-wide, so Ubuntu 24.04's PEP 668 block never bites. Later runs
reuse it.

One-time prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

Full WSL + IntelliJ walkthrough: [`../SETUP.md`](../SETUP.md). Captured output is
in [`output.txt`](output.txt).

It runs the same `pipeline.py` four times — dev, prod, prod with an environment
variable override, and prod with a CLI override. The file is never edited, and it
never once mentions dev, test or prod.

## The layering

Four layers, lowest precedence to highest:

```
defaults  ->  config[env]  ->  environment vars  ->  CLI flags
(config.yaml)  (config.yaml)   (PIPELINE_*)         (--batch-size)
```

Each layer only overrides what it needs to. `dev` doesn't restate the target
table; it inherits it. That inheritance is what stops config files drifting apart
until nobody knows which value is real.

Why all four? They map to how a pipeline is actually operated:

- **defaults** — what's true everywhere
- **config[env]** — what genuinely differs between environments, in version control
- **env vars** — how a scheduler or container injects at runtime
- **CLI flags** — how *you* override at 2am without editing a file

## The part that matters at 2am

Every value in the output reports where it came from:

```
  setting       value                       resolved from
  --------------------------------------------------------------
  source_path   s3://example-prod/inbound   config[prod]
  batch_size    99                          env[PIPELINE_BATCH_SIZE]
  log_level     WARNING                     config[prod]
```

When a run misbehaves and someone swears the config is right, that last column
*is* the investigation. Without it you're guessing which of four layers won.

## Secrets are not settings

Note what's missing from `config.yaml`: the password. Config files get committed,
copied into tickets and pasted into Slack. Credentials come from the environment
only — and in production, from a secret manager that injects them as environment
variables.

Config is for settings. The environment is for secrets. Never blur the two.

## Files

```
config-driven-python/
├── config-driven-python-README.md   this file
├── run.sh              ./run.sh → creates .venv, runs it four ways
├── pipeline.py         the pipeline — knows nothing about any environment
├── requirements.txt    Python dependency (pyyaml)
├── config/
│   └── config.yaml     defaults + per-environment overrides (no secrets)
└── output/
    └── output.txt      captured expected output
```
