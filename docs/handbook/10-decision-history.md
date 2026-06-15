# Decision History

> Scope: the *why* behind MediaWiki core's biggest architectural choices, so a
> new senior engineer does not relitigate settled decisions or re-attempt
> abandoned ones. This document is deliberately about **rationale and direction**,
> not mechanics — for *how* each subsystem works see the deep-dives under
> `docs/handbook/subsystems/` (linked at the end).

## How to read this (documented vs reconstructed)

MediaWiki has **no in-repo ADR / decisions / RFC directory.** Architectural
decisions are made and recorded *outside this tree*:

- **Phabricator** (`phabricator.wikimedia.org`, tasks like `T12345`) — the RFC /
  **Technical Decision Making (TDM)** process lives here. Code comments and
  commit messages cite these task IDs; that citation is usually the only
  in-repo pointer to the "why."
- **wikitech-l** mailing list and **mediawiki.org** wiki pages (e.g.
  *Manual:Stable interface policy*, *Manual:Domain events*) — the prose policy.
- **Gerrit** (`gerrit.wikimedia.org`) commit messages — frequently carry a
  `Bug: T#####` footer and a sentence of rationale.

Because of that, this chapter mixes three kinds of statement, and **each entry
is tagged**:

- **[Documented]** — the rationale is stated in the repo: a class/file docblock,
  `docs/Injection.md`, `docs/Events.md`, a commit message, or a `RELEASE-NOTES`
  entry. The strongest sources are `docs/Injection.md` (DI) and `docs/Events.md`
  (domain events), which are *intentional rationale documents*.
- **[Inference]** — reconstructed from code shape, `@since`/`@deprecated` tags,
  and git history. Plausible, consistent with the evidence, but **not stated as
  rationale anywhere in-repo**. The classic-history framings ("X replaced Y")
  are often inferences even when the *fact* of the replacement is documented.
- **[Dated: git]** — a commit hash + date I verified with read-only
  `git log`. Dates are **when the change landed in this repo's history** (often
  the merge to master), which precedes the tagged release; they anchor sequence,
  not exact ship dates.

The **most reliable temporal axis is the MediaWiki version number**
(`@since 1.NN`, `@deprecated since 1.NN`), pulled straight from docblocks. The
current tree is **`MW_VERSION = 1.47.0-alpha`** (`includes/Defines.php:23`,
verified). No calendar dates appear in the subsystem docs themselves — all their
anchors are version numbers; the dates below come from git.

When in doubt, the entry says so. **A reconstructed rationale presented as fact
is actively harmful** here — if you need the real "why" for a patch, follow the
`T#####` to Phabricator rather than trusting an [Inference] tag.

---

## Key decisions (one entry each: context → decision → why → what it replaced / alternatives)

### 1. PHP globals + `wf*()` + static singletons → service container + constructor DI

- **Context.** MediaWiki began in the early 2000s as a PHP-globals codebase:
  `$wgXxx` configuration globals, `wf*()` free functions
  (`includes/GlobalFunctions.php`), and classes that managed their own
  singletons via static `getInstance()`/`newFrom*()`. This is convenient at
  small scale but makes code untestable, hides dependencies, and prevents
  running multiple wikis/configs in one process.
- **Decision.** Introduce a central **service locator**, `MediaWikiServices`,
  wired in `includes/ServiceWiring.php`, and migrate code to **constructor
  dependency injection**. Value objects (immutable, no business logic) +
  stateless service objects became the target architecture.
- **Why. [Documented]** `docs/Injection.md` is the authoritative rationale:
  reduce strong coupling, make dependencies explicit and narrow, keep services
  *deterministic and agnostic of global/request state* so they are safe in web,
  API, job, and CLI contexts and can eventually be instantiated across wikis.
  The origin is **RFC `T384`** (cited at the top of `docs/Injection.md`).
- **What it replaced / alternatives.** Direct `$wgXxx` reads (now bridged by
  `GlobalVarConfig`, which reads `$GLOBALS['wg*']` so the modern `Config` and the
  legacy globals are *two views of the same data during the migration* —
  [Documented], service-container deep-dive), `wfGetDB()`, `Foo::getInstance()`,
  and `new Foo()` direct instantiation. `docs/Injection.md` ships explicit
  migration recipes for each.
- **State.** **In flight, with an unambiguous direction.** As of 1.39 (2022)
  `docs/Injection.md` says DI is adopted "in much of its code," but "some
  operations still require singletons or global state." Both styles are
  "correct" depending on a class's vintage. `MediaWikiServices::getInstance()`
  is explicitly **a migration stepping stone** for static entry points (hook
  handlers, `newFromGlobalState()` shims) only — **never inject
  `MediaWikiServices` into business logic.**
