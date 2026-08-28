# The Databricks Asset Bundle gotcha: dev mode isolates the pipeline name, not where it writes

**In one line:** `mode: development` prepends `[dev <you>]` to a pipeline's *name*, so two
developers deploying the same bundle get two separate pipeline objects and it *feels* isolated.
But it never touches the pipeline's write **target** (`catalog`/`schema`). Point both at the same
schema and their tables land in the same place - overwriting each other. The fix is one line:
make the pipeline's target schema per-developer. This repo is a self-contained demo of that.

> Databricks Asset Bundles were recently renamed **Declarative Automation Bundles**; the CLI is
> still `databricks bundle` and the file is still `databricks.yml`.

---

## The bootstrap (automatic, idempotent)

The pipeline writes into a shared catalog (`dab_sandbox`), and developers need `CREATE SCHEMA`
on it. `run.sh` handles that as its first step, calling `setup.sh`, which is **check-then-act
idempotent**:

- catalog already exists -> skips creation (no SQL warehouse needed)
- grant already in place  -> skips the grant (so a non-admin re-run doesn't fail)

Only the first run - the one that creates the catalog - needs catalog-create rights and a SQL
warehouse (auto-picked, or `WAREHOUSE_ID=...`). It effectively runs:

```sql
CREATE CATALOG IF NOT EXISTS dab_sandbox COMMENT 'Shared developer sandbox';
GRANT USE CATALOG, CREATE SCHEMA ON CATALOG dab_sandbox TO `account users`;
```

(In a real setup, scope the grant to a developers *group*.) You can also run `bash setup.sh` alone.

## The trap

You deploy the bundle to dev and see `[dev alice] demo_pipeline`. Two developers, two distinct
pipeline objects - it looks isolated. But `mode: development` only prefixes the resource **name**.
A pipeline's `catalog` and `schema` are *settings* - where it publishes tables - and they're
values, not names, so dev mode leaves them exactly as written:

```
[dev alice] demo_pipeline  --\
                              >-- both write to  dab_sandbox.demo.{bronze, silver}
[dev bob]   demo_pipeline  --/
```

Alice runs her pipeline, then Bob runs his, and Bob's `bronze`/`silver` overwrite Alice's. The
`[dev you]` prefix on the name did nothing to stop it, because the data never went through it.

## The fix

Make the pipeline's write **target** per-developer, using `${workspace.current_user.short_name}`:

```yaml
# databricks.yml
variables:
  catalog: { default: dab_sandbox }   # shared, pre-existing
  schema:  { description: The pipeline's target schema }

targets:
  dev:
    mode: development
    default: true
    variables:
      schema: demo_${workspace.current_user.short_name}   # <- per-developer WRITE TARGET
```

```yaml
# resources/pipeline.yml
resources:
  pipelines:
    demo_pipeline:
      catalog: ${var.catalog}
      schema:  ${var.schema}     # where it writes - now demo_<you>
      serverless: true
      libraries:
        - file: { path: ../src/demo_pipeline.py }
```

Now Alice's pipeline writes to `dab_sandbox.demo_alice`, Bob's to `dab_sandbox.demo_bob`. Same
catalog, different schema - their `bronze`/`silver` never collide. (`schema` is a value, not a
resource name, so it takes your substitution as-is - no `[dev you]` prefix, no doubling.)

## The proof - before you deploy anything

`databricks bundle validate` resolves the config for whoever runs it, so both the prefixed name
*and* the untouched target show up:

```bash
databricks bundle validate -t dev -p vic-dev -o json \
  | jq -r '.resources.pipelines.demo_pipeline | .name, (.catalog + "." + .schema)'
#   [dev alice] demo_pipeline        <- dev mode prefixed the NAME
#   dab_sandbox.demo_alice           <- but the TARGET is what you set, per developer
```

## Run it (one command, idempotent)

```bash
bash run.sh          # profile defaults to vic-dev; override with PROFILE=other bash run.sh
```

`run.sh` runs five steps and tees a clean log to `output/output.txt`:

```bash
bash setup.sh                                              # 1. ensure catalog + grants (idempotent)
databricks bundle validate -t dev -p vic-dev              # 2. proof: name is prefixed, target is yours
databricks bundle deploy   -t dev -p vic-dev              # 3. create [dev <you>] demo_pipeline
databricks bundle run demo_pipeline -t dev -p vic-dev     # 4. writes bronze/silver into demo_<you> (a few min)
databricks tables list dab_sandbox demo_<you> -p vic-dev  # 5. verify the tables are in YOUR schema
```

It's **idempotent**: re-run any time. Each developer writes to their own schema, so re-running
never overwrites anyone else's tables. Have a teammate run it - two schemas, two sets of tables,
zero collision.

## Why this one bites

`mode: development` is a naming and lifecycle preset. Its `[dev you]` prefix applies to resource
*names* - a pipeline's `name`, a job's `name`, a schema resource's `name`. But a pipeline's
`catalog` and `schema` describe *where it writes*; they're settings, not names, so the preset
never rewrites them. So the thing that looks like isolation (the prefixed pipeline name) and the
thing that actually matters (the write target) are two different fields - and only you control
the second one.

## Files

```
databricks-asset-bundles/
|-- databricks.yml                 the bundle: shared-catalog var + per-developer target schema
|-- resources/pipeline.yml         the pipeline; its schema (write target) is ${var.schema}
|-- src/demo_pipeline.py           minimal Lakeflow (DLT) source - writes bronze + silver
|-- setup.sh                       one-time admin: create shared catalog + grants (idempotent)
|-- run.sh                         setup + validate + deploy + run + verify -> output/output.txt
|-- output/output.txt              captured output from your run (created by run.sh)
```
