"""
Logging done right in Python: structured logs with context - bound dynamically, not hardcoded.

Even a well-written print() puts the id and error in the message, but it is still an
unstructured STRING. Structured logging emits the same event as queryable FIELDS. And the
enterprise way to attach context is NOT to hardcode a run_id or repeat extra={...} on every
call - it is a reusable filter that stamps whatever context is currently bound onto every
record. You bind once (per run, per record); every log line carries it.

Pure standard library - no pip, no account. A fixed run_id (from an env var) and a
deterministic clock keep the output reproducible; the notes point out what changes in prod.
"""
import json, logging, sys, io, os, uuid, contextvars
from collections import Counter

ORDERS = [
    {"id": "R-100", "amount": 120},
    {"id": "R-101", "amount": 80},
    {"id": "R-102", "amount": -50},   # bad record
    {"id": "R-103", "amount": 200},
]

def validate(o):
    if o["amount"] < 0:
        raise ValueError("amount is negative")

# ---------------------------------------------------------------------------
# 1. print(), even done well, is an unstructured string
# ---------------------------------------------------------------------------
def with_print(orders):
    for o in orders:
        try:
            print("processing order", o["id"])
            validate(o)
        except ValueError as e:
            print(f"ERROR processing {o['id']} at validate: {e}")

# ---------------------------------------------------------------------------
# 2. Reusable, dynamic context - write these ONCE, use everywhere
# ---------------------------------------------------------------------------
_log_context = contextvars.ContextVar("log_context", default={})

def bind_context(**fields):
    """Bind context that every later log line will carry. Returns a token for reset()."""
    return _log_context.set({**_log_context.get(), **fields})

class ContextFilter(logging.Filter):
    """Copy whatever context is bound right now onto each record - dynamic, never hardcoded."""
    def filter(self, record):
        for key, value in _log_context.get().items():
            setattr(record, key, value)
        return True

# ---------------------------------------------------------------------------
# JSON formatter: turns a LogRecord into one line
# ---------------------------------------------------------------------------
_STD = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {"message", "asctime", "taskName"}

class JsonFormatter(logging.Formatter):
    _n = 0
    _CTX = ("run_id", "record_id")   # bound-context fields, emitted first in a stable order
    def formatTime(self, record, datefmt=None):
        s = JsonFormatter._n; JsonFormatter._n += 1
        return "2026-08-26T02:14:%02dZ" % (2 + s)     # deterministic demo clock; real: record.created
    def format(self, record):
        out = {"ts": self.formatTime(record), "level": record.levelname, "logger": record.name}
        for f in self._CTX:
            if hasattr(record, f):
                out[f] = getattr(record, f)
        out["msg"] = record.getMessage()
        for k, v in record.__dict__.items():          # per-call extra={...} fields
            if k not in _STD and k not in out:
                out[k] = v
        return json.dumps(out)

def get_logger(stream):
    log = logging.getLogger("pipeline")               # a named logger, never the root logger
    log.setLevel(logging.INFO)
    log.handlers.clear(); log.filters.clear()
    h = logging.StreamHandler(stream); h.setFormatter(JsonFormatter())
    log.addHandler(h)
    log.addFilter(ContextFilter())                    # one filter, injects the bound context
    log.propagate = False
    return log

def with_logging(orders, stream):
    JsonFormatter._n = 0
    log = get_logger(stream)
    run_id = os.environ.get("PIPELINE_RUN_ID") or uuid.uuid4().hex[:6]   # orchestrator's id, or a uuid
    bind_context(run_id=run_id)                       # bound ONCE for the whole run
    log.info("run started", extra={"step": "start", "n_records": len(orders)})
    ok = failed = 0
    for o in orders:
        token = bind_context(record_id=o["id"])       # bound per record - every line below carries it
        try:
            log.info("validating record", extra={"step": "validate"})
            validate(o)
            log.info("loaded record", extra={"step": "load"})
            ok += 1
        except ValueError as e:
            failed += 1
            log.error("record failed", extra={"step": "validate", "reason": str(e)})
        finally:
            _log_context.reset(token)                 # pop the per-record context
    log.info("run finished", extra={"step": "end", "ok": ok, "failed": failed})

# ---------------------------------------------------------------------------
# demo
# ---------------------------------------------------------------------------
bar = "=" * 70
print(bar); print("Logging done right in Python: structured logs with context"); print(bar)

print("\n--- 1. print(), even with the id in the message, is a STRING ---")
with_print(ORDERS)
print("   The id and error are there - but it is free text: no run_id to tie it to this")
print("   run among thousands, and no fields to filter or aggregate without regex.")

print("\n--- 2. Bind context once (reusable filter), then log ---")
print("   run_id = os.environ.get('PIPELINE_RUN_ID') or uuid.uuid4().hex[:6]   # per run, not hardcoded")
print("   bind_context(run_id=run_id)")
print("   bind_context(record_id=o['id'])          # per record; ContextFilter stamps both on every line")
buf = io.StringIO(); with_logging(ORDERS, buf)
logs = buf.getvalue().strip().splitlines()
for line in logs:
    print(line)

print("\n--- 3. One log.error call -> one JSON object (where each field comes from) ---")
print('   log.error("record failed", extra={"step": "validate", "reason": str(e)})')
print("   becomes:")
print("   " + [l for l in logs if '"level": "ERROR"' in l][0])
print("     ts, level, logger  <- added by the logger + formatter")
print("     run_id, record_id  <- bound via bind_context(), stamped by ContextFilter (dynamic)")
print("     msg                <- the first argument to log.error(...)")
print("     step, reason       <- the extra={...} you pass on this call")

print("\n--- 4. Because they are fields, you can query them ---")
recs = [json.loads(l) for l in logs]
err = next(r for r in recs if r["level"] == "ERROR")
print("   errors only        -> run: %s | record: %s | step: %s | why: %s"
      % (err["run_id"], err["record_id"], err["step"], err["reason"]))
by_level = Counter(r["level"] for r in recs)
by_step = Counter(r["step"] for r in recs)
print("   count by level     -> " + " | ".join(f"{k} {v}" for k, v in sorted(by_level.items())))
print("   count by step      -> " + " | ".join(f"{k} {v}" for k, v in sorted(by_step.items())))
print("   (same shape as Splunk `stats count by step`, or SQL GROUP BY over the JSON)")

print("\n" + bar)
print("print() gives you a wall of strings; structured logs give you queryable fields.")
print("Bind context once with a reusable filter - never hardcode it, never repeat it.")
print(bar)