- **Dates: git.** `MediaWikiServices` / `ServiceWiring.php` introduced
  `eb46307b001` "Introduce top level service locator." **2015-10-12** → the DI
  era began ~MW 1.27. `includes/libs/` (the standalone `wikimedia/*` libraries)
  is held to a *stricter* version of this rule — it must not touch
  `$wg*`/`MediaWikiServices` at all so it stays independently publishable
  (see decision #9).

### 2. Multi-Content Revisions (MCR): single text blob → named content slots

- **Context.** Historically a revision pointed at exactly one text blob
  (`rev_text_id` → `text` table). One revision = one wikitext body. Extensions
  wanting structured data alongside the article (Wikibase-style derived data,
  templated metadata, page-associated structured content) had nowhere to put it
  except by overloading the main wikitext.
- **Decision.** A revision now carries **one or more named slots**
  (`page → revision → slots → content → blob`), each slot with its own content
  model, versioned together atomically. The `revision` table became
  **metadata-only** — `rev_text_id` is gone (the "MCR split").
- **Why. [Inference for the motivation; Documented for the model]** The
  multiple-content-streams motivation is the doc author's synthesis (not quoted
  from a docblock), but the *model* is documented in `sql/tables.json` and the
  storage classes, and `slot_origin` (inherited slots: a section edit reuses
  prior content rows rather than re-storing them) is documented behavior.
- **What it replaced / alternatives.**
  - The **single-text-blob model** (`rev_text_id` → `text`). The `text` table
    survives as the legacy blob store; its `old_text`/`old_flags` field names are
    a **1.4-era holdover** ([Documented]).
  - The **old `Revision` class** → split into the immutable read view
    `RevisionRecord` (concrete: `RevisionStoreRecord`; write/proto:
    `MutableRevisionRecord`) and the gateway service `RevisionStore`.
    `RevisionStore` is **@since 1.31**, re-namespaced from `Storage` to
    `Revision` in **1.32**. `PageUpdater` (the canonical edit API) and
    `RevisionSlotsUpdate` are @since 1.32; `SlotRoleRegistry` @since 1.33.
- **State.** Landed and the dominant model; the surrounding `WikiPage`
  god-object is still being decomposed into `PageStore`/`PageUpdater`/
  `DerivedPageDataUpdater` (its `doEditUpdates()`/`prepareContentForEdit()`/
  `doUserEditContent()` are `@deprecated`).
- **Dates: git.** `e61a1caaddb` "[MCR] Break Revision into RevisionRecord and
  RevisionStore" **2017-08-27**; re-namespaced `dff469a408d` **2018-09-20**.

### 3. Scattered `User->isAllowed()` checks → the `Authority` abstraction

- **Context.** Permission checks were spread across the codebase as direct calls
  on the `User` god-object (`$user->isAllowed('edit')`, `User::getEditToken`,
  etc.). `User` (~107 KB) simultaneously models identity, options, email contact,
  *and* permissions — coupling permission logic to a specific concrete object and
  to global request state.
- **Decision.** Introduce the **`Authority`** interface as "the authority of the
  current execution context" — the abstraction new code depends on for *can this
  actor do this?* (`isAllowed`/`probablyCan`/`definitelyCan`/`authorizeAction`/
  `authorizeRead`/`authorizeWrite`). Production implementation `UserAuthority`
  wraps a `User` + request context + `PermissionManager` + `RateLimiter`.
- **Why. [Documented fact, Inference for framing]** The boundary is documented:
  application logic should ask `Authority`, never `User->isAllowed()` directly.
  `PermissionManager` is the engine behind `UserAuthority`. The deliberate
  **rigor ladder** (`RIGOR_QUICK`/`RIGOR_FULL`/`RIGOR_SECURE`) is a documented,
  test-pinned (`UserAuthorityTest`) cost/thoroughness trade-off — e.g.
  `authorizeWrite` consults the **primary DB** so a just-made block/protection
  change isn't missed via replication lag, while reads use the replica on
  purpose.
- **What it replaced / alternatives.** Direct `User->isAllowed()` /
  `PermissionManager` use in new code; `User::getEditToken` → `CsrfTokenSet`
  (@since 1.37); `User::newFrom*` statics → `UserFactory`. `User`'s permission
  methods are now `@deprecated` thin shims over `Authority` — "`User` is being
  dismantled."
- **State.** In flight. `Authority` @since 1.36; the migration of call sites off
  `User` is ongoing.
- **Dates: git.** `0ac16e53aa3` "Introduce Authority interface" **2021-01-05**,
  `Bug: T261963`. The commit body calls it "a basis for spike exploring the
  concept" — i.e. it started as exploratory, which fits the still-in-flight state.

