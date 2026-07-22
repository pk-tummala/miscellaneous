#!/usr/bin/env python3
"""
pipeline.py - a pipeline that knows nothing about its environment.

Resolution order (lowest to highest precedence):

    1. defaults        in config.yaml
    2. environment     block in config.yaml, chosen by --env / PIPELINE_ENV
    3. env vars        PIPELINE_<SETTING>, e.g. PIPELINE_BATCH_SIZE=99
    4. CLI flags       --batch-size 99

Nothing here is hard-coded. No database names, no paths, no credentials.
Credentials never live in config either - they come from the environment.
"""
import argparse
import os
import sys

import yaml

SETTINGS = ("source_path", "target_table", "batch_size", "log_level", "dry_run")


def coerce(value):
    """Env vars and CLI args arrive as strings; config arrives typed."""
    if not isinstance(value, str):
        return value
    low = value.strip().lower()
    if low in ("true", "false"):
        return low == "true"
    if value.strip().lstrip("-").isdigit():
        return int(value)
    return value


def load_config(path, env):
    with open(path) as fh:
        raw = yaml.safe_load(fh)

    # layer 1: defaults
    resolved = dict(raw.get("defaults", {}))
    source = {k: "default" for k in resolved}

    # layer 2: the environment block
    for key, val in raw.get("environments", {}).get(env, {}).items():
        resolved[key] = val
        source[key] = f"{env} settings"

    # layer 3: environment variables
    for key in SETTINGS:
        env_key = f"PIPELINE_{key.upper()}"
        if env_key in os.environ:
            resolved[key] = coerce(os.environ[env_key])
            source[key] = f"env var {env_key}"

    return resolved, source


def parse_args(argv):
    p = argparse.ArgumentParser(description="Config-driven pipeline demo")
    p.add_argument("--config", default="config/config.yaml")
    p.add_argument("--env", default=os.environ.get("PIPELINE_ENV", "dev"))
    p.add_argument("--source-path")
    p.add_argument("--target-table")
    p.add_argument("--batch-size", type=int)
    p.add_argument("--log-level")
    p.add_argument("--dry-run", action="store_true", default=None)
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    resolved, source = load_config(args.config, args.env)

    # layer 4: explicit CLI flags win over everything
    for key in SETTINGS:
        val = getattr(args, key, None)
        if val is not None:
            resolved[key] = val
            source[key] = "command line"

    print(f"\n  environment : {args.env}")
    print(f"  {'setting':<14}{'value':<28}came from")
    print("  " + "-" * 62)
    for key in SETTINGS:
        print(f"  {key:<14}{str(resolved[key]):<28}{source[key]}")

    # Credentials NEVER come from config. Environment only.
    secret = os.environ.get("PIPELINE_DB_PASSWORD")
    print(f"\n  db_password   {'*' * 8 if secret else '(not set)':<28}"
          f"{'env var PIPELINE_DB_PASSWORD' if secret else 'never in the settings file'}")

    if resolved["dry_run"]:
        print("\n  dry_run=True -> would process, writing nothing.\n")
    else:
        print(f"\n  Processing {resolved['source_path']} -> {resolved['target_table']} "
              f"in batches of {resolved['batch_size']}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
