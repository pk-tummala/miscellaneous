# Unity Catalog - governance you build in, not bolt on

**In one line:** in Unity Catalog, governance isn't a separate project - it's the shape of the data.
A three-level namespace (`catalog.schema.table`), least-privilege grants that **inherit**, clear
ownership, and **automatic lineage** all come from building on it. Do it on day one and there is
nothing to retrofit. `bash run.sh` builds a governed schema from scratch and demonstrates each piece;
`bash run.sh teardown` removes it.

---

## What goes wrong when governance is bolted on later

Governance skipped during development doesn't disappear - it becomes a debt that comes due at the
worst time (an audit, an incident, a breach). The repercussions:

- **Access sprawl.** With no model from the start, access is handed out ad hoc - broad grants, copied
  permissions, everyone a little bit admin. Retrofitting least-privilege means **revoking access
  people already depend on**: broken dashboards, angry teams, and the politics the hook names.
- **No lineage history.** When a column changes or a figure looks wrong, you need to know what feeds
  it and what consumes it - *now*. Lineage added later only captures the future; it cannot reconstruct
  the past, so the one incident where you needed it is the one it can't answer.
- **Namespace chaos.** Without the three-level namespace and naming conventions, you get duplicated,
  ambiguous objects across workspaces. Consolidating them later is a migration in itself.
- **Audit gaps.** No record of who accessed what. In a regulated environment (banking, health,
  insurance) that is not a tidiness problem - it is a compliance and legal exposure.
- **Ownership ambiguity.** No owners means orphaned objects nobody can grant on, change, or delete.

Every one of these is cheap to prevent on day one and expensive to fix after go-live - which is why
*"governance added after go-live is just a migration with extra politics."*

## The model (what the demo builds)

**1. Three-level namespace.** Every object lives at `catalog.schema.table`, and every object is a
*securable*. This hierarchy is also the unit of access control.

**2. Least-privilege grants that inherit.** To read a table a principal needs three privileges -
`SELECT` on the table, `USE CATALOG` on the catalog, and `USE SCHEMA` on the schema. And privilege
**inheritance** means you grant once at the right level:

```sql
GRANT USE CATALOG ON CATALOG gov_demo            TO `data_analysts`;
GRANT USE SCHEMA  ON SCHEMA  gov_demo.sales       TO `data_analysts`;
GRANT SELECT      ON SCHEMA  gov_demo.sales       TO `data_analysts`;  -- inherits to every table, now and future
```

Grant `SELECT` on the schema and it applies to **all current and future tables** in it - you never
re-grant per table. `USE SCHEMA` is also an access *boundary*: even if a table owner grants `SELECT`,
the consumer cannot read the table without `USE SCHEMA`, which only the schema owner controls. Grant
to **account groups** (`data_analysts`, `data_engineers`) - never to individual users, and never
`SELECT` to `account users` (that is everyone).

**3. Ownership.** Every securable has an owner with all privileges on it. Ownership does not inherit
downward, so set it deliberately - own catalogs/schemas with a **group**, not a person who might
leave.

**4. Lineage - free.** Unity Catalog captures table and column lineage **automatically** for
operations on UC objects. The demo builds `orders_silver` from `orders_bronze`; the relationship is
recorded with no extra code, queryable from `system.access.table_lineage` (once system tables are
enabled) or Catalog Explorer's Lineage tab.

**5. Audit - free.** Access is logged to `system.access.audit` - who ran what, when, against which
object. The record you'll wish you had is being written from the first query.

## Inspecting and tightening

```sql
SHOW GRANTS ON SCHEMA gov_demo.sales;                       -- who has what
SELECT * FROM gov_demo.information_schema.table_privileges;  -- same, as a queryable view
REVOKE SELECT ON SCHEMA gov_demo.sales FROM `data_analysts`; -- tightening is instant, not a migration
```

Because access is a property of the object, changing it is a single statement - the exact opposite of
the retrofit nightmare.

## Run it (self-provisioning, idempotent) - and tear it down

```bash
bash run.sh            # uses the vic-dev profile (DATABRICKS_PROFILE=<name> to override)
bash run.sh teardown   # DROP CATALOG gov_demo CASCADE + delete the warehouse
```

`run.sh` resolves or creates a small serverless SQL warehouse, then builds the catalog, schema and
tables, applies the grants, shows ownership and lineage, and revokes - all idempotent. Output is
captured to `output/output.txt`. (`system.access` lineage/audit tables must be enabled by an account
admin and have some latency; the grants, inheritance, namespace and ownership are shown synchronously.)

## Files

```
unity-catalog-governance/
|-- run.sh               build + demo (namespace, grants, ownership, lineage) and `teardown`
|-- output/output.txt    captured real run
```