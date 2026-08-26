# Logging done right in Python: structured logs with context

**In one line:** even a well-written `print()` puts the id and the error in the message - but
it is still an unstructured *string*. Structured logging emits the same event as queryable
*fields*, and the enterprise way to attach those fields is not to hardcode a `run_id` or
repeat `extra={...}` on every call - it is a **reusable filter that binds context once** and
stamps it on every line.

---

## Run it

```bash
bash run.sh
```

Needs only `python3` - the standard-library `logging` module (plus `contextvars`) does all of
this, no pip, no account. Captured output is in [`output/output.txt`](output/output.txt); the
code is [`structured_logging.py`](structured_logging.py).

## print() with an exception block - and why it still falls short

To be fair to `print()`, write it well: catch the error and include the id.

```python
except ValueError as e:
    print(f"ERROR processing {o['id']} at validate: {e}")
```

```
ERROR processing R-102 at validate: amount is negative
```

The id **is** there. The problem is that this is *free text*: no `run_id` to tell this
failure apart from the same message in another run, no fields to filter or aggregate without
regex, a format that drifts per developer, and no levels or routing.

## Don't hardcode context - bind it (the reusable pattern)

The naive fix is worse than it looks:

```python
# anti-pattern: hardcoded, and repeated on every single call
log.error("record failed", extra={"run_id": "run-2f9c1a", "record_id": o["id"], ...})
```

A hardcoded `run_id` is wrong (every run needs its own), and repeating `run_id`/`record_id`
in every `extra={...}` is noise you will get inconsistent. Instead, bind context once and let
a **filter** inject it. Two small reusable pieces, written once for the whole codebase:

```python
import contextvars, logging

_log_context = contextvars.ContextVar("log_context", default={})

def bind_context(**fields):                       # bind values every later line will carry
    return _log_context.set({**_log_context.get(), **fields})

class ContextFilter(logging.Filter):              # stamp the bound context onto each record
    def filter(self, record):
        for key, value in _log_context.get().items():
            setattr(record, key, value)
        return True
```

Wire the filter into your logger **once** at startup - this is where the `ContextFilter`
instance is actually created. From then on you never call `filter()` yourself; the logging
framework runs it on every record automatically (right before the formatter, so the record
already carries the context by the time the JSON is built):

```python
h = logging.StreamHandler(); h.setFormatter(JsonFormatter())
log = logging.getLogger("pipeline")
log.addHandler(h)
log.addFilter(ContextFilter())     # the instance lives here; logging invokes .filter() per record
```

Now the `run_id` comes from the orchestrator (dynamic, not a literal), and you bind context at
the scope it belongs to:

```python
run_id = os.environ.get("PIPELINE_RUN_ID") or uuid.uuid4().hex[:6]   # Airflow/Databricks inject this
bind_context(run_id=run_id)                       # once, for the whole run
for o in orders:
    token = bind_context(record_id=o["id"])       # once per record
    try:
        log.info("validating record", extra={"step": "validate"})
        ...
    except ValueError as e:
        log.error("record failed", extra={"step": "validate", "reason": str(e)})
    finally:
        _log_context.reset(token)                 # pop the per-record context
```

Every call now carries `run_id` and `record_id` automatically - you never pass them again.
Because it is backed by `contextvars`, the binding is correct even across threads and async
tasks (each execution context sees only its own values). Run-level lines (`run started`,
`run finished`) carry `run_id` but no `record_id`; the per-record lines carry both - the
context is scoped, not global.

Verified dynamic: `PIPELINE_RUN_ID=job-9987 python3 structured_logging.py` puts
`"run_id":"job-9987"` on every line, no code change.

## How one `log.error(...)` becomes one JSON object

```
log.error("record failed", extra={"step": "validate", "reason": "amount is negative"})
```

becomes

```json
{"ts":"...","level":"ERROR","logger":"pipeline","run_id":"run-2f9c1a","record_id":"R-102","msg":"record failed","step":"validate","reason":"amount is negative"}
```

| Field | Where it comes from |
| --- | --- |
| `ts` | the formatter (`formatTime`) - real code uses `record.created`, an epoch float |
| `level`, `logger` | the logger itself (`ERROR`, and the `getLogger("pipeline")` name) |
| `run_id`, `record_id` | bound with `bind_context(...)`, stamped on every record by `ContextFilter` |
| `msg` | the first argument to `log.error(...)` |
| `step`, `reason` | the `extra={...}` you pass on this specific call |

`level`, `logger` and the timestamp are **captured automatically** on every `LogRecord`.
`run_id`/`record_id` are **bound context** (dynamic, via the filter); `step`/`reason` are
per-call `extra`. The formatter decides which attributes to emit and how.

## Because they're fields, you can query them

The demo runs three queries over the JSON with nothing but the standard library:

```
errors only     -> run: run-2f9c1a | record: R-102 | step: validate | why: amount is negative
count by level  -> ERROR 1 | INFO 9
count by step   -> end 1 | load 3 | start 1 | validate 5
```

That "count by step" is the same shape as a Splunk `stats` or a SQL `GROUP BY`. Once the logs
are JSON, every platform can index and query them:

**Splunk:**

```
index=pipelines run_id="run-2f9c1a"        | table _time, step, record_id, msg
index=pipelines level=ERROR                | stats count by step, reason
```

**AWS CloudWatch Logs Insights:**

```
fields @timestamp, step, record_id, reason | filter level="ERROR" | stats count() by step
```

**Load the JSON straight into a table and use SQL:**

```sql
-- DuckDB
SELECT step, count(*) FROM read_json_auto('run.log') GROUP BY step;
-- Snowflake: land raw JSON in a VARIANT column, then  v:step::string
-- BigQuery:  JSON_VALUE(line, '$.step')
```

`print()` output needs a parser; JSON logs are already a table waiting to happen.

## Practices worth keeping

- Configure logging **once** at the entry point (handler + formatter + `ContextFilter`);
  everywhere else just `logging.getLogger(__name__)`.
- Bind context with `bind_context(...)` at the right scope; never hardcode a `run_id` or repeat
  it in every call.
- Use `logger.exception(...)` (or `exc_info=True`) inside an `except` to capture the stack trace.
- Log **identifiers and outcomes**, never secrets or full payloads.
- Let handlers decide the destination (stdout, file, syslog); don't hard-code it where you log.

## Files

```
python-structured-logging/
|-- python-structured-logging-README.md   this file
|-- structured_logging.py   print()+except vs structured, the bind_context pattern, the queries
|-- run.sh                  bash run.sh -> runs it (python3 only)
|-- output/
    |-- output.txt          captured expected output
```

---

*Standard library only (Python 3, incl. `contextvars`). Deterministic and byte-identical
across runs: the run_id is read from `PIPELINE_RUN_ID` (pinned in run.sh) and the clock is
fixed - in production the run_id is the orchestrator's or a uuid, and the timestamp is real
(`record.created`).*
