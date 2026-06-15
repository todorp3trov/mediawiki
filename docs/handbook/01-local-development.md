# Local Development & Workflow

> Scope: getting from a fresh clone to a productive inner loop — run → change →
> test → debug — on **MediaWiki core** (1.47.0-alpha, PHP ≥ 8.3). This doc owns
> the *workflow*; the *what/why* of each subsystem lives in
> `docs/handbook/subsystems/*.md`, and the per-module mechanics live in the
> `AGENTS.md` files. Link out, don't duplicate.
>
> **Toolchain caveat for this document:** every command below is transcribed
> from `composer.json`, `package.json`, `Gruntfile.js`, and `DEVELOPERS.md`.
> None were executed in this checkout — there is no PHP/Composer on PATH and no
> `vendor/` or `node_modules/` installed here. Treat them as "documented, not
> verified-by-running."

---

## Prerequisites & one-time setup

MediaWiki core is "engine only." `extensions/` and `skins/` are **empty
placeholders** in this repo (just a README + `.gitignore`); a bare wiki runs
with no skin installed and looks unstyled until you clone one in (Vector is the
usual first one — see `DEVELOPERS.md` "Install extensions and skins"). Don't be
alarmed by the plain page on first install.

There are two supported setup paths. Pick based on what you're doing.

### Path A — Docker Compose (recommended; the canonical path in DEVELOPERS.md)

This is what `DEVELOPERS.md` documents as *the* development environment. It
gives you PHP-FPM + Apache + Xdebug + SQLite + a job runner, all pinned to the
Wikimedia-published images, so your local PHP version and extensions match CI's
expectations.

Steps (from `DEVELOPERS.md`):

1. Install Docker (Desktop on macOS/Windows, engine on Linux). **The images are
   AMD64-only** — Apple Silicon runs them under Rosetta emulation; there is no
   ARM64 image (`DEVELOPERS.md` §Requirements).
2. `git clone https://gerrit.wikimedia.org/r/mediawiki/core.git mediawiki`.
   (Note: clone from **Gerrit**, not GitHub — GitHub is a read-only mirror; code
   review happens on Gerrit.)
3. Create a `.env` in the repo root. The documented contents set
   `MW_SCRIPT_PATH=/w`, `MW_SERVER=http://localhost:8080`, `MW_DOCKER_PORT=8080`,
   admin user/pass, and `XDEBUG_ENABLE=true` / `XHPROF_ENABLE=true`. Then append
   your host UID/GID via `MW_DOCKER_UID=$(id -u)` / `MW_DOCKER_GID=$(id -g)` so
   files written in the container are owned by you (Windows users leave these
   blank). This `.env` is consumed by `docker-compose.yml` (`env_file: .env`).
4. `docker compose up -d` — starts `mediawiki` (PHP-FPM), `mediawiki-web`
   (Apache, publishes the port), and `mediawiki-jobrunner` (background jobs).
   All three bind-mount the repo at `/var/www/html/w` (note: cwd inside the
   container is `/var/www/html/w`, **not** `/var/www/html` — a common stale-doc
   trap, see Troubleshooting).
5. `docker compose exec mediawiki composer update` — install PHP deps into
   `vendor/`.
6. `docker compose exec mediawiki /bin/bash /docker/install.sh` — runs the
   installer and writes `LocalSettings.php`. (`/docker/install.sh` is baked into
   the image, not in this repo — `docker/` does not exist in the checkout.)

The wiki is then at <http://localhost:8080>. Run any command in the container
with `docker compose exec mediawiki <cmd>`, or open a shell with
`docker compose exec mediawiki bash`.

The compose stack is **minimal by design** (the file header says so):
DB is SQLite, there's no memcached/MySQL container. You extend it via a
git-ignored `docker-compose.override.yml` (add MySQL, mount an out-of-tree
extension/skin or a local Codex build, set Xdebug `extra_hosts` on Linux). After
editing the override file you must `docker compose down && docker compose up -d`
for it to take effect.

