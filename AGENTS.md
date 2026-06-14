# MediaWiki core

The free, open-source PHP wiki engine that powers Wikipedia and the other
Wikimedia projects. This repository is **MediaWiki core** — the engine itself.
Hundreds of features ship as separate extensions and skins (see "Extensions &
skins" below); they are *not* in this repo. When acting here, you are working on
the platform that thousands of third-party wikis and every Wikimedia site run
on, so backward compatibility and performance-at-scale are first-class concerns.

- Canonical home & dev wiki: <https://www.mediawiki.org/>
- Code review: **Gerrit** (`gerrit.wikimedia.org`), not GitHub PRs. See `.gitreview`.
- Bugs/tasks: **Phabricator** (`phabricator.wikimedia.org`), referenced as `T12345`.
- License: GPL-2.0-or-later.

## Architecture & module map

A request enters through a thin entry-point script in the repo root, which boots
the environment (`includes/WebStart.php` → `includes/Setup.php`) and then hands
off to a handler. Almost everything is reached through two hubs: the
**service container** (`MediaWikiServices`, wired in `includes/ServiceWiring.php`)
for dependency injection, and the **hook system** (`HookContainer`/`HookRunner`)
for extension points. These two are the most-connected nodes in the entire
codebase — understand them first.

Entry points (repo root):
- `index.php` — web views, actions, and special pages (`MediaWiki\Actions\ActionEntryPoint`).
- `api.php` — the Action API (`includes/Api`).
- `rest.php` — the REST API (`includes/Rest`).
- `load.php` — ResourceLoader; serves JS/CSS modules (`includes/ResourceLoader`).
- `thumb.php`, `img_auth.php`, `opensearch_desc.php` — media thumbnails, protected file access, search descriptor.
- `maintenance/run.php` — CLI entry point for all maintenance scripts.

Main modules (each significant one has its own `AGENTS.md`):
- `includes/` — **the PHP core**: services, hooks, DB layer, parser, output, Title/User/Page, Action/REST APIs, ResourceLoader backend, and `includes/libs/` (standalone Wikimedia libraries). See `includes/AGENTS.md`.
- `tests/` — PHPUnit (unit + integration), QUnit, Jest, Selenium, API tests, parser tests. See `tests/AGENTS.md`.
- `maintenance/` — ~200 CLI scripts (install, update, schema, rebuilds, imports). See `maintenance/AGENTS.md`.
- `resources/` — front-end source: `mediawiki.*` JS/CSS modules, jQuery plugins, Vue/Codex. See `resources/AGENTS.md`.
- `languages/` — i18n: `languages/i18n/*.json` messages, `languages/data`, `languages/messages` (per-language fallback/config).
- `sql/` — database schema: abstract `sql/tables.json` → generated per-DB SQL (`sql/mysql`, `sql/postgres`, `sql/sqlite`).
- `docs/` — developer documentation (`docs/Injection.md`, `docs/Hooks.md`, `docs/database.md` are the high-value ones).
- `mw-config/` — the web-based installer's front controller.

## Tech stack

- **PHP ≥ 8.3** (see `composer.json`). Package manager: **Composer**.
- **Node.js** + **npm** for the front-end toolchain (lint, Jest, QUnit, Selenium). Package manager: **npm** (`package-lock.json`).
- Databases: MySQL/MariaDB, PostgreSQL, SQLite.
- Key bundled libraries live under the `wikimedia/*` and `oojs/*` Composer packages, plus Parsoid (`wikimedia/parsoid`) and Codex (`@wikimedia/codex`) on the front end.

## Setup

> The toolchain (PHP, Composer, `vendor/`, `node_modules/`) is **not** present in
> this checkout; the commands below are the project's canonical commands and were
> **not executed here**. Run them in a configured environment.

Recommended local environment is **Docker Compose** (full instructions in
`DEVELOPERS.md`): create a `.env`, then `docker compose up -d`,
`docker compose exec mediawiki composer update`, and
`docker compose exec mediawiki /bin/bash /docker/install.sh`. The wiki then
serves at <http://localhost:8080>.

Without Docker:
```sh
composer update                 # PHP deps incl. PHPUnit (do NOT use --no-dev for tests)
npm ci                          # front-end deps
composer mw-install:sqlite      # one-shot SQLite install for the built-in server
composer serve                  # PHP built-in server on http://127.0.0.1:4000
```

## Build, test & lint

Canonical commands (from `composer.json` / `package.json` scripts; **not run here**).
Module files refine these — e.g. how to run a single PHPUnit test is in `tests/AGENTS.md`.

PHP:
```sh
composer test          # quick pre-commit gate: parallel-lint + phpcs + minus-x
composer lint          # PHP syntax (parallel-lint)
composer phpcs         # code style — rules in .phpcs.xml (mediawiki-codesniffer)
composer fix           # auto-fix style (phpcbf) + minus-x fix
composer phan          # static analysis (config in .phan/)
composer phpunit:config        # REQUIRED before running phpunit directly (generates phpunit.xml)
composer phpunit:unit          # fast, DB-less unit tests
composer phpunit               # full suite (config generated automatically)
```

JavaScript / CSS / i18n:
```sh
npm run lint           # grunt: eslint (.js/.json/.vue) + banana (i18n) + stylelint
npm test               # grunt lint + jsdoc + jest
npm run jest           # JS unit tests (tests/jest)
npm run qunit          # browser QUnit — needs a running wiki + MW_SERVER/MW_SCRIPT_PATH
```

## Conventions

- **PHP style**: MediaWiki coding conventions enforced by `mediawiki-codesniffer` via `.phpcs.xml`. Indentation is **tabs** (see `.editorconfig`). New code uses the `MediaWiki\` namespace and constructor dependency injection; a large body of legacy global-namespace classes and `wf*()` global functions (`includes/GlobalFunctions.php`) still exists and is being migrated away from.
- **Dependency injection**: register new services in `includes/ServiceWiring.php` and add a typed accessor on `MediaWikiServices`. Read `docs/Injection.md` — it is the authority and includes migration recipes. Do not inject `MediaWikiServices` itself into business logic.
- **Hooks**: each hook has an interface `XxxHook` with a method `onXxx`; callers use a `HookRunner`. See `docs/Hooks.md`.
- **Database**: use `IConnectionProvider`; `$dbr` = replica (read), `$dbw` = primary (write); prefer the query builders (`newSelectQueryBuilder()` etc.). See `docs/database.md`.
- **i18n**: never hard-code UI English; add messages to `languages/i18n/en.json` with documentation in `qqq.json`. The `banana` checker enforces this.
- **Commits/review**: small, focused commits with a `Bug: T12345` footer; submitted to Gerrit (`.gitmessage` is the template). `.git-blame-ignore-revs` lists bulk-reformatting commits.

## Gotchas

- **`autoload.php` is generated** (header says so) — it maps classic class names to files. After adding, moving, or renaming a class, regenerate it with `php maintenance/run.php generateLocalAutoload`. `tests/phpunit/structure/AutoLoaderStructureTest` fails if it is stale.
- **`phpunit.xml` is generated** from `phpunit.xml.template` by `composer phpunit:config`. Running PHPUnit without generating it first will not work as expected.
- **Integration tests are destructive to the database.** Never run them against a production or data-bearing wiki (`tests/phpunit/README.md`).
- **DB schema is generated.** Edit the abstract schema (`sql/tables.json` or add a change in `sql/abstractSchemaChanges/`) and regenerate per-DB SQL with `maintenance/run generateSchemaSql` / `generateSchemaChangeSql`; `AbstractSchemaTest` enforces that the generated SQL matches.
- **`extensions/` and `skins/` are empty placeholders** here (just a README + `.gitignore`); real extensions/skins are cloned in separately and enabled via `wfLoadExtension()`/`wfLoadSkin()` in `LocalSettings.php`. Some behavior and tests assume specific extensions.
- **No in-repo CI config.** CI runs on Wikimedia infrastructure (Quibble); the authoritative build/test/lint definitions are the `composer.json` and `package.json` scripts.
- **`LocalSettings.php`** is the local site config and is git-ignored; it is created by the installer and is required for the wiki to run.
- Large generated/data files to avoid reading wholesale: `autoload.php` (~470 KB), `HISTORY` (~1.8 MB), `sql/*/tables-generated.sql`, `package-lock.json`.
