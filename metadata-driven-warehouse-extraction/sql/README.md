# Metadata schema — SQL

The control schema for the extract pattern described in the white paper.
Six tables, one view. **No warehouse data lives here** — only configuration
and run history.

| File | Purpose |
|---|---|
| `01-metadata-schema.sql` | The six control tables, constraints and indexes |
| `02-downstream-view.sql` | The read-only view exposed to the consuming team |
| `03-example-config.sql` | Worked configuration for six table archetypes |
| `04-operational-queries.sql` | Progress, failures, anomaly checks, profiling |

## Order

```sh
psql -f 01-metadata-schema.sql
psql -f 02-downstream-view.sql
psql -f 03-example-config.sql      # optional — examples only
```

## Dialect

PostgreSQL. The schema is deliberately plain: `SERIAL`, `VARCHAR`, `TIMESTAMP`,
`BOOLEAN`. Porting to another engine is mostly a matter of identity columns
and the `now()` default.

## The one query to run first

Section A of `04-operational-queries.sql` tests whether a table's change-date
column actually advances between commits. It runs against the **source
warehouse**, not this schema, and it is the single most valuable thing to
measure before committing to a plan — it cannot be answered reliably by asking.
