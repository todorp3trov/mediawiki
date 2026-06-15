# sql/ — database schema

The canonical definition of MediaWiki core's database schema. The schema is
written **once, abstractly** (in JSON) and the concrete per-DB SQL is
**generated** from it. You edit the abstract source here; you never hand-write
the dialect SQL. The runtime DB layer that consumes these tables lives in
`includes/libs/rdbms/` — see `docs/database.md`.

## Layout

- `tables.json` — **the single source of truth for the full schema**: every core table, column, index, and comment, using abstract (Doctrine DBAL) types like `integer`, `bigint`, `binary`, `blob` — not raw MySQL/Postgres types. This is the file you edit to add or change a table.
- `abstractSchemaChanges/*.json` — one file per **incremental change** (add column, drop index, widen a type, …), each a `before`/`after` snapshot of the affected table. These drive upgrades of existing wikis.
- `mysql/`, `postgres/`, `sqlite/` — **generated** output, one dir per supported DB:
  - `tables-generated.sql` — the full schema generated from `tables.json`.
  - `patch-*.sql` — the change SQL generated from each `abstractSchemaChanges/` entry; applied to existing wikis by `maintenance/run update`.
- `tables.sql` — intentionally blank stub kept for back-compat (T191231); **do not edit** — the real schema is `tables-generated.sql` + `tables.json`.

## Workflow: changing the schema (canonical; toolchain not present here)

1. Edit the abstract source: change `tables.json` for the full schema, **and** add a `before`/`after` change file under `abstractSchemaChanges/` for wikis upgrading in place.
2. Regenerate the per-DB SQL — never edit `tables-generated.sql` or `patch-*.sql` by hand:
   ```sh
   php maintenance/run.php generateSchemaSql           # full schema  ← tables.json
   php maintenance/run.php generateSchemaChangeSql      # change patch ← abstractSchemaChanges/
   ```
3. Wire the new patch into the DB updater (`DatabaseUpdater` / the per-DB `MysqlUpdater`, `SqliteUpdater`, `PostgresUpdater` under `includes/Installer/`) so `maintenance/run update` applies it on existing wikis.

## Conventions & gotchas

- **Generated SQL must match the JSON.** `tests/phpunit/structure/AbstractSchemaTest` regenerates and diffs; if you forget step 2 (or hand-edit the SQL), it fails. This is the most common way to break the schema build.
- All three dialects are generated from the *same* abstract definition — keep them in sync by regenerating all of them, not by editing one.
- The abstract JSON formats are themselves schema-validated: see `docs/abstract-schema.schema.json` (tables), `docs/abstract-schema-changes.schema.json` (changes), and `docs/abstract-schema-table.json`.
- Add a `comment` to new tables/columns — they document the schema and surface in generated SQL and on-wiki schema docs.
- `tables-generated.sql` is large/generated — don't read it wholesale to understand the schema; read `tables.json` instead.
