# Subsystem: Action API

*Code: `includes/Api/`. Entry point: `api.php` → `ApiEntryPoint` → `ApiMain`. MW_VERSION 1.47.0-alpha.*

This is the original, module-based machine API of MediaWiki — `?action=query&...`.
It is the workhorse the web front end, every gadget, every bot, and most
third-party tooling talk to. It is decades old and **wildly depended upon**: its
default output shape is a public contract that effectively cannot break. The
newer, route-based [REST API](rest-api.md) is its sibling, not its replacement;
read that doc and the comparison table in it for "when to use which." This doc
explains the Action API framework and the request lifecycle — it does *not*
re-document REST internals.

> Scope note: this covers the *framework* (`ApiMain`, `ApiBase`, `ApiQuery`, the
> module manager, param validation glue, result/continuation/error/formatter
> machinery). The ~150 concrete core modules (`ApiEditPage`, `ApiQueryRevisions`,
> …) are cited as examples of the contract, not documented one by one.

## Responsibility & boundaries

The Action API turns one HTTP request to a single endpoint (`api.php`) into a
call to one **module** selected by the `action=` query parameter, validates its
parameters, checks permissions/tokens/lag, executes it, and serialises the
resulting nested array into the client's chosen format (json/xml/php/none/raw,
plus `…fm` pretty-HTML variants). It owns:

- module registration & dispatch (`ApiModuleManager`),
- parameter declaration, validation & coercion (via `includes/libs/ParamValidator`),
- the result data model + size limiting (`ApiResult`),
- continuation for paged result sets (`ApiContinuationManager`),
- output format negotiation and serialisation (`ApiFormat*`),
- error/warning formatting (`ApiErrorFormatter`, `ApiMessage`),
- the cross-cutting request concerns: CSRF tokens, `maxlag`, `assert`/`assertuser`,
  `apihighlimits`, CORS, read/write authorization, conditional requests, cache headers,
- and **auto-generated, i18n-driven help** (`action=help`, `action=paraminfo`).

It does **not** own: authentication or sessions (it consumes the
`Authority`/`Session`/`User` from
[auth-permissions-sessions](auth-permissions-sessions.md)); business logic
(modules call into [storage-revisions-content](storage-revisions-content.md),
[parser-and-content-transform](parser-and-content-transform.md),
[files-media-uploads](files-media-uploads.md), search, etc.); or the DB layer
(modules borrow replica/primary connections via the standard providers).

## Internal structure (key files & their roles)

Dispatcher & base:
- **`api.php`** (~30 lines) — defines `MW_API` / `MW_ENTRY_POINT='api'`, boots
  `includes/WebStart.php`, constructs `ApiEntryPoint` and calls `run()`.
- **`ApiEntryPoint.php`** (`@internal`, extends `MediaWikiEntryPoint`) — rejects
  `PATH_INFO` (T128209, 301-redirects to the clean URL), sets a dummy
  `Special:Badtitle` `$wgTitle` (much of core breaks with a null Title), then
  constructs `ApiMain`, fires the **`ApiBeforeMain`** last-chance hook, and calls
  `ApiMain::execute()`. Exceptions before/inside that are reported in API format
  via `handleApiBeforeMainException()`.
- **`ApiMain.php`** (~2,600 lines) — the dispatcher. Itself an `ApiBase`
  subclass (its parent is itself: `parent::__construct($this, 'main')`). Holds the
  `ApiModuleManager`, `ApiResult`, `ApiErrorFormatter`, `ApiParamValidator`,
  `ApiContinuationManager`. Owns the whole lifecycle (`executeAction()` and the
  check methods below). The core action and format module lists are
  `private const MODULES` / `FORMATS` here.
- **`ApiBase.php`** (~2,300 lines, `@stable to extend`) — base class of *every*
  module. Defines the override surface a module author implements
  (`execute()`, `getAllowedParams()`, `needsToken()`, `isWriteMode()`,
  `mustBePosted()`, `getExamplesMessages()`, `getCustomPrinter()`, …),
  parameter extraction (`extractRequestParams()`/`getParameter()`), the
  `requireOnlyOneParameter`/`requireMaxOneParameter`/`requireAtLeastOneParameter`/
  `requirePostedParameters` guards, error/warning emission (`dieWithError`,
  `dieStatus`, `addWarning`, …), result access (`getResult()`), and the
  help-message machinery (`getFinalParams`/`getFinalParamDescription`/
  `getFinalDescription`). `validateToken()` is `final`.