### Path B — bare `composer serve` + SQLite (fast, no Docker)

For quick core work when you already have PHP 8.3 + Composer + the required PHP
extensions (`ext-intl`, `ext-mbstring`, `ext-dom`, `ext-pdo` for SQLite, etc. —
see the `require`/`suggest` blocks in `composer.json`). This path uses PHP's
built-in webserver. Note: **this is not the path `DEVELOPERS.md` walks through**;
it is encoded in `composer.json` scripts and the project README, and is the path
the toolchain-free root `CLAUDE.md` lists:

```sh
composer update                 # install vendor/ (do NOT use --no-dev — tests need dev deps)
npm ci                          # front-end deps (node_modules/)
composer mw-install:sqlite      # one-shot SQLite install (writes LocalSettings.php)
composer serve                  # PHP built-in server on http://127.0.0.1:4000
```

Two scripts worth understanding (verbatim from `composer.json`):

- `mw-install:sqlite` →
  `maintenance/run.php install --server=http://localhost:4000 --dbtype sqlite
  --with-developmentsettings --dbpath cache/ --scriptpath= --pass adminpassword
  MediaWiki Admin`. Key bits: it installs to a SQLite DB under `cache/`, uses an
  **empty script path** (so the wiki is at the docroot, `/`), and passes
  `--with-developmentsettings`, which makes the generated `LocalSettings.php`
  `require` `includes/DevelopmentSettings.php` (see Configuration below).
- `serve` → sets `MW_LOG_DIR=logs`, `MW_LOG_STDERR=1`, `PHP_CLI_SERVER_WORKERS=8`
  and runs `php -S 127.0.0.1:4000`. So with this path, **debug logs land in
  `logs/` and also stream to your terminal** out of the box.

### Web installer (the GUI path)

`mw-config/` is the web-based installer's front controller (`index.php` there).
If you don't pre-seed `LocalSettings.php`, visiting the wiki redirects into the
installer, which walks you through DB choice and writes `LocalSettings.php` for
you. The CLI installer (`maintenance/run install`, or `composer mw-install:sqlite`)
is the scriptable equivalent and is what both setup paths above use.

---

## The inner loop (change → see → test)

The whole point of either setup is a tight edit loop. What you do depends on
*what kind* of file you changed.

### (a) PHP changes

For ordinary edits to existing methods/classes: **edit → refresh the browser**.
There is no build step or compile for PHP. The `:cached` bind-mount means the
container sees your edits immediately.

Three cases force an extra step before the change takes effect:

