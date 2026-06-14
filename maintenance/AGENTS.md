# maintenance/ — CLI scripts

~200 command-line PHP scripts for administering and developing a wiki: install,
schema upgrades, cache/index rebuilds, imports/exports, user/permission tools,
and benchmarks. Depends on `includes/` (it boots the full MediaWiki environment).

## How scripts are run

Use the **maintenance runner**, not the script files directly:
```sh
php maintenance/run.php <name> [options]    # or the shorthand: maintenance/run <name>
```
`<name>` can be a simple name, a class name, or a path:
- `maintenance/run version`  → `maintenance/version.php`
- `maintenance/run Version`  → the `Version` class (autoloaded)
- `maintenance/run ./maintenance/version.php` → by path (relative paths must start with `./`)

Extensions' maintenance scripts are invoked by full class name or
`extensions/Foo/maintenance/script.php` path. See `maintenance/README`.

> Not executed in this checkout — there is no PHP toolchain or installed wiki here.

## Frequently used

- `maintenance/run update` — apply pending DB schema/data migrations (run after pulling changes or enabling an extension that adds tables).
- `maintenance/run install` — CLI installer (see also `composer mw-install:sqlite`).
- `maintenance/run generateLocalAutoload` — regenerate the root `autoload.php` after class changes.
- `maintenance/run generateSchemaSql` / `generateSchemaChangeSql` — regenerate per-DB SQL from the abstract schema in `sql/`.
- `maintenance/run shell` — interactive PHP REPL (PsySH) with MediaWiki booted.

## Key files & conventions

- `Maintenance.php` — the abstract base class every script extends. New scripts define options/args in the constructor and put logic in `execute()`.
- `run.php` / `run` — the runner/entry point. `doMaintenance.php`, `CommandLineInc.php` — legacy include-style bootstraps.
- `includes/` (i.e. `maintenance/includes/`) — shared helpers for scripts (e.g. dumpers).
- `benchmarks/` — performance benchmark scripts.
- **Style exceptions**: `.phpcs.xml` grants many maintenance scripts grandfathered exemptions (filename≠classname, `proc_open`/`shell_exec`, multiple classes per file). Don't take these as a license for new scripts — new code should follow the standard rules; the exclusions exist to freeze pre-existing violations.
- Scripts run with no web request context — obtain services via the booted container, and remember they may run for a long time against large databases (mind replication lag; see `docs/database.md`).
