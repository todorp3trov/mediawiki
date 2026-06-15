# Public API & Extension Contracts

> Scope: **what MediaWiki core exposes to the outside world and how it signals
> what it will keep stable.** Three audiences depend on this surface: PHP
> extension/skin authors (the largest single concern — every Wikimedia feature
> and thousands of third-party features are extensions, *not* in this repo),
> HTTP API clients (bots, gadgets, apps, the JS front end), and downstream PHP
> projects that consume the standalone `wikimedia/*` libraries carved out of
> `includes/libs/`.
>
> This doc owns the *surface* and the *stability-signaling vocabulary*. It does
> **not** own the deprecation *timeline/policy* or the release process — that is
> [`07` Release & Compatibility](07-release-and-compatibility.md). It does not
> re-document the API frameworks themselves — those are the
> [Action API](subsystems/action-api.md), [REST API](subsystems/rest-api.md),
> and [Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md)
> subsystem deep-dives. Read those first; this doc enumerates the *contract* and
> links out.
>
> MW_VERSION 1.47.0-alpha. Counts below come from `grep` over `includes/` and are
> approximate (annotations appear in comments and may be double-counted across a
> class+method); they indicate scale, not exact API size.

---

## What's public vs internal (and how it's signaled)

MediaWiki's PHP API is **closed by default**. Visibility (`public`/`protected`)
is *not* the contract — a `public` method with no stability annotation carries
**no promise** to extensions. Stability is declared explicitly with docblock
annotations. There is **no in-repo document defining these markers** (verified:
nothing under `docs/` defines them except this handbook); the authoritative
"Stable interface policy" lives on mediawiki.org. The in-repo signal *is* the
annotation vocabulary itself.

The vocabulary, with precise meaning and approximate `includes/` counts:

| Annotation | Where it goes | Precise meaning |
|---|---|---|
| `@stable to call` (~174) | method | Extensions may **call** this method; its signature is part of the contract and won't change incompatibly without a deprecation cycle. |
| `@stable to extend` (~174) | class | Extensions may **subclass** this class. Its constructor signature and protected surface are stable — important because adding a required constructor arg would break subclasses. (Example: `ApiBase` is `@stable to extend` at the class level — `includes/Api/ApiBase.php:56`.) |
| `@stable to override` (~869) | method | Extensions that subclass may **override** this specific method; core won't change the contract it calls the override under. The most common marker — most of a `@stable to extend` class's surface is *not* overridable unless individually marked. |
| `@stable to implement` (~594) | interface | Extensions may **implement** this interface; core won't add methods to it without a deprecation cycle (this is the marker on every hook interface — see below). |
| `@newable` (~176) | class | Extensions may directly `new` this class (instantiate it themselves). The default is that you may *not* — most classes must be obtained from a service/factory, so `new`-ing them is unsupported. (Example: `MessageValue` in `includes/libs/Message/MessageValue.php:19`.) |
| `@internal` (~1061) | class/method | **No promise whatsoever.** May change or vanish without a deprecation entry. Do not use from an extension even if it is `public`. (Example: `HookRunner`, `ApiEntryPoint`, `Rest\EntryPoint` are all `@internal`.) |
| `@unstable` (~144) | class/method/config | Public but **experimental** — exists, may be used, but the shape can change without the normal deprecation cycle. Often spelled `@unstable EXPERIMENTAL` (e.g. several `MainConfigSchema.php` entries; `OutputPipelineStages` in the extension schema). |
| `@deprecated since 1.XX` (~1985) | anything | On the way out; a replacement is named. See the deprecation section below. |

Mental model for reading core:

- **No annotation on a `public` member → treat it as `@internal`.** You may be
  able to call it, but core owes you nothing. Inheriting from an unannotated
  class is unsupported.
- The annotations are **directional**: `to call` (you invoke it), `to extend` /
  `to override` (you subclass/override it), `to implement` (you implement an
  interface). A class can be `@stable to extend` while almost none of its
  methods are `@stable to override` — extend it, but only touch the marked seams.