### 4. A REST API introduced *alongside* (not replacing) the Action API

- **Context.** The Action API (`api.php`, one endpoint, `action=`/`list=`/`prop=`
  module selection) is decades old and "wildly depended upon" — billions of
  client calls assume its exact default output shape.
- **Decision.** Add a **second, separate** REST API (`rest.php`, many endpoints,
  path + HTTP verb selects a handler, resource-shaped URLs, status codes,
  ETag/Last-Modified, OpenAPI spec) **without deprecating the Action API.**
  Both are "first-class."
- **Why. [Documented]** The subsystem docs state plainly that REST "is *not* a
  deprecation of the Action API." The two serve different needs:
  - **Action API** — vast, battle-tested module surface; generators,
    continuation, batching, multi-format output (json/xml/php); its *default
    output shape is a public contract that effectively cannot break.*
  - **REST API** — newer, deliberately smaller, HTTP-native, resource-oriented;
    modern constructor DI; JSON-first.
  - **Rule of thumb:** new resource-oriented HTTP-native endpoints go in REST;
    anything needing the huge module surface, generators, multi-format output, or
    batching stays on the Action API.
  - The `ActionModuleBasedHandler` bridge exists precisely to wrap an Action API
    module from a REST route during migration ([Documented class, framing
    partly inferred]).
- **What it replaced / alternatives.** Did not replace anything — it is a
  *parallel* surface. Note it deliberately uses MediaWiki's *own* PSR-7-*flavoured*
  `RequestInterface`/`ResponseInterface`, **not** literal `psr/http-message`
  (whether PSR-7 will eventually back them is an open question — see below).
- **State.** REST framework actively growing (Modules layer @since 1.43,
  ModuleManager @since 1.46, ModuleMode/AudienceDesignation 1.47).
- **Dates: git.** `3f0056a252d` "REST API initial commit" **2019-05-09**
  (~MW 1.34).

### 5. A typed Domain Event system added *alongside* hooks

- **Context.** Hooks (`XxxHook`/`onXxx`, dispatched via `HookContainer`/
  `HookRunner`) are MediaWiki's universal extension mechanism, but they are a
  poor fit for "something changed" notifications: PHP interfaces make hook
  signatures impossible to evolve backward-compatibly, and the transactional
  semantics of a hook handler (does it run inside the DB transaction?) are
  unclear.
- **Decision.** Introduce **Domain Events** (`docs/Events.md`) — an
  observer/listener mechanism for "something happened" events
  (`PageLatestRevisionChangedEvent`, `PageCreatedEvent`, …), **@since 1.44**,
  *as a complement to hooks, not a wholesale replacement.*
- **Why. [Documented — `docs/Events.md` is intentional rationale]** Sustainability:
  apply the observer pattern to improve component boundaries; clarify
  transactional/deferred semantics; **escape the rigidity of PHP-interface hook
  signatures** that can't be changed compatibly; and prepare for a future
  event-bus relay that can broadcast events between wikis/services.
- **Key tribal fact. [Documented]** The dispatch engine sits on top of
  `HookContainer` + `DeferredUpdates`, so **every event type also functions as a
  hook name.** There are two ways to observe an event: *synchronously* via a hook
  handler on that name, or *asynchronously / post-commit* via a registered
  listener (run through `DeferredUpdates`). Domain events deliver **after the
  DB transaction commits, never inside it**, with at-least-once semantics — so
  **listeners must be idempotent.**
- **What it replaced / alternatives.** Targeted at the "something changed" *class*
  of hook (the typed `Page/Event/*` events are the modern successors to legacy
  hooks like `PageContentSaveComplete` → `PageSaveComplete` in 1.35); the
  synchronous-hook path is intentionally preserved because event types double as
  hook names.
- **Dates: git.** `5febca16489` "Introduce DomainEventDispatcher"
  **2024-09-01**; framework made stable for the 1.44 release shortly after.

### 6. Parsoid as the strategic parser direction (legacy `Parser` still default)

- **Context.** MediaWiki has a legacy PHP wikitext parser (`includes/parser/
  Parser`), pure-PHP and tightly coupled to PHP rendering. Visual editing, HTML
  round-tripping, and a clean DOM model needed a different engine; **Parsoid**
  (`wikimedia/parsoid`, a *separate Composer package*) was built for that.
- **Decision.** Treat **Parsoid as the strategic direction**; core is "actively
  migrating to" it. Both parsers currently coexist — the legacy `Parser` is
  still the default for most page views; Parsoid is reached through glue in
  `includes/parser/Parsoid/`.
- **Why. [Documented — code docblock + task]** Tracked in **`T236809`**, cited
  in multiple in-tree docblocks. `ParsoidParser.php`'s own docblock says
  *"eventually this will extend `\Parser`"* — i.e. the two parsers are meant to
  *converge on one interface*. "The direction of travel is *toward* Parsoid."
