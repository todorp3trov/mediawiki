# includes/ — MediaWiki PHP core

The heart of the engine. Every entry point (`index.php`, `api.php`, `rest.php`,
`load.php`, `maintenance/run.php`) boots through here and then calls into these
subsystems. ~3,000 PHP files. Most of MediaWiki's application logic lives here;
`maintenance/`, `tests/`, and `resources/` all depend on it.

## The spine (most-connected pieces — learn these first)

From a structural analysis of the codebase, the highest-connectivity hubs are:

- **Hook system** — `includes/HookContainer/` (`HookContainer`, `HookRunner`). By far the most-referenced code in the repo: the universal extension point. Each hook is an interface `XxxHook::onXxx()`; core calls them through `HookRunner`. See `docs/Hooks.md`.
- **`MediaWikiServices`** (`includes/MediaWikiServices.php`) — the service locator / DI container. Service factories are defined in `includes/ServiceWiring.php` (~3,300 lines). This is the canonical way to obtain core services. See `docs/Injection.md`.
- **`includes/GlobalFunctions.php`** — legacy `wf*()` globals (`wfMessage`, `wfDebug`, `wfDeprecated`, …). Still heavily referenced, but **do not add new ones**; prefer services/injection.
- **`Output/OutputPage.php`** — assembles the HTML response (head, modules, body) for web views.
- **DB layer** — `includes/libs/rdbms/` (the `Rdbms` library: `Database`, `LoadBalancer`, `IConnectionProvider`, query builders). See `docs/database.md`.
- **`Title/Title.php`** — the central page-identity value object; threads through nearly everything.
- **Parser** — `includes/parser/` (`Parser`, `ParserOutput`, `Sanitizer`): wikitext → HTML. (Modern parsing increasingly delegates to Parsoid, the `wikimedia/parsoid` Composer package.)

## Key directories

- `Api/` — Action API modules (`api.php`). `Rest/` — REST API handlers (`rest.php`).
- `Actions/` — page actions; `ActionEntryPoint` is the `index.php` handler. `Specials/` + `SpecialPage/` — special pages.
- `Storage/`, `Revision/`, `Page/`, `Content/` — page/revision storage and content models.
- `User/`, `Permissions/`, `Block/`, `Auth/`, `Session/` — identity, rights, blocking, authentication, sessions.
- `Settings/`, `Config/`, `MainConfigSchema.php`, `MainConfigNames.php` — configuration system and the canonical `$wg*` schema.
- `ResourceLoader/` — back-end for `load.php` (front-end *source* is in `/resources`).
- `Cache/`, `ObjectCache/`, `Deferred/`, `JobQueue/` — caching, deferred updates, the job queue.
- `Language/`, `Languages/` — localisation and language services.
- `Installer/` — the installer back-end (web front controller is in `/mw-config`).
- `libs/` — **standalone, dependency-light Wikimedia libraries** (rdbms, ObjectCache, ParamValidator, filebackend, …). Several are mirrored as separate `wikimedia/*` Composer packages; keep them framework-agnostic (no `$wg*` globals, no service-locator access).
- Bootstrap files: `WebStart.php`, `Setup.php`, `BootstrapHelperFunctions.php`, `MediaWikiEntryPoint.php`, `PHPVersionCheck.php`.

## Conventions & gotchas

- **Adding a service**: write the factory in `ServiceWiring.php`, add a typed getter on `MediaWikiServices`, and add a case to `MediaWikiServicesTest`. `docs/Injection.md` has step-by-step migration recipes (singletons, static classes, smart records, hook handlers).
- **Adding/renaming/moving a class** requires regenerating the root `autoload.php`: `php maintenance/run.php generateLocalAutoload`. `AutoLoaderStructureTest` enforces it.
- **`$wg*` config** is declared in `MainConfigSchema.php` (with `MainConfigNames.php` constants), not invented ad hoc.
- **`includes/libs/` must stay decoupled** from MediaWiki globals/services so the libraries remain independently publishable.
- **Stable vs internal API**: classes/methods marked `@stable to call`/`@stable to extend` are part of the extension-facing contract; `@internal` and `@unstable` are not. Breaking stable interfaces requires a deprecation path (`wfDeprecated()` / `@deprecated`).
- Build/test commands are repo-wide — see the root `AGENTS.md` and `tests/AGENTS.md`.