- `@internal` is *narrowing*: it can sit on a `public` symbol to say "public for
  technical reasons (cross-package access), not for you."

Two structural facts reinforce the boundary:

- **`includes/libs/` is the deliberately-decoupled layer** (its `README` says
  the classes "do not call on any other portions of MediaWiki code, and can be
  used in other projects"). Several are published as standalone `wikimedia/*`
  Composer packages (see the library section). Their public surface is a contract
  precisely because external projects consume them.
- **Entry-point and dispatcher classes are `@internal`** (`ApiEntryPoint`,
  `Rest\EntryPoint`, `HookRunner`) — the framework wiring is core's, even though
  the *override surfaces it exposes* (`ApiBase`, `Rest\Handler`, the `XxxHook`
  interfaces) are stable.

> The deprecation *timeline* (how many releases between deprecate and remove),
> the soft-vs-hard rules, and the formal policy text are owned by
> [`07` Release & Compatibility](07-release-and-compatibility.md) and
> mediawiki.org. This doc only defines the *vocabulary*.

---

## HTTP API surface & versioning (Action API + REST API)

The on-the-wire HTTP contract is a **separate, stricter promise** than the PHP
contract: clients cannot be recompiled, so request params and response shapes are
near-frozen and wire changes get their own changelog section (`=== Action API
changes ===` in the release notes). MediaWiki ships **two** machine APIs; they
are siblings, both first-class — REST is *not* a deprecation of the Action API.

### Action API (`api.php` → `includes/Api/`)

The decades-old, module-based workhorse: one endpoint, `action=`/`prop=`/`list=`
query params select a module. Read [action-api](subsystems/action-api.md) for the
framework and lifecycle. The contract highlights:

- **The default output shape is effectively frozen.** Billions of client calls
  assume `formatversion=1` (the lossy legacy shape: booleans as
  present-empty-string-or-absent, content under `*`, stringified numbers) and
  `errorformat=bc` (single top-level `error`). These remain the **defaults**
  because changing them would break every existing client; the burden is on new
  clients to opt into `formatversion=2`. Renaming a result key or changing an
  existing param's meaning is a breaking change.
- **`formatversion` is the versioning lever for output**, not a path/header
  version. `1` (default, frozen), `2` (real booleans/numbers, UTF-8), `latest`
  (newest, accept churn).
- **The `continue` blob is opaque** — clients echo it back verbatim, never parse
  it; its structure carries no compatibility guarantee.
- Deprecating an API param/module uses `addDeprecation()` / `@deprecated` params,
  `apiwarn-*` warnings, and the `Api-Deprecation` signalling — announced on
  mediawiki.org. The 1.47 removal of the `php` response format is a worked
  example (see release notes).
- Auto-generated help (`action=help`) and machine-readable metadata
  (`action=paraminfo`) make the surface self-describing.

### REST API (`rest.php` → `includes/Rest/`)

The modern, route-based API: `path + HTTP verb` selects a Handler. Read
[rest-api](subsystems/rest-api.md) for the framework and the "when to use which"
table. Contract highlights:

- **Versioning lives in the URL path prefix** (`/v1/...`, `content/v1`), not in a
  header or query param.
- **A module's lifecycle/audience is encoded in the `moduleId` suffix**
  (`-beta`, `-internal`) driving `ModuleMode` (`disabled / hidden / discoverable
  / published`), overridable via `$wgRestModuleOverrides`. *(Inferred from the
  subsystem doc: the published/internal/beta distinction is mid-rollout — today
  every designation maps to `DISCOVERABLE` with `// will become PUBLISHED` TODOs.
  Confirm target semantics before relying on it.)*
- **OpenAPI 3.0 specs are generated** per module (`/specs/v0/...`) plus a
  `discovery` endpoint — the surface is self-documenting by design.
- Error contract: throw `HttpException` / `LocalizedHttpException` (both
  `@newable`, `@stable to call`); the standardized JSON error body
  (`httpCode`, `messageTranslations`, `errorKey`) is the wire contract.

**Choosing:** new resource-oriented, HTTP-native endpoints go in REST; anything
needing the Action API's vast module surface, generators, multi-format output, or
batching stays on the Action API. `ActionModuleBasedHandler` bridges an Action
module into a REST route during migration.

The front-end mirrors both: `mw.Api` (Action API) and `mw.Rest` (REST) — see the
mw.* section.

---

## PHP extension points (hooks + the extension.json attribute system)

The PHP extension contract has two halves: **hooks** (observe/override behaviour
at runtime) and **registration attributes** in `extension.json` (declare what an
extension contributes). Both are fully covered in
[hooks-and-extension-registration](subsystems/hooks-and-extension-registration.md);
this is the contract summary.

### Hooks — the primary extension point

- A hook is a one-method interface `XxxHook` with method `onXxx()`, living in a
  `Hook` sub-namespace of the calling component (`MediaWiki\Foo\Hook\XxxHook`).
  There are **~584** such interface files repo-wide.
- The interface carries **`@stable to implement`** — *that interface signature is
  the contract for handlers.* Core fires hooks through `HookRunner`, which is
  **`@internal`**: extensions implement the interface, they do **not** call or
  subclass `HookRunner`. (An extension defining its *own* hooks creates its own
  runner.)
- Extensions register a handler via `extension.json`: a `HookHandlers` entry
  (an ObjectFactory spec — class + injected `services`) plus a `Hooks` mapping
  from hook name to handler. Object handlers get DI; legacy
  string/`Class::method` handlers (and `$wgHooks`) are the pre-1.35 no-DI path.
- Return contract: `false` aborts; `null`/`true` continues; anything else throws.
  Prefer by-reference "replacement" params over `false`.
- Because `HookRunner` is the single most-connected node in core (~1084 edges),
  hooks reach nearly every feature.

### The `extension.json` / `skin.json` manifest

`extension.json` is *the* manifest. `ExtensionRegistry`/`ExtensionProcessor` read
it at bootstrap, validate it against **`docs/extension.schema.v2.json`**
(`manifest_version: 2`; v1 is frozen), and turn it into globals, autoload
entries, and **attributes**. Every contribution an extension can make is a key in
that schema. (`getAttribute()` is the read API; the schema is the authoritative
enumeration.)

Core wiring & lifecycle keys: `manifest_version`, `name`/`namemsg`, `type`,
`requires`/`suggests` (version + ability + inter-extension constraints, checked by
`VersionChecker`), `AutoloadClasses`/`AutoloadNamespaces`,
`TestAutoloadClasses`/`TestAutoloadNamespaces`, `ServiceWiringFiles` (register
DI services), `config`/`config_prefix`/`ConfigRegistry`, `callback`,
`ExtensionFunctions`, `attributes` (free-form attributes consumed by *other*
extensions), `load_composer_autoloader`.

The major *contribution* attribute families (grouped by what they let an
extension add) — see the next section for the registration-based ones, and the
table below for the rest of the system:

| Family | Attributes | Contributes |
|---|---|---|
| Hooks & events | `Hooks`, `HookHandlers`, `DeprecatedHooks`, `DomainEventSubscribers`, `DomainEventIngresses` | hook handlers; deprecate own hooks; subscribe to domain events |
| HTTP APIs | `APIModules`, `APIFormatModules`, `APIMetaModules`, `APIPropModules`, `APIListModules`, `RestRoutes`, `RestModuleFiles` | Action API modules/submodules; REST routes & module files |
| Content & pages | `ContentHandlers`, `namespaces`, `SpecialPages`, `Actions`, `TrackingCategories`, `ShadowPageProviders`, `OutputPipelineStages` (`@unstable`), `ParsoidModules` | content models; namespaces; special pages; page actions; Parsoid extensions |
| Front-end | `ResourceModules`, `ResourceModuleSkinStyles`, `ResourceLoaderSources`, `ResourceFileModulePaths`, `MessagePosterModule`, `QUnitTestModule`, `ValidSkinNames`, `SkinOOUIThemes`/`SkinCodexThemes`/`OOUIThemePaths` | ResourceLoader modules, skins, themes |
| i18n | `MessagesDirs`, `ExtensionMessagesFiles`, `TranslationAliasesDirs`, `RawHtmlMessages` | message files & aliases |
| Identity & rights | `GroupPermissions`, `AvailableRights`, `RevokePermissions`, `GrantPermissions`/`GrantPermissionGroups`/`GrantRiskGroups`, `AddGroups`/`RemoveGroups`/…, `ImplicitGroups`, `PrivilegedGroups`, `RateLimits`, `SessionProviders`, `AuthManagerAutoConfig`, `CentralIdLookupProviders`, `PasswordPolicy`, `ReauthenticateTime`, `TempUser*Providers`/`Mappings`, `UserRegistrationProviders`, `UserOptionsStoreProviders`, `DefaultUserOptions`/`ConditionalUserOptions`/`HiddenPrefs`, credential blacklists | permissions, rights, auth/session providers, user options |
| Background & infra | `JobClasses`, `DatabaseVirtualDomains`, `NotificationMiddleware`/`NotificationHandlers`, `InstallerTasks`, `CodeHighlightProviders`, `RecentChangeSources`/`RecentChangesFlags`, `FeedClasses`, `SearchMappings` | job types, DB virtual domains, notifications, installer tasks |
| Media | `FileExtensions`, `MediaHandlers`, `ForeignResourcesDir` | allowed file types, media handlers |
| Logging | `LogTypes`, `LogNames`, `LogHeaders`, `LogActions`, `LogActionsHandlers`, `LogRestrictions`, `FilterLogTypes`, `ActionFilteredLogs` | log types & formatters |

`skin.json` is the same machinery for skins; `wfLoadExtension('Foo')` /
`wfLoadSkin('Bar')` in `LocalSettings.php` queue the manifest for loading.

---

## Other registration-based extension points (content models, special pages, RL modules, …)

These are "register a class via an `extension.json` attribute; core instantiates
it via ObjectFactory and calls into it through a stable base class/interface." The
common shape: **the attribute is the registration contract; a `@stable to
extend`/`@stable to implement` base type is the code contract.**

- **Content models** — `ContentHandlers` maps a model ID → a `ContentHandler`
  class/ObjectFactory spec. The extension supplies a `ContentHandler` (+ `Content`)
  subclass; this is how non-wikitext content types (JSON, CSS, custom) plug in.
  See [storage-revisions-content](subsystems/storage-revisions-content.md).
- **Special pages** — `SpecialPages` maps a page name → a `SpecialPage` subclass
  spec. See [actions-special-pages-editing](subsystems/actions-special-pages-editing.md).
- **Page actions** — `Actions` maps an action name → an `Action` subclass.
- **API modules** — `APIModules` (top-level `action=`) and
  `APIPropModules`/`APIListModules`/`APIMetaModules` (query submodules) register
  `ApiBase`/`ApiQueryBase` subclasses. `ApiBase`/`ApiQueryBase` are
  `@stable to extend`. See [action-api](subsystems/action-api.md).
- **REST routes** — `RestRoutes` (flat specs → prefix-less module) and
  `RestModuleFiles` (OpenAPI-like module-definition files). Handlers extend the
  `@stable to extend` `Rest\Handler`/`SimpleHandler`. See
  [rest-api](subsystems/rest-api.md).
- **ResourceLoader modules** — `ResourceModules` (the largest schema block)
  declares JS/CSS modules, dependencies, and messages, served by `load.php`.
  See [output-skins-resourceloader](subsystems/output-skins-resourceloader.md).
- **Namespaces** — `namespaces` registers custom namespaces (ID, name,
  content-model, capabilities).
- **Jobs** — `JobClasses` maps a job type → a `Job` (`RunnableJob`) class for the
  job queue. See [caching-deferred-jobs](subsystems/caching-deferred-jobs.md).
- **Services** — `ServiceWiringFiles` lets an extension register DI services into
  `MediaWikiServices`. See
  [service-container-and-config](subsystems/service-container-and-config.md).

---

## Emitted events / domain events

Beyond hooks, core emits **domain events** (`includes/DomainEvent/`, `@since
1.44`; `docs/Events.md`) — a typed observer/listener mechanism that is the
*modern alternative to a certain class of hook* for "something changed"
notifications. Why they exist: PHP interfaces (hooks) can't evolve their method
signatures backward-compatibly, and hooks don't standardize transactional/deferred
semantics; events fix both and are designed to eventually relay over an event bus.

Contract facts an extension author needs:

- **Two ways to observe one event.** `EventDispatchEngine` is built on
  `HookContainer` + `DeferredUpdates`, so **every event type also functions as a
  hook name**. Observe synchronously (in-transaction) via a plain hook handler on
  that name, *or* asynchronously/post-commit via a registered listener.
- **Listeners run after commit, never inside the transaction**, with
  **at-least-once** delivery — so **listeners must be idempotent.**
- Extensions subscribe by registering a `DomainEventIngress` subclass under the
  `DomainEventIngresses` (or `DomainEventSubscribers`) attribute with an `events`
  list; the ingress auto-discovers `handle{EventType}Event()` methods.

Core's emitted event surface today is centered on the page lifecycle
(`includes/Page/Event/`), each a `DomainEvent` subclass declaring a stable type
string:

| Event class | Type string |
|---|---|
| `PageCreatedEvent` | `PageCreated` |
| `PageMovedEvent` | `PageMoved` |
| `PageDeletedEvent` | `PageDeleted` |
| `PageLatestRevisionChangedEvent` | `PageLatestRevisionChanged` (also emits `PageRevisionUpdated`) |
| `PageRecordChangedEvent` | `PageRecordChanged` |
| `PageProtectionChangedEvent` | `PageProtectionChanged` |
| `PageHistoryVisibilityChangedEvent` | `PageHistoryVisibilityChanged` |
| `PageEvent` (base) | `Page` (parent type in the event-type chain) |

Core consumes some of these internally via ingresses
(`SearchEventIngress`, `ChangeTrackingEventIngress`, `LanguageEventIngress`).
Full mechanics: [hooks-and-extension-registration](subsystems/hooks-and-extension-registration.md)
and `docs/Events.md`.

---

## Library public surface (includes/libs → wikimedia/* packages) & the front-end mw.* API

### The publishable PHP libraries

`includes/libs/` holds **standalone, framework-agnostic** code (no `$wg*`
globals, no service-locator access — enforced by convention; its `README` states
it "can be used in other projects without dependency issues"). A subset is
**authored here and published outward** as separate `wikimedia/*` Composer
packages — their public surface is a real contract for external consumers.

A key, easily-missed distinction:

- **Authored in-repo, published out** — these live under `includes/libs/` in the
  `Wikimedia\` namespace and are *not* `require`d from `vendor/` (verified: no
  `wikimedia/rdbms`, `wikimedia/param-validator`, `wikimedia/stats`, `wikimedia/file*`
  in `composer.json` `require`). Examples (autoload-confirmed):
  `Wikimedia\Rdbms\*` (`includes/libs/Rdbms/`),
  `Wikimedia\ParamValidator\*` (`includes/libs/ParamValidator/`),
  `Wikimedia\Stats\*` (`includes/libs/Stats/`), plus `FileBackend`, `ObjectCache`,
  `Message`, `Mime`, `Http`, `StringUtils`, `Diff`, `WRStats`, etc.
- **Authored elsewhere, consumed in** — `composer.json` `require`s ~30
  `wikimedia/*` packages from `vendor/` (e.g. `wikimedia/assert`,
  `wikimedia/services`, `wikimedia/object-factory`, `wikimedia/ip-utils`,
  `wikimedia/remex-html`, `wikimedia/css-sanitizer`, `wikimedia/minify`,
  `wikimedia/parsoid`, `wikimedia/scoped-callback`, …), plus `oojs/oojs-ui` and
  `wikimedia/codex`.

The `composer.json` `replace` block lists only polyfills (`symfony/polyfill-*`)
and `krinkle/intuition` — packages core *provides* so they are never installed;
it is **not** how the `includes/libs` packages are published. *(Inference: the
in-repo `includes/libs` copies are the source of truth that is mirrored/published
to the standalone `wikimedia/*` repos; the exact publishing pipeline is off-repo.
See open questions.)*

For an extension developer, the practical contract: treat the public surface of
these libraries (Rdbms query builders, ParamValidator, Stats, etc.) as stable
API, and keep any new code you add under `includes/libs/` decoupled from MW
globals so it stays publishable.

### The front-end `mw.*` JavaScript API

The browser-side public API for user scripts, gadgets, skins, and extensions is
the `mw.*` global namespace, documented in
[`resources/README.md`](../../resources/README.md) (the authoritative front-end
API index) and served as ResourceLoader modules via `load.php`. Headline surfaces:

- **Modules & config:** `mw.loader` (dependency loading), `mw.config`
  (per-page/site config values), `mw.hook` + global JS events (client-side
  hooks).
- **APIs:** `mw.Api` (Action API client) and `mw.Rest` (REST API client) — the
  JS mirrors of the two HTTP APIs above.
- **i18n & UI:** `mw.message`/`mw.msg`, `mw.language`, `mw.notification`.
- **Identity & pages:** `mw.user`, `mw.Title`, `mw.Uri`, `mw.util`.
- **Debug/deprecation:** `mw.log`, `mw.log.deprecate(...)`
  (`resources/src/mediawiki.base/log.js:101`) — the JS analogue of
  `wfDeprecated()`; it wraps a property so accessing the old name emits a
  deprecation warning and fires `mw.track('mw.deprecate', key)`.
- **Upstream libs:** OOjs and OOUI (and Codex/Vue) are part of the front-end
  surface.

Front-end modules are registered in `resources/Resources.php` (core) or the
`ResourceModules` attribute (extensions). See
[output-skins-resourceloader](subsystems/output-skins-resourceloader.md).

---

## Stability guarantees & how deprecation is signaled (→ see Release & Compatibility)

How a change to the public surface is *signaled* (the timeline/policy is owned by
[`07` Release & Compatibility](07-release-and-compatibility.md)):

- **PHP symbols:** mark `@deprecated since 1.XX` in the docblock and name the
  replacement (**soft** deprecation — no runtime warning, starts the clock). To
  **hard**-deprecate, additionally call `wfDeprecated()` / `wfDeprecatedMsg()`
  (or `MWDebug::detectDeprecatedOverride()` for overridden methods) so callers get
  a runtime warning (deduped once per call site). `~1985` `@deprecated` markers
  exist across `includes/`. Operator/dev knobs: `$wgDevelopmentWarnings`,
  `$wgDeprecationReleaseLimit` (see doc 07).
- **Hooks:** add to `DeprecatedHooks` (core literal or the `DeprecatedHooks`
  attribute) and mark the *interface* `@deprecated`; migrating extensions
  acknowledge with `"deprecated": true` on the handler to enable call-filtering.
- **Action API:** `addDeprecation()` / `@deprecated` params, `apiwarn-*`
  warnings, and the `Api-Deprecation` response signalling; wire removals are
  tracked in the `=== Action API changes ===` release-notes section.
- **REST API:** path-prefix versioning (`/v1` → `/v2`) and the `moduleId`
  audience suffix; deprecation headers applied per-handler.
- **Front-end:** `mw.log.deprecate()` wraps the old symbol with a warning.

The guarantee in one line: **anything marked `@stable to *` (or part of the
default HTTP wire shape, or a `wikimedia/*` library's public surface) requires a
deprecation cycle to change; anything `@internal`/`@unstable`/unannotated does
not.** The exact cycle length and the formal policy are
[`07`](07-release-and-compatibility.md) + mediawiki.org.

---

## Foundation (links)

This doc builds on and links to (does not duplicate):

- **Root [`AGENTS.md`](../../AGENTS.md) / `CLAUDE.md`** — repo conventions:
  `@stable to call`/`@stable to extend` = extension-facing; `@internal`/`@unstable`
  not; `extension.json` is the manifest; `includes/libs/` must stay decoupled.
- **[`includes/AGENTS.md`](../../includes/AGENTS.md)** — the PHP core module map
  (the spine: Hook system + `MediaWikiServices`).
- **Subsystem deep-dives (the frameworks behind this surface):**
  - [Action API](subsystems/action-api.md) — the `api.php` framework & wire contract.
  - [REST API](subsystems/rest-api.md) — the `rest.php` framework & path versioning.
  - [Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md)
    — hooks, `extension.json`/`ExtensionProcessor`, domain events (the core of the PHP extension contract).
  - [Service Container & Config](subsystems/service-container-and-config.md) —
    ObjectFactory/DI that instantiates every registered extension class; `$wg*` schema.
  - [Storage/Revisions/Content](subsystems/storage-revisions-content.md),
    [Actions/Special-pages/Editing](subsystems/actions-special-pages-editing.md),
    [Output/Skins/ResourceLoader](subsystems/output-skins-resourceloader.md),
    [Caching/Deferred/Jobs](subsystems/caching-deferred-jobs.md) — the homes of
    content models, special pages, RL modules, and jobs respectively.
- **Sibling handbook doc:** [`07` Release & Compatibility](07-release-and-compatibility.md)
  — owns the deprecation *timeline/policy*, versioning, and release process.
  This doc owns the *surface and how stability is signaled*.
- **In-repo source of truth:** `docs/extension.schema.v2.json` (the attribute
  enumeration), `docs/Hooks.md`, `docs/Events.md`, `docs/Injection.md`,
  `resources/README.md` (mw.* index), `includes/libs/README`, `composer.json`
  (`require`/`replace`).
- **Authoritative off-repo policy:** the **"Stable interface policy"** is on
  **mediawiki.org** — there is **no in-repo document** defining the `@stable`/
  `@internal`/`@newable` markers (verified). Defer to the wiki for the policy text.

---

### Open questions / genuine unknowns

- **The publishing pipeline for `includes/libs` → `wikimedia/*`.** It is verified
  that `Wikimedia\Rdbms`/`ParamValidator`/`Stats`/etc. live in-repo (not
  `require`d from vendor) while ~30 other `wikimedia/*` packages are consumed from
  vendor. The *direction* (in-repo copies published outward) is inferred from the
  `includes/libs/README` decoupling rule and the absence of these from `require`;
  the exact mirror/release mechanism is off-repo and not confirmed here.
- **REST audience-designation semantics.** The published/internal/beta
  distinction (`ModuleMode`) is mid-rollout per the REST subsystem doc (everything
  currently maps to `DISCOVERABLE`); the end-state stability meaning of each tier
  is not yet active.
- **No in-repo marker definitions.** The precise normative meaning of
  `@stable to call` vs `@stable to override` vs `@newable` (and the deprecation
  cycle length) is policy on mediawiki.org, not encoded in the tree; the
  definitions above are reconstructed from usage + conventions and should be
  cross-checked against the Stable interface policy before being treated as
  normative.
- **`@unstable` precise contract.** It clearly means "experimental, may change
  without the normal cycle," but whether it carries any weaker guarantee than
  `@internal` (e.g. announced-before-change) was not determinable from the code.