Registration & validation:
- **`ApiModuleManager.php`** — the registry. Holds `name => [group, ObjectFactory spec]`
  maps; lazily instantiates modules through `ObjectFactory` (so `'services'`
  arrays in the spec are DI-resolved), passing `(parentModule, name)` as extra
  constructor args. Groups: `action`, `format` (in `ApiMain`) and `prop`, `list`,
  `meta` (in `ApiQuery`).
- **`Validator/ApiParamValidator.php`** — the bridge from the Action API's
  `getAllowedParams()` settings arrays to the standalone
  `includes/libs/ParamValidator` library. Registers the **type defs** (`integer`,
  `string`, `boolean`, `enum`, `timestamp`, `namespace`, `title`, `user`, `tags`,
  `submodule`, `upload`, `limit`, `expiry`, `password`, `raw`, …) and normalises
  Action-API-specific quirks (e.g. unknown multi-values are ignored, integer
  ranges aren't enforced unless `PARAM_RANGE_ENFORCE`). Converts a
  `ValidationException` into an `ApiUsageException`.
- **`includes/ParamValidator/TypeDef/`** — the MW-aware type defs that need core
  services: `TitleDef`, `UserDef`, `NamespaceDef`, `TagsDef`, `ArrayDef`.
- **`Validator/SubmoduleDef.php`** — the `submodule` type, which is what makes
  `action`/`format`/`prop`/`list`/`meta`/`generator` resolve their values against
  a module manager and drives the recursive help tree.

The query subsystem:
- **`ApiQuery.php`** — the `action=query` dispatcher; a mini-`ApiMain` for read
  submodules. Registers three submodule groups (`prop`/`list`/`meta`), builds the
  shared `ApiPageSet`, runs the requested submodules, and writes continuation.
- **`ApiQueryBase.php`** (`@stable to extend`) — base for submodules; a thin OO
  layer over `SelectQueryBuilder` (`addTables`/`addFields`/`addWhere`/`select`/
  `getDB`) plus result-attachment helpers (`addPageSubItem(s)`,
  `setContinueEnumParameter`).
- **`ApiQueryGeneratorBase.php`** — base for submodules usable as `generator=`;
  adds the `executeGenerator($pageSet)` mode.
- **`ApiPageSet.php`** (~1,600 lines) — resolves `titles=`/`pageids=`/`revids=`
  (or a generator's output) into one shared, normalised set of pages that `prop`
  modules attach data to. The reason `query` batches well.
- **`ApiQueryTokens.php`** — `meta=tokens`; the canonical token-type → salt
  registry (`getTokenTypeSalts()`) and the `ApiQueryTokensRegisterTypes` hook.

Result, continuation, errors, output:
- **`ApiResult.php`** — the metadata-annotated nested-array result tree (see
  "State & data it owns").
- **`ApiContinuationManager.php`** — builds the opaque `continue` blob and the
  `batchcomplete` signal.
- **`ApiErrorFormatter.php`** / **`ApiErrorFormatter_BackCompat.php`** — render
  warnings/errors per the `errorformat` param; the BackCompat one is the
  pre-1.25 default (`bc`).
- **`ApiMessage.php`** / `ApiMessageTrait` — a `Message` that carries a
  machine-readable API error `code` + structured `data`.
- **`ApiFormatBase.php`** + `ApiFormatJson`/`ApiFormatXml`/`ApiFormatPhp`/
  `ApiFormatNone`/`ApiFormatRaw`/`ApiFormatFeedWrapper` — the printers.
- **`ApiHelp.php`** / **`ApiParamInfo.php`** — render the auto-generated help
  (`action=help`) and machine-readable param metadata (`action=paraminfo`).
- Traits like **`ApiWatchlistTrait`**, `ApiBlockInfoTrait`, `ApiCreateTempUserTrait`,
  `ApiAuthManagerHelper` — shared param sets / behaviour mixed into related
  modules.

## Main flows

### The `api.php` lifecycle

The orchestrator is `ApiMain::executeAction()` (the un-error-wrapped core), wrapped
by `executeActionWithErrorHandling()` for external requests (`execute()` picks
between the two based on internal vs external mode). The fixed order:

1. **`setupExecuteAction()`** — `extractRequestParams()` on the *main* module
   (validates `action`, `format`, `maxlag`, `assert`, `errorformat`, `origin`, …).
2. **`checkAsserts()`** — `assert=anon|user|bot` / `assertuser=` checked *early*,
   before the module's own params, so a logged-out bot's "am I logged in?" check
   wins over downstream param errors.
3. **`setupModule()`** — resolve `action` → module via the module manager;
   `extractRequestParams()` on the module; if the module `needsToken()`, require
   POST, require the `token` param, and `validateToken()` (die `apierror-badtoken`
   on mismatch). *Returning `needsToken() === true` is a `LogicException`* — modules
   must return a token-type string.
4. **`checkExecutePermissions()`** — read modules need `read` right; write modules
   need write-API enabled (`$wgEnableWriteAPI`-style) and not read-only; fires the
   **`ApiCheckCanExecute`** hook so extensions can veto.
5. **`checkMaxLag()`** — if `maxlag=` is set and replica lag (optionally inflated
   by job-queue depth) exceeds it, respond `503` with `Retry-After`/`X-Database-Lag`
   and `apierror-maxlag`. Returns false → abort.
6. **`checkConditionalRequestHeaders()`** — ETag / `If-None-Match` /
   `If-Modified-Since` via the module's `getConditionalRequestData()`; may short-
   circuit with `304`.
7. **`setupExternalResponse()`** — method check (405 on bad verb), POST-required
   check, `Content-Length` vs `post_max_size` (413), pick the printer
   (`getCustomPrinter()` or `format=`).
8. **`$module->execute()`** — the module does its work, writing into `getResult()`.
   `APIAfterExecute` hook fires.
9. **`reportUnusedParams()`** — warns about parameters the client sent that no
   module consumed (catches typos).
10. **`printResult()`** — the printer serialises `ApiResult` (applying
    `formatversion`/strip/BC transforms) to the output buffer.

Around all this, `executeActionWithErrorHandling()` adds: CORS preflight handling
(`handleCORS()`, short-circuits `OPTIONS`), output buffering so a mid-stream error
can be wiped and replaced, `MediaWiki::preOutputCommit()` (commit DBs, cookies),
and cache headers (only sent after the body, never public on error). Any
`Throwable` goes to **`handleException()`**: rollback DB writes (unless it's an
intentional `ApiUsageException`), fire `ApiMain::onException`, replace the result
with the formatted error, set `private` cache, emit the **`MediaWiki-API-Error`**
header, and print.

```mermaid
sequenceDiagram
    autonumber
    participant C as HTTP client (bot/gadget/JS)
    participant EP as ApiEntryPoint (api.php)
    participant M as ApiMain
    participant MM as ApiModuleManager
    participant PV as ApiParamValidator
    participant Mod as ApiBase module
    participant R as ApiResult
    participant F as ApiFormat* printer

    C->>EP: GET/POST api.php?action=query&list=...&format=json
    EP->>EP: reject PATH_INFO; set dummy $wgTitle
    EP->>M: new ApiMain(context); ApiBeforeMain hook
    EP->>M: execute() -> executeActionWithErrorHandling()
    M->>M: handleCORS() (OPTIONS short-circuits)
    M->>PV: extractRequestParams() main (action,format,maxlag,assert,errorformat)
    M->>M: checkAsserts(assert/assertuser)
    M->>MM: getModule(action, "action")
    MM-->>M: module instance (ObjectFactory + DI services)
    M->>PV: module.extractRequestParams() (validate/coerce per type defs)
    M->>Mod: validateToken() if needsToken() (POST + CSRF)
    M->>M: checkExecutePermissions() + ApiCheckCanExecute hook
    M->>M: checkMaxLag() / checkConditionalRequestHeaders()
    M->>M: setupExternalResponse() -> pick printer (format / getCustomPrinter)
    M->>Mod: execute()
    Mod->>R: addValue()/setIndexedTagName()/setContinueEnumParameter()
    Mod-->>M: (APIAfterExecute hook)
    M->>M: reportUnusedParams()
    M->>F: printResult(): getResultData() with formatversion/strip transforms
    F-->>M: serialised body (+ Content-Type)
    M->>M: preOutputCommit(); send cache headers
    M-->>C: status + headers + body
    Note over M,C: on Throwable -> handleException(): rollback,<br/>replace result with error, MediaWiki-API-Error header
```

### The query submodule model (`action=query`)

`ApiQuery` is where the API's real read power lives, and it has its *own* dispatch
model orthogonal to the top-level `action`:

- **`prop`** — properties of pages already in the set (`revisions`, `info`,
  `links`, `categories`, `imageinfo`). A prop module never chooses pages; it reads
  the shared `ApiPageSet` and attaches data per page.
- **`list`** — enumerate pages/items by some criterion (`allpages`,
  `categorymembers`, `backlinks`, `recentchanges`, `search`, `usercontribs`).
- **`meta`** — wiki-wide metadata not tied to a page (`siteinfo`, `userinfo`,
  `tokens`, `allmessages`, `languageinfo`).

All three groups are registered into one `ApiModuleManager` (tagged by group),
merging core constants + config (`$wgAPIPropModules` etc.) + the
`ApiQuery::moduleManager` hook. `ApiQuery::execute()` then: instantiates the
requested submodules → applies continuation filtering (skip already-finished
modules) → builds the shared `ApiPageSet` from `titles`/`pageids`/`revids` (or a
`generator=`) → emits shared scaffolding (`normalized`, `redirects`,
`query.pages`) → runs every submodule → writes continuation.

**Generators** are the elegant trick: any `ApiQueryGeneratorBase` subclass can run
in `executeGenerator()` mode to *populate the page set* instead of producing
output. So `generator=allpages&prop=revisions` means "enumerate pages with
allpages, then fetch each one's revisions." Generator params are auto-prefixed
with `g` (e.g. `gaplimit`). Each submodule namespaces its own params with a short
**module prefix** (`revisions`→`rv`, so `rvprop`/`rvlimit`), which is how dozens
coexist in one request.

## State & data it owns

The Action API is request-scoped; the durable state it manipulates belongs to
other subsystems. Within a request it owns:

- **`ApiResult` — the result tree.** One nested PHP array that modules build
  incrementally and a formatter serialises. The hard problem it solves: PHP arrays
  are ambiguous but output formats aren't (`['a','b']` vs `['x'=>1]` must become
  `[...]` vs `{...}` in JSON, attributes vs child elements in XML). So keys
  starting with `_` are **metadata** that encode the producer's intent:
  `_type` (default/array/assoc/kvp + BC variants), `_content` (text-content field,
  the `*` key in legacy output), `_element` (XML tag for indexed-list items, set via
  `setIndexedTagName()`), `_subelements`, `_preservekeys`, `_BC_bools`, `_kvpkeyname`.
  `addValue($path,$name,$value,$flags)` builds the tree; collisions throw unless
  `OVERRIDE`. A **result-size limit** (`$wgAPIMaxResultSize`) is enforced per add
  (sum of scalar `strlen`), emitting `apiwarn-truncatedresult`;
  `NO_SIZE_CHECK` bypasses it for infrastructure (errors, continuation).
  `getResultData($path,$transforms)` is what formatters call to apply the
  format-specific lens.

- **`formatversion` — the legacy/modern serialisation switch, default `1`.**
  `formatversion=1` is the pre-1.25 lossy shape: booleans become
  present-empty-string / absent-key (test with `isset`, not `=== true`),
  content under `*`, numbers stringified, non-ASCII `\u`-escaped. `formatversion=2`
  is real booleans/numbers and UTF-8. **`1` is still the default because changing
  it would break every existing client** — the burden is on new code to opt into
  `2`. `latest` means "newest, accept churn."

- **The `continue` blob + `batchcomplete`.** Opaque string the client echoes back
  to page through large sets. Internally it encodes generator state and the list
  of finished submodules (`<generatorKeys>||<finishedModules>`); submodules set
  their position via `setContinueEnumParameter()`. **Clients must treat it as
  opaque** — its structure tracks MW's internal scheduling and carries no
  compatibility guarantee. `batchcomplete:true` signals "every page in the current
  set has all its requested props" (a self-consistent slice).

- **Per-request error/warning lists** (`errors[]`/`warnings[]` or the legacy `bc`
  single-`error` shape) and the chosen `ApiErrorFormatter`/printer.

## Dependencies (in / out)

In (consumed):
- **`ObjectFactory`** (via `ApiModuleManager` & `ApiParamValidator`) — module and
  type-def construction with DI; this is how legacy `ApiBase` subclasses get
  services despite not using constructor-DI conventions directly. See
  [service-container-and-config](service-container-and-config.md).
- **`includes/libs/ParamValidator`** + `includes/ParamValidator/TypeDef` — all
  parameter typing/coercion (shared with the REST API).
- **`HookContainer`** — many extension points (see below). See
  [hooks-and-extension-registration](hooks-and-extension-registration.md).
- **`Authority`/`User`/`Session`/`PermissionManager`** — read/write authorization,
  `assert`, token validation. See [auth-permissions-sessions](auth-permissions-sessions.md).
- **DB layer** (`IConnectionProvider`, `SelectQueryBuilder`) — `ApiQueryBase::getDB()`
  borrows a replica; write modules use primary. See [database-rdbms](database-rdbms.md).
- **Localisation** — every help/error string is an i18n message. See
  [localisation](localisation.md).
- Config: `$wgAPIModules`, `$wgAPIFormatModules`, `$wgAPIPropModules`/`ListModules`/
  `MetaModules`, `$wgAPIMaxResultSize`, `$wgAPIMaxLagThreshold`, `$wgEnableWriteAPI`,
  `$wgJobQueueIncludeInMaxLagFactor`, etc.

Out (modules call into): storage/revisions, parser/Parsoid, files/uploads, search,
watchlist, blocks, AuthManager — those are the *modules'* dependencies, injected
per module, not the framework's.

Consumed by: the MediaWiki JS front end (`mediawiki.api`), gadgets, bots
(pywikibot etc.), mobile apps, and countless external integrations. The REST API's
`ActionModuleBasedHandler` wraps Action modules during migration.

## Extension / customization points

Three registration mechanisms, all merged at `ApiMain`/`ApiQuery` construction:

1. **Core built-ins** — `ApiMain::MODULES`/`FORMATS` and
   `ApiQuery::QUERY_PROP/LIST/META_MODULES` constants (`name => ['class'=>…, 'services'=>[…]]`).
2. **`extension.json` attributes** — `APIModules`, `APIFormatModules`,
   `APIMetaModules`, `APIPropModules`, `APIListModules` (objects mapping module
   name → ObjectFactory spec). The common path for extensions. Schema:
   `docs/extension.schema.v2.json`.
3. **Hooks** — `ApiMain::moduleManager` and `ApiQuery::moduleManager` mutate the
   manager at runtime; `$wgAPIModules`-style config in `LocalSettings.php`.

Other extension points:
- **Module override surface** (subclass `ApiBase`/`ApiQueryBase`/`ApiQueryGeneratorBase`):
  `execute()`, `getAllowedParams()`, `needsToken()`, `isWriteMode()`,
  `mustBePosted()`, `getCustomPrinter()`, `getExamplesMessages()`, `getHelpUrls()`,
  `getConditionalRequestData()`, `getCacheMode()`.
- **ParamValidator type defs** — declared in `getAllowedParams()` via
  `PARAM_TYPE` + per-type-def constants; new types register through
  `ApiParamValidator::TYPE_DEFS`.
- **Param-level hooks** — `APIGetAllowedParams`, `APIGetParamDescriptionMessages`,
  `APIGetDescriptionMessages` let extensions add params/help to existing modules.
- **Token types** — `ApiQueryTokensRegisterTypes` adds new CSRF token types + salts.
- **Lifecycle hooks** — `ApiBeforeMain`, `ApiCheckCanExecute`, `APIAfterExecute`,
  `ApiMain::onException`, `ApiQueryCheckCanExecute`, `APIQueryAfterExecute`,
  `ApiMaxLagInfo`.

### How to add a new top-level action module

1. Subclass `ApiBase` in `includes/Api/ApiFoo.php` (or your extension). Implement
   `execute()` (write into `$this->getResult()->addValue(...)`),
   `getAllowedParams()` (ParamValidator settings arrays), and
   `getExamplesMessages()`. For a write module: `isWriteMode()` → true,
   `mustBePosted()` → true, `needsToken()` → `'csrf'`. Use `dieWithError()` /
   `dieStatus()` for failures; never `echo`.
2. Register it: core → add to `ApiMain::MODULES`; extension → `APIModules` in
   `extension.json`. List `'services'` for ObjectFactory DI.
3. Add i18n: `apihelp-foo-summary`, `apihelp-foo-extended-description`,
   `apihelp-foo-param-<name>`, `apihelp-foo-example-<n>` in `languages/i18n/en.json`
   (+ `qqq.json`). Help renders automatically from these keys + `getAllowedParams()`.
4. If you added/renamed a class, regenerate `autoload.php`
   (`php maintenance/run.php generateLocalAutoload` — *not run here*;
   `AutoLoaderStructureTest` enforces it).
5. Test: a PHPUnit test under `tests/phpunit/includes/api/` (drive via
   `ApiTestCase`/`ApiMainTest` patterns) and optionally a black-box HTTP test under
   `tests/api-testing/action/`. Run via `composer phpunit` after
   `composer phpunit:config` (*not run here*).

### How to add a query submodule

1. Subclass `ApiQueryBase` (or `ApiQueryGeneratorBase` if it should be usable as
   `generator=`). Implement `execute()` (and `executeGenerator($pageSet)` for
   generators), `getAllowedParams()`, `getCacheMode()` if not private. Pick a unique
   short param prefix (the constructor's 3rd arg) — it namespaces every param.
2. Build queries with the `ApiQueryBase` helpers (`addTables`/`addFields`/
   `addWhere`/`addOption`/`select`), attach results with `addPageSubItem(s)`, and
   page with `setContinueEnumParameter()`.
3. Register under `prop`/`list`/`meta`: core → the matching `ApiQuery` constant;
   extension → `APIPropModules`/`APIListModules`/`APIMetaModules`. Generators are
   auto-discovered from any `ApiQueryGeneratorBase` subclass — no extra registration.
4. i18n + autoload + tests as above. The module path used for help keys is
   `query+<name>` (e.g. `apihelp-query+revisions-summary`).

## Invariants & gotchas

- **The default output is a frozen public contract.** `formatversion=1` and the
  legacy `errorformat=bc` are still the defaults precisely because billions of
  client calls assume them — booleans as empty-string-or-absent, content under
  `*`, single top-level `error`. Changing a default, renaming a result key, or
  altering an existing param's meaning is a breaking change. Backward-incompatible
  changes need a deprecation path: `addDeprecation()` / `@deprecated` params,
  `apiwarn-*` warnings, and the `Api-Deprecation` signalling, announced on
  mediawiki.org. `@stable to extend`/`@stable to call` markers on `ApiBase`/
  `ApiQueryBase` are the *extension* contract; breaking them needs the same care.
- **Tokens: return a string, not `true`.** `needsToken()` must return a token-type
  string (`'csrf'`, `'patrol'`, `'rollback'`, `'userrights'`, `'login'`,
  `'createaccount'`, or a custom one registered via `ApiQueryTokensRegisterTypes`).
  Returning `true` throws a `LogicException` (legacy handling removed). Token
  modules must also be POST-only. Clients fetch tokens via `meta=tokens`; CSRF is
  the catch-all type with empty salt.
- **`maxlag` is the politeness contract for bots.** Well-behaved bots send
  `maxlag=5`; on lag they get `503` + `Retry-After` and should back off. The lag
  number can be inflated by job-queue depth (`$wgJobQueueIncludeInMaxLagFactor`).
  Bots also hit a stricter read-only gate when a majority of replicas are lagged
  (`$wgAPIMaxLagThreshold`).
- **`assert`/`assertuser` guard against silent session loss.** They are checked
  *before* the module's params so a logged-out write doesn't proceed as anon; they
  are the recommended bot safety net.
- **`apihighlimits` right raises caps.** `limit` params cap at `LIMIT_BIG1=500` /
  `LIMIT_SML1=50` for normal users and `LIMIT_BIG2=5000` / `LIMIT_SML2=500` for
  users with `apihighlimits` (bots). Use `max` in `limit` requests to get the
  applicable ceiling.
- **Rate limiting is per-module, not central.** Unlike maxlag/asserts (handled in
  `ApiMain`), individual write modules call `User::pingLimiter()` themselves
  (`ratelimit` action), surfacing `apierror-ratelimited`. There is no API-wide
  throttle in the dispatcher.
- **CORS strips credentials by default.** `origin=*` (anonymous CORS) forces
  `lacksSameOriginSecurity()` and drops the user's credentials (anonymous request,
  `MediaWiki-Login-Suppressed` header) to avoid CSRF; authenticated cross-origin
  needs an explicit allowed `origin` + a CSRF-safe session provider, or
  `crossorigin=1`.
- **The `continue` blob is opaque** — pass it back verbatim; never parse or
  construct it.
- **Errors roll back writes.** A non-`ApiUsageException` Throwable triggers
  `rollbackPrimaryChangesAndLog()`; `ApiUsageException` is treated as intentional
  client error (no rollback). Errors always force `private` cache and emit the
  `MediaWiki-API-Error` header, so clients can detect failure from headers alone.
- **`reportUnusedParams()` warns on typos** — a misspelled param isn't a hard
  error, just a warning, so check `warnings` during development.
- **Help is generated, not hand-written.** Never hand-maintain help text; it is
  derived from `getAllowedParams()` + the `apihelp-<path>-*` message keys.
  `action=paraminfo` exposes the machine-readable version (used by ApiSandbox).
- **`format` defaults to `jsonfm`** (pretty HTML) for browser-friendliness; real
  clients must pass `format=json`.

## Foundation

Builds on: root `AGENTS.md`; `includes/AGENTS.md` (the `Api/` row); the DI
conventions in `docs/Injection.md` (modules are ObjectFactory specs, not raw
constructor-DI); and `docs/Hooks.md` for the hook contract. The `ApiBase`/
`ApiQueryBase` `@stable to extend` markers are the extension contract.

Cross-references:
- [rest-api](rest-api.md) — the sibling API and the "when to use which" table;
  `ActionModuleBasedHandler` bridges Action modules into REST during migration.
- [auth-permissions-sessions](auth-permissions-sessions.md) — `Authority`,
  `Session`, CSRF token salts, the read/write authorization the API consumes.
- [service-container-and-config](service-container-and-config.md) — `ObjectFactory`
  module construction and the `$wgAPI*Modules` config.
- [hooks-and-extension-registration](hooks-and-extension-registration.md) — the
  `extension.json` API attributes and the lifecycle hooks.
- [database-rdbms](database-rdbms.md) — `ApiQueryBase` query builders and
  replica/primary connection handling; `maxlag`.
- [storage-revisions-content](storage-revisions-content.md),
  [parser-and-content-transform](parser-and-content-transform.md),
  [files-media-uploads](files-media-uploads.md) — what the concrete read/write
  modules (`query+revisions`, `parse`, `edit`, `upload`) actually call into.
- [localisation](localisation.md) — the `apihelp-*`/`apiwarn-*`/`apierror-*`
  message keys that drive help and error text.
- [caching-deferred-jobs](caching-deferred-jobs.md) — the API cache-control modes
  (`public`/`private`/`anon-public-user-private`) and `maxlag` job-queue inflation.

## Open questions

- **Authoritative "Public/Stable API policy" doc location.** The shared context
  references a "Public API doc," but no in-repo Markdown specifically codifies the
  Action API backward-compatibility policy (deprecation timelines, what counts as
  a breaking change). The policy is documented on mediawiki.org
  (Manual:Stable_interface_policy / API:Stable_interface), not in this repo; the
  in-repo signal is the `@stable`/`@deprecated`/`@internal` markers and the
  `Api-Deprecation` machinery. Confirm the canonical reference before citing it.
- **`needsToken() === true` legacy.** `ApiMain::setupModule()` still defensively
  throws on `true`, implying some external modules may not yet have migrated; the
  deadline/status of that migration was not found in-repo.
- **`$wgEnableWriteAPI` default & deprecation status.** `checkExecutePermissions`
  gates on `mEnableWrite`; whether write-API-disabled is still a realistic
  deployment (vs effectively always-on) was not determined from the code read here.
- **Action API long-term roadmap vs REST.** The REST doc states both are
  first-class and REST is not a deprecation of the Action API; whether specific
  Action modules are slated to move to REST (beyond the `ActionModuleBasedHandler`
  bridge) is not captured in-repo.