- **What it replaced / alternatives.** Does **not** yet replace the legacy parser
  by default; it is the intended convergence target. Note the two engines
  **diverge in HTML output by design** — parser tests carry both `html/php` and
  `html/parsoid` expectations; *do not assume a legacy fix is a Parsoid fix.*
  (Separately, the old DOM-based preprocessor is gone; `Preprocessor_Hash` is the
  only implementation — [Documented].)
- **State.** In flight; which page views use Parsoid on a given wiki is a
  *deployment/config* decision, not determinable from the source tree.
  `ParsoidParser` @since 1.41 and `@unstable`.

### 7. The `Title` god-object → value objects (`LinkTarget`/`PageReference`/`PageIdentity`) + services

- **Context.** `Title` (~3.8k lines) is the single most-connected domain object:
  it implements both `LinkTarget` and `PageIdentity`, is **mutable**, reaches
  into the service container statically, and lazily queries the DB. It threads
  through ~169 call sites.
- **Decision.** Replace it with **small, immutable, side-effect-free pieces**:
  the interface ladder `LinkTarget` → `TitleValue` → `PageReference`/
  `PageReferenceValue` → `PageIdentity`/`PageIdentityValue` → `ProperPageIdentity`,
  plus services `TitleParser` (source of truth for validity), `TitleFormatter`,
  `LinkRenderer`, `LinkBatchFactory`.
- **Why. [Documented — verbatim in interface docblocks, the strongest-sourced
  rationale in this set]** The `@note`s on `PageIdentity` literally say: `Title`
  is the *only* `PageIdentity` allowed to represent non-pages, the *only* one
  allowed to be mutable, and that "once Title has been removed… the distinction
  between `PageIdentity` and `ProperPageIdentity` becomes redundant." That is the
  migration thesis, stated in code. The end state: `ProperPageIdentity` is what
  `PageIdentity` collapses into once `Title` is gone.
- **What it replaced / alternatives.** `Linker::link()` (deprecated since 1.28) →
  `LinkRenderer`; `MediaWikiTitleCodec` (deprecated since 1.44, now a near-empty
  delegating stub) → `TitleParser` + `TitleFormatter`; `Title::newFrom*` statics
  → `TitleParser`/services (`TitleFactory` exists *only* to make those statics
  mockable in tests — "there is nothing interesting in this class," per its own
  docblock). New code depends on the *interfaces and services*, not `Title`.