1. **Added, renamed, moved, or deleted a class** → regenerate the classmap:
   ```sh
   php maintenance/run.php generateLocalAutoload
   ```
   `autoload.php` is **generated** (its header says so) and maps classic
   (non-PSR-4) class names to files; a stale one means "class not found" or the
   structure test `tests/phpunit/structure/AutoLoaderStructureTest` fails. (New
   code under the `MediaWiki\` namespace is PSR-4 and may not need this, but run
   it whenever the structure test complains — *inferred from the AGENTS.md note
   that the test enforces it*.)

2. **Changed the DB schema** (edited `sql/tables.json` or added a change under
   `sql/abstractSchemaChanges/`) → regenerate per-DB SQL, then apply migrations:
   ```sh
   php maintenance/run.php generateSchemaSql        # or generateSchemaChangeSql
   php maintenance/run.php update                    # apply pending migrations to your DB
   ```
   `AbstractSchemaTest` fails if the generated SQL doesn't match the abstract
   schema. See `docs/handbook/subsystems/database-rdbms.md` and
   `docs/handbook/subsystems/storage-revisions-content.md` for the data model.

3. **Pulled new commits or enabled an extension that adds tables** → run
   `maintenance/run.php update` to apply any pending schema/data migrations.
   This is the single most-forgotten step after `git pull`.

If a PHP change *appears* not to apply and none of the above are the cause,
suspect caching (see Troubleshooting → caching layers).

### (b) Front-end changes (JS / CSS / Less / Vue)

ResourceLoader normally concatenates and minifies modules, so a raw edit to a
`resources/src/...` file won't show up readably. Two tools:

- **ResourceLoader debug mode:** append `?debug=true` to any wiki URL (aliases
  `?debug=1` and `?debug=2`, per
  `includes/ResourceLoader/Context.php::debugFromString`). This serves modules
  unminified and unconcatenated, so your source maps to what's in the browser —
  this is the front-end "refresh and see it" loop. `?debug=2` is a higher debug
  level. See `docs/handbook/subsystems/output-skins-resourceloader.md`.
- **Vue devtools:** `DevelopmentSettings.php` sets `$wgVueDevelopmentMode = true`,
  so Codex/Vue components are debuggable when development settings are loaded.
- **Local Codex builds:** if you're co-developing Codex, clone it, run
  `npm run build-all` (or the faster `npm run quick-build` for `.vue`/`.ts`-only
  changes), mount it via `docker-compose.override.yml`, and set
  `$wgCodexDevelopmentDir = MW_INSTALL_PATH . '/codex'` in `LocalSettings.php`
  (`DEVELOPERS.md` §Codex). You must re-run the Codex build after every change —
  it is *not* watched.

For JS unit logic, the fastest loop bypasses the browser entirely with Jest:
```sh
npm run jest                    # jest --config tests/jest/jest.config.js
npm run jest -- --watch         # re-run on change (inferred: standard Jest flag)
```

### (c) Running a SUBSET / single PHPUnit test

**`phpunit.xml` is generated** from `phpunit.xml.template` by
`composer phpunit:config` (via `tests/phpunit/generatePHPUnitConfig.php`).
Running PHPUnit without generating it first will not behave correctly. The
`composer phpunit` script does this for you, but if you invoke `phpunit`
directly you must generate the config first.

The documented single-file pattern (from `DEVELOPERS.md` and `tests/AGENTS.md`)
runs from inside `tests/phpunit`:
```sh
composer phpunit:config                              # once, after template/test changes
cd tests/phpunit
composer phpunit -- path/to/MyTest.php               # one file
composer phpunit -- path/to/dir/                     # a directory
# under Docker:
docker compose exec mediawiki bash
instance:/w$ cd tests/phpunit
instance:/w/tests/phpunit$ composer phpunit -- path/to/MyTest.php
```

Faster, DB-less subset:
```sh
composer phpunit:unit                                # testsuite core:unit, no DB
```

Named testsuites available from `phpunit.xml.template`: `core:unit`,
`includes`, `structure`, `integration`, `maintenance_suite`, `parsertests`,
`docs`. The full testing strategy (base-class choice, `@covers`, strictness)
is owned by `tests/AGENTS.md` and the testing handbook doc — see Foundation.

> **WARNING:** PHPUnit *integration* tests are **destructive to the database**.
> Never run them against a production or data-bearing wiki
> (`tests/phpunit/README.md`).

---

## Running services locally (DB, cache, …)

- **Database.** SQLite is the default everywhere for development: both setup
  paths install to SQLite (`docker-compose.yml` sets `MW_DBTYPE=sqlite`,
  `MW_DBPATH=…/cache/sqlite`; `mw-install:sqlite` uses `--dbtype sqlite`). It
  needs no server and is the right choice for a quick start. Switch to
  **MySQL/MariaDB** (needs `ext-mysqli`) or **PostgreSQL** (`ext-pgsql`) when you
  must reproduce DB-specific behavior — under Docker, add a DB container via
  `docker-compose.override.yml` and point `LocalSettings.php` at it; recipes are
  on the MediaWiki-Docker wiki page linked from `DEVELOPERS.md`. Note that
  `DevelopmentSettings.php` turns on **MySQL strict mode**
  (`$wgSQLMode = 'STRICT_ALL_TABLES,ONLY_FULL_GROUP_BY'`, `$wgDBStrictWarnings`)
  so dev catches the same SQL strictness CI does.
- **Cache.** No cache server is required. Default caching "just works" and
  changes propagate immediately (`DEVELOPERS.md` §Caching). Memcached/Redis/APCu
  are optional accelerators (`composer.json` `suggest`); add them only when
  profiling or reproducing prod behavior. See
  `docs/handbook/subsystems/caching-deferred-jobs.md`.
- **Job runner.** The Docker stack runs a dedicated `mediawiki-jobrunner`
  container so background jobs execute automatically. On the bare path there's no
  job runner — run jobs manually with `php maintenance/run.php runJobs` when you
  need them to fire. (*Inferred:* the bare path has no equivalent service; jobs
  otherwise run on later web requests via the default deferred mechanism.)

---

## Configuration & local secrets

- **`LocalSettings.php`** is the site config. It is **git-ignored** and is
  **created by the installer** (CLI, web, or `composer mw-install:sqlite`); the
  wiki will not run without it. This is where you toggle local behavior, load
  skins/extensions (`wfLoadSkin`/`wfLoadExtension`), and override services.
- **`$wgSecretKey`** is generated automatically by the installer (a 64-char
  random value, see `includes/Installer/Installer.php` and written by
  `LocalSettingsGenerator.php`). You do not set it by hand; it lives in your
  git-ignored `LocalSettings.php`. There is no separate secrets file for core
  dev — local secrets live in `LocalSettings.php`.
- **`includes/DevelopmentSettings.php`** is the curated bundle of "make the wiki
  developer-friendly" settings. Enable it by adding
  `require "$IP/includes/DevelopmentSettings.php";` to `LocalSettings.php`
  (the `--with-developmentsettings` installer flag does this for you; the bare
  SQLite path passes that flag). What it turns on, and *why it matters*:
  - `error_reporting(-1)` and (web only) `display_errors` — see every notice.
  - `$wgShowExceptionDetails = true`, `$wgShowHostnames = true` — full stack
    traces in the browser instead of a generic error page. **This is the single
    biggest quality-of-life setting for debugging.**
  - `$wgDevelopmentWarnings = true` — `wfWarn()` becomes fatal in tests, catching
    deprecation/misuse early.
  - **Log files keyed off `MW_LOG_DIR`** — if that env var is set, it wires up
    `$wgDebugLogFile` (`mw-debug-web.log` / `mw-debug-cli.log`),
    `$wgDBerrorLog` (`mw-dberror.log`), and error/exception/ratelimit groups.
    The Docker stack sets `MW_LOG_DIR=/var/www/html/w/cache` (so logs land in
    `cache/*.log`); the bare `serve` script sets `MW_LOG_DIR=logs`.
  - `$wgEnableJavaScriptTest = true` (enables `Special:JavaScriptTest`, which
    `npm run qunit` needs), near-infinite rate limits and login throttles (so
    parallel tests don't get throttled), `$wgForceDeferredUpdatesPreSend = true`
    (so end-to-end GETs observe prior POSTs), and several experimental/feature
    flags (temp accounts, Codex sub-referencing, Vue dev mode, pig-latin and
    x-xss test languages, a small `$wgMaxArticleSize` so size limits are
    testable). Read the file top-to-bottom once — it is short and documents the
    Phabricator task behind each experimental toggle.
- **`composer.local.json`** is merged into Composer config via the
  composer-merge-plugin (`composer.json` `extra.merge-plugin`) — that's the hook
  for adding local dev dependencies without editing the tracked `composer.json`.

The config *system* itself (`MainConfigSchema.php`, `$wg*` declaration, the
Settings subsystem) is documented in
`docs/handbook/subsystems/service-container-and-config.md` — don't invent ad-hoc
`$wg*` names.

---

## Debugging (logs, debugger, verbosity)

- **Turn on verbosity first:** load `DevelopmentSettings.php` (above). With it,
  exceptions render full stack traces in the browser and PHP notices surface.
- **Logs.** With `MW_LOG_DIR` set, tail the debug log:
  - Docker: logs go to `cache/*.log` (notably `cache/mw-debug-web.log`) — they
    are **not** streamed to `docker compose logs` (`DEVELOPERS.md` notes this).
  - Bare `composer serve`: logs go to `logs/` *and* stream to your terminal
    (`MW_LOG_STDERR=1`).
- **`wfDebug()` / `wfDebugLog()`** are the legacy logging entry points; modern
  code uses PSR-3 loggers via the LoggerFactory. The debug toolbar
  (`$wgDebugToolbar`, commented in `DevelopmentSettings.php`) and
  `$wgDebugDumpSql` (log every SQL query) are opt-in extras for deep debugging.
  `MWDebug` is the underlying mechanism. (*Inferred from the commented toggles
  in DevelopmentSettings.php; not exercised here.*)
- **Xdebug (step debugging).** Built into the Docker image and enabled via
  `XDEBUG_ENABLE=true` in `.env`, but **per-request** by default: set
  `XDEBUG_TRIGGER=1` in the GET/POST or use a browser extension to activate it.
  Xdebug 3 listens on `client_port` 9003. To debug *every* request, set
  `XDEBUG_CONFIG=start_with_request=yes` in `.env`. Linux hosts need the
  `host.docker.internal` `extra_hosts` override (`DEVELOPERS.md` §Xdebug,
  §Troubleshooting). On the bare path, Xdebug is whatever you've configured in
  your own PHP — not provided by the project.
- **Interactive REPL (PsySH).** `php maintenance/run.php shell` boots the full
  MediaWiki environment into an interactive PHP shell — the fastest way to poke
  at services, load a `Title`, or call a method against your real local DB
  without writing a script. (`psy/psysh` is a dev dependency; `ext-readline` is
  suggested for history/autocomplete.)
- **XHProf profiling** is available in the Docker stack (`XHPROF_ENABLE=true`)
  for performance work; see `docs/handbook/subsystems/` performance material and
  the perf handbook doc.

---

## Common dev tasks (seed, reset, migrate, codegen)

| Task | Command (documented, not run here) |
|------|-----------------------------------|
| Apply pending migrations (after pull / enabling an extension) | `php maintenance/run.php update` |
| Regenerate the classmap (after add/rename/move class) | `php maintenance/run.php generateLocalAutoload` |
| Regenerate per-DB SQL from abstract schema | `php maintenance/run.php generateSchemaSql` / `generateSchemaChangeSql` |
| Rebuild the localisation (i18n) cache | `php maintenance/run.php rebuildLocalisationCache` |
| Interactive REPL with MediaWiki booted | `php maintenance/run.php shell` |
| Run background jobs manually (bare path) | `php maintenance/run.php runJobs` |
| Auto-fix PHP style + perms | `composer fix` (`phpcbf` + `minus-x fix .`) |
| Pre-commit gate (lint + style + minus-x) | `composer test` |
| Front-end lint (eslint + banana i18n + stylelint) | `npm run lint` |

**Reset / re-seed the database** (SQLite, from `DEVELOPERS.md` §Re-install):
remove/rename `LocalSettings.php`, delete `cache/sqlite/`, re-run the install
command, then re-apply any custom `LocalSettings.php` and run
`maintenance/run.php update` if extensions added tables. Under Docker, Windows
users must `chmod -R o+rwx cache/sqlite` after.

The maintenance runner is the front door for ~200 scripts — `maintenance/run`
accepts a name, a class name, or a `./path` (`maintenance/CLAUDE.md`,
`maintenance/AGENTS.md`). `composer maintenance -- <args>` is the script alias.

**Style is enforced, not optional.** Indentation is **tabs**, width 4
(`.editorconfig`; Markdown and YAML use 2-space indent). `composer test` is the
quick gate (`@lint` + `phpcs` + `minus-x check`); `composer fix` auto-fixes most
violations. Static analysis is `composer phan`. CI runs these on Wikimedia
Quibble — there is **no in-repo CI config**, so `composer.json`/`package.json`
scripts are the source of truth for what CI will check.

---

## Troubleshooting — newcomer gotchas

- **Generated files that go stale and break the build:**
  - `autoload.php` (~470 KB) — regenerate with `generateLocalAutoload` after
    class changes, or `AutoLoaderStructureTest` fails.
  - `phpunit.xml` — generated from `phpunit.xml.template`; run
    `composer phpunit:config` before invoking `phpunit` directly.
  - Per-DB SQL (`sql/*/tables-generated.sql`) — regenerate with
    `generateSchemaSql`; `AbstractSchemaTest` enforces it.
- **Integration tests will wipe your dev DB.** They're destructive by design;
  use a throwaway local DB only.
- **`@covers` is mandatory.** The PHPUnit config sets
  `forceCoversAnnotation="true"` and is strict (`failOnWarning`, `failOnRisky`,
  notices→exceptions, no stray output). A test that emits a PHP notice or has no
  `@covers` fails even if its assertions pass (`tests/AGENTS.md`).
- **Tabs, not spaces** — `.editorconfig` enforces tab indentation in PHP/JS;
  `phpcs` will reject spaces.
- **`extensions/`/`skins/` are empty here.** Behavior and some tests assume
  specific extensions/skins; a bare core looks unstyled and some features are
  absent until you clone them in. Clone Vector to get a real skin.
- **"Cannot access the database" after pulling.** The Docker working dir changed
  to `/var/www/html/w`; ensure `LocalSettings.php` has `$wgScriptPath = '/w'` and
  `$wgSQLiteDataDir = "/var/www/html/w/cache/sqlite"` (`DEVELOPERS.md`
  §Troubleshooting). Linux: set `MW_DOCKER_UID`/`MW_DOCKER_GID`. Windows:
  `chmod -R o+rwx cache/sqlite`.
- **"My change isn't showing up."** Hard-refresh the browser first. If it's a
  front-end file, you probably need `?debug=true`. If still cached, disable
  server caches in `LocalSettings.php` (`$wgMainCacheType = CACHE_NONE;`
  `$wgMessageCacheType = CACHE_NONE;` `$wgParserCacheType = CACHE_NONE;` and zero
  `$wgResourceLoaderMaxage`) — but expect a slowdown, especially on macOS/Windows
  Docker (`DEVELOPERS.md` §Caching).
- **Clone from Gerrit, review on Gerrit.** GitHub is a mirror. Patches go to
  Gerrit with a `Bug: T12345` footer; tasks live on Phabricator.

---

## Foundation (link to root AGENTS.md + relevant subsystem docs)

- **Root `AGENTS.md`** — architecture/module map, repo-wide conventions
  (`MediaWiki\` namespace + DI, hooks, DB layer), and the canonical build/test
  command list this doc operationalizes.
- **`DEVELOPERS.md`** — the canonical Docker Compose dev-environment guide;
  authoritative for `.env`, install, Xdebug, Codex, and re-install/reset.
- **Per-module guides:** `includes/AGENTS.md` (the PHP core spine; service +
  autoload regeneration), `maintenance/AGENTS.md` (the `run.php` runner and
  frequently-used scripts), `tests/AGENTS.md` (test layout, base classes,
  `@covers`, strictness), `resources/AGENTS.md` (front-end source).
- **Subsystem deep-dives** (`docs/handbook/subsystems/`):
  `service-container-and-config.md` (config system, `LocalSettings`/`$wg*`),
  `output-skins-resourceloader.md` (ResourceLoader debug mode, skins),
  `database-rdbms.md` + `storage-revisions-content.md` (schema & migrations),
  `caching-deferred-jobs.md` (caches, job queue), `localisation.md` (i18n /
  localisation cache).
- **Sibling handbook docs:** the testing-strategy doc (full PHPUnit/Jest/QUnit/
  Selenium strategy), the architecture doc, and the performance/production doc
  (Xdebug/XHProf profiling) go deeper than this workflow doc's pointers.