- **State.** A multi-year, deliberately incremental effort with **no in-tree
  dated roadmap.** Treat "decompose Title" as a *direction, not a deadline*
  ([Inference, doc-flagged]). `Title::toPageIdentity()` is the recommended exit
  hatch. (Real coupling note: MediaWiki's `LinkTarget` *extends Parsoid's*
  `LinkTarget`, and `TitleValue` uses Parsoid's `LinkTargetTrait`.)

### 8. Abstract schema (`sql/tables.json`) → generated per-DB SQL

- **Context.** SQL DDL had to be hand-maintained per database engine, which
  drifts and is error-prone.
- **Decision.** Define the schema **once** in abstract form (`sql/tables.json`,
  abstract changes in `sql/abstractSchemaChanges/`) and **generate** the per-DBMS
  SQL (`sql/mysql`, `sql/postgres`, `sql/sqlite`) via a DBAL layer that wraps
  **Doctrine DBAL** (`maintenance/run generateSchemaSql` /
  `generateSchemaChangeSql`). `AbstractSchemaTest` byte-matches the generated SQL
  as a CI gate.
- **Why. [Inference for the "replaced hand-maintained SQL" framing; Documented
  for the mechanism]** The subsystem docs document the *current* generated regime
  but do not narrate the prior hand-maintained state or cite an introducing task.
  The clear goal is "one definition targets MySQL, PostgreSQL, and SQLite without
  per-DB drift."
- **What it replaced / alternatives.** Hand-written per-engine SQL. Note this is
  also when the supported-DB set narrowed: **Oracle and MSSQL were dropped**
  (`4d10bb14e81`, **2019-08-13**), leaving MySQL/MariaDB (canonical), PostgreSQL,
  SQLite. MySQL is the canonical target — queries are tuned for it. The schema
  declares almost no physical FOREIGN KEY constraints; integrity is enforced in
  application code (a historical MySQL-replication/performance/portability choice
  — [Inference, doc-flagged]).
- **State.** Landed and enforced.
- **Dates: git.** `8a4c4004123` "Introduce maintenance/generateSchemaSql.php"
  **2020-01-18**; empty abstract schema wired into the installer **2020-05-09**
  (~MW 1.35).

### 9. Carving standalone `wikimedia/*` libraries out of `includes/libs/`

- **Context.** Generic, reusable infrastructure (the Rdbms database abstraction,
  object cache, `ParamValidator`, file backends, etc.) lived inside MediaWiki and
  was coupled to its globals.
- **Decision.** Keep that code under `includes/libs/` but treat it as
  **framework-agnostic**, mirrored as standalone `wikimedia/*` Composer packages.
- **Why. [Documented]** So the libraries remain **independently publishable and
  reusable** outside MediaWiki. The hard rule: `includes/libs/` **must not touch
  DI/config** — no `$wg*` globals, no `MediaWikiServices`. Trade-off explicitly
  acknowledged: clean reusable boundaries vs. some duplication/indirection.
- **State.** Established convention.

### 10. Gerrit (not GitHub PRs) for code review

- **Context.** MediaWiki development predates GitHub's PR model and runs on
  Wikimedia's own infrastructure.
- **Decision.** Code review happens on **Gerrit** (`gerrit.wikimedia.org`,
  project `mediawiki/core.git`); the canonical repo this checkout mirrors is
  Gerrit, not GitHub. Verified: `.gitreview` points at
  `host=gerrit.wikimedia.org`, `project=mediawiki/core.git`.
- **Why. [Inference — not stated in-repo]** Gerrit's patchset-based,
  per-commit, rebase-oriented review with a stable **`Change-Id`** footer suits a
  large, long-lived, commit-granular project and integrates with Wikimedia CI
  (Quibble) and Phabricator. *This rationale is reconstructed; no in-repo
  document states it.*
- **Consequences in the tree.** Every commit carries a `Change-Id:` trailer (see
  any `git log` body); `.gitmessage` is the commit template; `Bug: T#####`
  footers link to Phabricator; `.git-blame-ignore-revs` lists bulk-reformatting
  commits. **GitHub is a read-only mirror — PRs there are not the contribution
  path.**

---

## Major pivots & long-running migrations (in flight today)

These are the live fronts. Touching code in these areas means you are walking
into a migration — check the current stage before assuming either the old or new
shape.

| Migration | From → To | State / version | Where |
|---|---|---|---|
| **Globals → DI** | `$wg*`/`wf*()`/singletons → `MediaWikiServices` + constructor injection | In flight since ~1.27 (2015); "much of code" by 1.39 | `docs/Injection.md`, service-container deep-dive |
| **`Title` decomposition** | `Title` god-object → `LinkTarget`/`PageIdentity` value objects + services | Multi-year, no committed end date | title-linking deep-dive |
| **`WikiPage`/edit decomposition** | `WikiPage`/`EditPage` monoliths → `PageStore`/`PageUpdater`/`PageEdit` | EditPage→PageEdit save engine @since 1.47 (`T157658`) | actions/editing + storage deep-dives |
| **File-tables migration** | `image`/`oldimage` → normalized `file`/`filerevision`/`filetypes` | write @1.44, read @1.47; default still `SCHEMA_COMPAT_OLD` | files-media deep-dive, `04-data-model.md` |
| **Normalized link tables** | denormalized `(namespace,title)` → `linktarget` FK | in flight (`LinksMigration`/`LinkTargetStore`) | title-linking + data-model |
| **Parsoid convergence** | legacy `Parser` (default) → Parsoid (`T236809`) | dual-engine; Parsoid @1.41 `@unstable` | parser deep-dive |
| **Domain events vs hooks** | "something changed" hooks → typed Domain Events | events @since 1.44, both coexist | `docs/Events.md`, hooks deep-dive |
| **`User` dismantling** | `User` god-object → `Authority`/`UserIdentity`/`UserFactory`/narrow services | in flight; permission methods deprecated shims | auth deep-dive |
| **REST surface growth** | (parallel to Action API, not a migration off it) | actively growing 1.43–1.47 | rest-api deep-dive |

**The `SCHEMA_COMPAT_*` staged-migration framework is itself a meta-decision
worth knowing. [Documented]** Big tables (actor, comment, linktarget, file)
migrate via bit-flags (`WRITE_OLD`/`READ_OLD`/`WRITE_NEW`/`READ_NEW`, defined in
`includes/Defines.php`) following a canonical 7-stage, rollback-safe sequence
(add new schema → dual-write → backfill → read-new → write-new only → cleanup).
**Why:** "a plain `ALTER TABLE` is not acceptable for a billion-row table on a
live Wikimedia cluster," and the *same code* must serve both a small wiki
(flip straight to NEW) and WMF (step through every stage). The actor and comment
normalizations already went through this; the file tables are mid-flight now
(see commit `1e11a4bda59` in this checkout's recent history, auditing pagers for
new-table join ordering).

**The EditPage → PageEdit extraction (flagged item). [Documented]** `EditPage`
(~4000 lines; its own header reads *"Surgeon General's Warning: prolonged
exposure to this class is known to cause headaches, which may be fatal"*) is a
monolith mid-refactor. As of **1.47** the save/constraint/conflict engine moved
into a new `MediaWiki\PageEdit` namespace (`PageEdit::edit()`, value objects
`PageEditInputs`/`PageEditResult`/`PageEditStatus`), persistence now goes through
`PageUpdater::saveRevision()` rather than `WikiPage::doUserEditContent()`, and the
old `IEditConstraint`/`CONSTRAINT_PASSED` constants are gone (constraints now
return a `PageEditStatus`: OK = pass). Tracked as **`T157658`**. **Whether
`EditPage` itself becomes a service is an open, active migration — not settled
design.**

---

## Abandoned / superseded approaches (so they aren't retried)

Do not reintroduce these. New code that reaches for the left column will be
rejected in review.

| Don't use | Use instead | Status / version |
|---|---|---|
| `AuthPlugin` / single global `$wgAuth` | `AuthManager` provider pipeline (Pre → Primary → Secondary) | `AuthPlugin` deprecated 1.27, **dropped** `3f717984c13` 2019-02-11 |
| `wfGetDB()` | `IConnectionProvider` (@since 1.40) → `getReplicaDatabase()`/`getPrimaryDatabase()` | **fully removed from `includes/`** (zero refs) |
| Raw SQL strings / hand-built conditions | Query builders (`newSelectQueryBuilder()` etc.), `Expression`/`IExpression` objects | `SelectQueryBuilder` added `d06a3e049bc` 2020-01-16 |
| Old `Revision` class | `RevisionRecord` (+ `RevisionStore`) | since 1.31/1.32 |
| `User->isAllowed()` / direct `PermissionManager` in new code | `Authority` | Authority @since 1.36 |
| `User::newFrom*` statics | `UserFactory` | — |
| `User::getEditToken` | `CsrfTokenSet` | @since 1.37 |
| PHP `$_SESSION` | `Session` (SessionManager) | — |
| `Linker::link()` / static `Linker` | `LinkRenderer` | deprecated since 1.28 |
| `MediaWikiTitleCodec` | `TitleParser` + `TitleFormatter` | deprecated since 1.44 |
| `SkinTemplate` / `QuickTemplate` / raw `Skin` subclass | `SkinMustache` (.mustache + `SkinComponent` data providers) | `SkinMustache` since 1.35 |
| `image`/`oldimage` direct queries | `FileSelectQueryBuilder` (branches on migration stage) | mid-migration — treat old tables as a hazard |
| `ObjectCache.php` static facade | `ObjectCacheFactory` / injected named caches | deprecated ≥1.42 |
| naive `get()`/`set()`+`delete()` caching | `WANObjectCache::getWithSetCallback` (tombstone + hold-off) | fixes a lagged-backfill race in multi-DC |
| `extension.json` manifest_version 1 new features | manifest_version 2 | **v1 schema is frozen (md5-asserted); never gains features** |
| Oracle / MSSQL database support | MySQL/MariaDB, PostgreSQL, SQLite | dropped `4d10bb14e81` 2019-08-13 |

**Already-removed classes you may see referenced in stale docs/comments
([Documented as removed / Inference]):** `EnqueueJob` (replaced by
`JobQueueEnqueueUpdate`), `FileJournal` (not present in this checkout),
non-`Universal` `SkinTemplateNavigation` variants, the old DOM-based parser
preprocessor. The doc `docs/deferred.txt` is "largely historical" — trust the
`DeferredUpdates.php` class docblock instead.

---

## "Why it's done this way" — non-obvious local choices

Facts that look strange until you know the reason.

- **The leading `1.` in the version is vestigial. [Documented]** `MW_VERSION`
  is `1.47.0-alpha`; the `1.` has never been bumped to `2.` and there is no plan
  this repo can verify. Treat it as a constant prefix. The number that actually
  moves between feature releases is the **`47`** (each bump is effectively a
  semver major — breaking changes allowed, but only via the deprecation policy).
- **Indentation is tabs. [Documented]** `.editorconfig`: `indent_style = tab`,
  `tab_width = 4`. (YAML files are an exception — 2 spaces, "tabs may not be
  valid YAML.") Enforced by `mediawiki-codesniffer` via `.phpcs.xml`.
- **Generated files you must not hand-edit, and the test that catches you:**
  - `autoload.php` — regenerate with `generateLocalAutoload`;
    `AutoLoaderStructureTest` fails if stale.
  - `phpunit.xml` — generated from `phpunit.xml.template` by
    `composer phpunit:config`.
  - per-DB SQL (`sql/mysql|postgres|sqlite/*`) — generated from
    `sql/tables.json`; `AbstractSchemaTest` byte-matches.
  - config files (`MainConfigNames.php`, `includes/config-schema.php`,
    `docs/config-schema.yaml`) — generated from `MainConfigSchema`;
    `SettingsTest::testConfigGeneration` fails on drift.
- **Every commit has a `Change-Id`. [Documented/Inference]** Required by Gerrit
  (see decision #10); a commit-msg hook adds it. It is the stable identity of a
  change across rebases/patchsets — *not* a bug ID (that's the separate
  `Bug: T#####` footer).
- **`MainConfig` and `$GLOBALS['wg*']` are two views of the same data — by design.
  [Documented]** During the DI migration, `GlobalVarConfig` deliberately reads the
  legacy globals; this is a bridge, not a bug.
- **`HookRunner` is a ~140 KB hand-maintained god class implementing every core
  hook interface, marked `@internal`. [Documented]** It is the single
  most-connected node in the codebase (~1084 structural edges) — the quantitative
  signature of "MediaWiki is extended in-process." Core calls it; extensions must
  not.
- **Hook dispatch order is fixed and load-bearing. [Documented]** legacy
  `$wgHooks` handlers run first, then `extension.json` `Hooks`-attribute handlers,
  then runtime-registered ones — "so legacy handlers get the first chance to
  abort." Hook-name normalization (colons/dashes → underscores) is *inlined, not
  a shared helper* — deliberately, because hooks are a hot path.
- **Read permission is checked twice on the view path — on purpose. [Documented,
  `T34276`]** Early in `performRequest()` (resetting to `Special:Badtitle` to
  avoid leaking page existence via skins/`$wgTitle`) *and* again in
  `Article::view()` — a deliberate information-leak defense.
- **A bad edit token fails *soft*. [Documented]** It downgrades save → preview so
  the user doesn't lose work (with `$wgRawHtml`, it suppresses the preview to
  avoid an XSS vector). Anonymous users and GET forms skip the token by design.
- **`Message::__toString()` always parses (`FORMAT_PARSE`). [Documented,
  `T146416`]** A "safe by default" security fix so `"$msg"` interpolation is
  escaped.
- **Two message file formats. [Documented]** `*.json` holds *translatable*
  strings (synced from translatewiki.net — **editing `de.json` in a core patch is
  wrong; the bot overwrites it**); `MessagesXx.php` holds *structural/executable*
  language config (namespace names, magic-word regexes) that predates JSON. The
  `Message` class (first implemented 1.17) was built to replace the old `wfMsg*`
  functions that "grew unusable."
- **`$wg*` config variables *are* the feature-flag mechanism. [Documented]**
  There is no separate feature-flag framework. Temporary migration flags
  (e.g. `$wgThumbnailStepsRatio`, removed in 1.47) are introduced default-off,
  flipped, then deleted.
- **Deprecation is a two-step, multi-release process. [Documented]** *Soft*
  deprecate (`@deprecated since 1.NN` docblock, no runtime warning — "starts the
  clock"); later *hard* deprecate (call `wfDeprecated()` → runtime warning); then
  remove (entry moves to `=== Breaking changes ===`). Practical minimum is **one
  feature release** between hard-deprecation and removal, but symbols often linger
  far longer (e.g. `BaseSearchResultSet::next()` deprecated 1.32, removed 1.47).
  The exact required minimum is policy on mediawiki.org, not in-repo.
- **No in-repo CI/release config. [Documented]** CI runs on Wikimedia
  infrastructure (Quibble); the authoritative build/test/lint definitions are the
  `composer.json` / `package.json` scripts. Two release models coexist: the
  near-`master` **WMF train** (`-wmf.N` builds, weekly) and **cut releases /
  LTS** for third parties (`REL1_xx` branches, signed tarballs with `vendor/`
  vendored in). Upgrade floor: anything older than **1.39** fails.

---

## Reconstructed vs documented — open questions for the team

Genuine unknowns. The riskiest items below are the **classic-history framings
that the subsystem docs themselves flag as inference** — verify against
Phabricator before repeating them as fact.

1. **TempUser motivation.** The framing "temporary accounts were introduced to
   stop recording editor IPs as the public actor" is **[Inference, doc-flagged]**
   — strongly implied by the design (`UserIdentityUtils`, `TempUser/`,
   `~2024-1`-style names, AuthManager dissociating temp from new accounts) but
   *not confirmed against a Phabricator task.* The privacy *intent* is real;
   confirm the official motivation. *Who knows:* Trust & Safety / Anti-Harassment
   team; check the IP-Masking program on mediawiki.org.
2. **AuthManager-replaced-AuthPlugin framing.** The *fact* is documented (AuthPlugin
   was deprecated 1.27 and dropped 2019); the "single global auth backend → ordered
   multi-step pipeline" narrative is **[Inference]** per the auth deep-dive. Verify
   against the AuthManager RFC if citing the rationale. *Who knows:* the original
   AuthManager RFC on Phabricator.
3. **Abstract-schema "replaced hand-maintained per-DB SQL."** Plausible and
   consistent, but **no in-repo doc narrates the prior state or cites the
   introducing task/version.** *Who knows:* the DBA / Data Persistence team;
   check `maintenance/AGENTS.md` and the `generateSchemaSql` task history.
4. **Gerrit-over-GitHub rationale.** The *fact* is unambiguous (`.gitreview`); the
   *why* (#10) is **[Inference]** — no in-repo document states why Gerrit was
   chosen. *Who knows:* Wikimedia Release Engineering; mediawiki.org Gerrit docs.
5. **Title-decomposition end-state timing.** The thesis is documented verbatim in
   `PageIdentity` docblocks, but there is **no dated roadmap or committed
   completion** — treat "remove Title" as direction, not deadline. Not verified
   against a Phabricator epic.
6. **Parsoid default-engine timeline.** Which page views default to Parsoid is a
   *deployment/config* decision (`ParsoidCacheConfig` etc.), not in this tree.
   When the legacy `Parser` is retired, if ever, is unknown here. *Who knows:* the
   Content Transform / Parsing team (`T236809`).
7. **REST vs Action API long-term.** Both are documented as first-class, but
   *whether specific Action modules are slated to move to REST* (beyond the
   `ActionModuleBasedHandler` bridge) is not captured in-repo. Whether
   `psr/http-message` will eventually back REST's bespoke PSR-7-shaped interfaces
   is also open.
8. **LTS cadence and exact deprecation minimum.** Which releases are LTS, the
   support-window lengths, and the formal soft→hard→removal timeline live on
   mediawiki.org (*Stable interface policy*), not in this repo. The repo only
   *demonstrates* a "≥1 feature release" norm by example.

---

## Foundation (links)

This chapter builds on (does not repeat) the following — go there for mechanics:

**Intentional rationale documents (read these first):**
- `docs/Injection.md` — the authoritative *why* of dependency injection (RFC
  `T384`), principles, and migration recipes (decision #1).
- `docs/Events.md` — the authoritative *why* of the Domain Event system
  (decision #5).

**Sibling handbook chapters:**
- `docs/handbook/02-architecture.md` — the shared-nothing monolith, the two hubs
  (service container + HookRunner), entry points, in-process extension model.
- `docs/handbook/04-data-model.md` — MCR tables, actor/comment/linktarget
  normalization, the `SCHEMA_COMPAT_*` staged-migration framework, abstract
  schema mechanics.
- `docs/handbook/07-release-and-compatibility.md` — versioning, the vestigial
  `1.`, `@stable`/`@deprecated` taxonomy, deprecation policy, WMF train vs cut
  releases, upgrade floor.
- `docs/handbook/11-code-ownership-and-review.md` — Gerrit/Change-Id workflow and
  review norms (decision #10).

**Subsystem deep-dives harvested for this chapter** (each has its own
Invariants/gotchas + open_questions):
- `subsystems/storage-revisions-content.md` (MCR, RevisionStore, PageUpdater)
- `subsystems/auth-permissions-sessions.md` (Authority, AuthManager, TempUser)
- `subsystems/title-linking-namespaces.md` (Title decomposition)
- `subsystems/rest-api.md` and `subsystems/action-api.md` (the two APIs)
- `subsystems/parser-and-content-transform.md` (Parsoid)
- `subsystems/service-container-and-config.md` (DI, ServiceWiring, config)
- `subsystems/hooks-and-extension-registration.md` (hooks vs events, registration)
- `subsystems/database-rdbms.md` (query builders, ChronologyProtector, DBAL)
- `subsystems/files-media-uploads.md` (file-tables migration)
- `subsystems/output-skins-resourceloader.md` (SkinMustache, ResourceLoader)
- `subsystems/caching-deferred-jobs.md` (WANObjectCache, deferred updates)
- `subsystems/actions-special-pages-editing.md` (EditPage → PageEdit)
- `subsystems/localisation.md` (Message system, LCStore, PHP→JSON)

**External (out of repo) — the real decision records:**
- Phabricator (`phabricator.wikimedia.org`) — RFC / TDM process; the `T#####`
  IDs cited throughout this chapter.
- mediawiki.org — *Manual:Stable interface policy*, *Manual:Domain events*,
  IP-Masking / temporary accounts program, Gerrit tutorial.
