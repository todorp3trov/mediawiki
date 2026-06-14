# MediaWiki Core — Engineering Handbook

MediaWiki core is the free, GPL-licensed PHP engine that powers Wikipedia, every
other Wikimedia project, and thousands of third-party wikis. It is a
**shared-nothing, boot-per-request modular monolith**: each request boots the
environment, is served, and tears down, scaling horizontally behind a CDN and a
replicated database + cache + job-queue cluster, and extended *in-process* through
a service container and a hook system rather than network services.

This handbook is the **senior-onboarding path**: it goes beyond the operational
`AGENTS.md` map into *how the system really works and why it is shaped this way* —
request lifecycles, the data model and how it evolves safely, the security and
performance constraints that bite in production, and the reasoning behind the big
decisions. For the quick operational reference (module layout, build/test/lint
commands, conventions, gotchas) start at the root [`AGENTS.md`](../../AGENTS.md)
and the per-module ones under `includes/`, `tests/`, `maintenance/`, `resources/`.

> **Where this repo sits.** Code review is on **Gerrit** (`gerrit.wikimedia.org`),
> not GitHub; tasks are on **Phabricator** (`T12345`). Much of the *policy* this
> handbook points at — the Stable interface / deprecation policy, the LTS
> schedule, team ownership, production SLOs and topology — lives on
> **mediawiki.org** and Wikimedia operations infrastructure, **not in this
> checkout**. Where that is the case, the documents say so rather than guess.

## Read in this order

1. [Local Development & Workflow](01-local-development.md) — fresh clone to a productive inner loop: Docker Compose vs bare `composer serve` + SQLite, the PHP and front-end edit loops, running a single test, debugging, and the newcomer gotchas.
2. [Architecture](02-architecture.md) — the big picture: the boot-per-request monolith, the entry points, the service-container + hook hubs, and an end-to-end trace of a logged-out page view.
3. [Subsystem Deep Dives](03-subsystem-deep-dives.md) — index into the 14 per-subsystem references (start here for "I need to own a change in X").
4. [Data Model & Schema Evolution](04-data-model.md) — the `page → revision → slots → content → text` (MCR) chain plus actor/comment/user normalization, and the abstract-schema → generated-SQL migration workflow with its `SCHEMA_COMPAT` staged-migration pattern.
5. [Public API & Extension Contracts](05-public-api-and-extensions.md) — what's public vs internal and how it's *signaled* (`@stable`/`@internal`/`@unstable` docblocks), the two HTTP APIs, hooks + the full `extension.json` attribute system, domain events, and the `wikimedia/*` libraries.
6. [Testing Strategy](06-testing-strategy.md) — the pyramid (unit / integration / **structure** / parser / Jest / QUnit / Selenium / api-testing), the unit-vs-integration base-class split that enforces DI, the strict-config traps, and the bar a patch must clear.
7. [Release, Upgrade & Backward Compatibility](07-release-and-compatibility.md) — the `1.MAJOR.MINOR` scheme (the "1." is vestigial), the two release models (WMF weekly train vs cut/LTS releases), the deprecation discipline, and the operator upgrade path.
8. [Security Model](08-security-model.md) — *defensive*: the trust boundaries and the layered guardrails (`Sanitizer` for XSS, query builders for SQLi, `ParamValidator` for input, CSRF tokens, `Html`/CSP), secrets, sensitive-data handling, and the rules a dev must never break.
9. [Performance & Production Constraints](09-performance-and-production.md) — where the time goes (the parse is the expensive op; ParserCache + CDN are why), the resource limits, the scaling model (replicas + ChronologyProtector), and the traps that turn a correct-looking patch into an outage.
10. [Decision History](10-decision-history.md) — *why* the system is shaped the way it is: globals→DI, MCR, Authority, REST-alongside-Action-API, domain events, Parsoid, the Title decomposition — each tagged documented vs reconstructed.
11. [Code Ownership & Review Norms](11-code-ownership-and-review.md) — the social process of merging a change: de-facto ownership from history, the Gerrit `+2`/Verified review flow, the commit/Change-Id conventions, the gate pipeline, and the idioms reviewers enforce beyond the linter.

## Subsystems

Grouped by role. Each links to its deep dive; all build on
[`includes/AGENTS.md`](../../includes/AGENTS.md) (front-end also on
[`resources/AGENTS.md`](../../resources/AGENTS.md)). The full table with
per-subsystem one-liners is in
[03-subsystem-deep-dives.md](03-subsystem-deep-dives.md).

**Platform / cross-cutting** (the foundations — read first):
[Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md) ·
[Service Container & Configuration](subsystems/service-container-and-config.md) ·
[Database (Rdbms)](subsystems/database-rdbms.md) ·
[Caching, Deferred Updates & Job Queue](subsystems/caching-deferred-jobs.md) ·
[Localisation (i18n/L10n)](subsystems/localisation.md)

**Content & identity:**
[Storage, Revisions & Content](subsystems/storage-revisions-content.md) ·
[Title, Linking & Namespaces](subsystems/title-linking-namespaces.md) ·
[Authentication, Permissions & Sessions](subsystems/auth-permissions-sessions.md) ·
[Files, Media & Uploads](subsystems/files-media-uploads.md)

**Presentation & request handling:**
[Parser & Content Transformation](subsystems/parser-and-content-transform.md) ·
[Output, Skins & ResourceLoader](subsystems/output-skins-resourceloader.md) ·
[Actions, Special Pages & Editing](subsystems/actions-special-pages-editing.md) ·
[Action API](subsystems/action-api.md) ·
[REST API](subsystems/rest-api.md)

## Not covered (and why)

All eleven handbook topics apply to MediaWiki core and are present — nothing was
omitted. A few deliberate boundaries:

- **Topic 3 is an index**, not a single document — the subsystem deep dives fan
  out into [`subsystems/`](subsystems/) (there is no `03-…` body file by design).
- **Extensions and skins are out of scope.** This repo is the *engine*; the
  in-repo `extensions/` and `skins/` are empty placeholders. The handbook covers
  the *contracts* extensions depend on (topic 5), not any specific extension.
- **Parsoid internals** are documented only at the seam — Parsoid ships as the
  separate `wikimedia/parsoid` Composer package; see the
  [Parser](subsystems/parser-and-content-transform.md) deep dive for the boundary.

## Open questions / tribal knowledge to confirm

This is the highest-value output of the exercise: the precise list of things the
repository **cannot teach**, gathered from every document so the team can fill
them once instead of every newcomer rediscovering them. They fall into four
buckets.

### A. Policy & infrastructure that lives off-repo (mediawiki.org / Wikimedia ops)

These are *correctly* external — the gap is that a newcomer won't know to go look.

- **The Stable interface / deprecation policy** — the formal deprecation minimum
  (the repo proves a "≥1 release" norm only by example), the soft→hard sequencing,
  and the meaning of each `@stable` variant. *On mediawiki.org.* (docs 05, 07)
- **LTS cadence and designations** — `UPGRADE` references "two LTS releases" and a
  1.39 floor, but which releases are LTS and their support windows are policy, not
  in-tree. (doc 07) *Who knows: Release Engineering / mediawiki.org.*
- **Production topology** — CDN/LB/app-server/replica counts, the multi-DC layout,
  the mcrouter/dynomite cache-purge broadcast topology, and the exact
  `UseDC=master` cookie ↔ CDN-edge contract. (docs 02, 09; caching & database deep
  dives) *Who knows: WMF SRE / Traffic.*
- **SLO targets, dashboards and alerts** — core ships the instrumentation
  (`Profiler`, `StatsFactory`, PSR-3 logging) but the actual SLOs, Grafana
  dashboards, Logstash queries and thresholds are in ops infra. Statsd-family
  emitters are in-repo; Prometheus scraping is downstream. (doc 09)
- **Release mechanics** — tarball GPG signing/verification and the weekly-train
  cutting/rollback/deploy tooling. (doc 07) *Who knows: Release Engineering.*
- **WMF online schema-change runbook** — how `ALTER`s are applied out-of-band at
  scale (the in-repo `update.php` path collapses the staged migration that WMF
  walks across deploys). (doc 04; database deep dive) *Who knows: Data Persistence.*
- **Gerrit governance** — the `+2` rights per area (Gerrit ACLs/groups, not in
  repo; the "owners" this handbook names are *committers from history*, not the
  authorized approver list), the server-side submit strategy, and the precise
  self-merge rule. (doc 11)
- **WMF team → area ownership map** and the **external dependency/CVE scanning**
  scope (libraryupgrader) — social/operational, shifts with reorgs. (docs 08, 11)
- **The `includes/libs/` → `wikimedia/*` publishing mechanism** — the libs are
  authored here and published outward, but the pipeline is off-repo. (doc 05)

### B. In-flight migrations whose end-state is genuinely unsettled

This is the live tribal knowledge most worth capturing — a newcomer will hit dual
code paths and needs to know which way the wind blows.

- **Title god-object decomposition** into `LinkTarget`/`PageReference`/
  `PageIdentity` value objects — direction is clear and stated in interface
  docblocks, but there is **no dated roadmap or epic** for finishing it or removing
  `Title`. (title deep dive; doc 10)
- **Parsoid as the default parser** — the strategic direction (T236809), but *which
  page views* default to Parsoid is a per-wiki config decision and the timeline to
  retire the legacy PHP `Parser` is not determinable from source. (parser deep
  dive; doc 10)
- **File-tables migration** (`image`/`oldimage`/`filearchive` →
  `file`/`filerevision`/`filetypes`, `$wgFileSchemaMigrationStage`) — default is
  still `SCHEMA_COMPAT_OLD`; when `READ_NEW`/`WRITE_NEW` become default and the old
  tables are dropped is undetermined. (files deep dive; doc 04)
- **`EditPage` → `MediaWiki\PageEdit` extraction** (T157658, @1.47) — the
  save/constraint/conflict engine is being pulled out of `EditPage`; an active
  migration, end-state not settled. (actions-editing deep dive; doc 10)
- **Domain Events vs hooks** (since 1.44) — listener options/priority are
  `@unstable` and the `AfterCommit` method suffix is a documented temporary
  backward-compat shim; the eventual stable shape isn't fixed. (hooks deep dive)
- **REST API maturity** — audience-designation modes are stubbed (everything maps
  to `DISCOVERABLE` with "will become PUBLISHED" TODOs); the `Router`/`Module`
  coupling is slated for removal (T411521); RESTBase-compat shims have unclear
  lifetimes. (rest-api deep dive)
- **`TempUser`** (temporary accounts) — clearly a recent, strategically important
  addition, but its official motivation (the IP-masking / anti-harassment program)
  is inferred from the design, **not** confirmed against a Phabricator task here.
  (auth deep dive; doc 10) *Who knows: Trust & Safety / Anti-Harassment.*
- **`ContentHolder`** (1.45) in the parser is `@internal`/`@unstable` and
  mid-evolution. (parser deep dive)

### C. Stock-install vs production "works locally, melts in prod" traps

- **Performance protections are no-ops by default.** `$wgMainCacheType =
  CACHE_NONE`, `$wgUseCdn = false`, and `PoolCounterNull` mean a stock install has
  almost none of the caching/stampede protections the performance story assumes.
  (doc 09)
- **Upload security checks are individually disableable** by config
  (`$wgDisableUploadScriptChecks`, `$wgVerifyMimeType`, …) — defense-in-depth by
  design, but a wiki that has turned them off is materially weaker. Confirm
  production defaults rather than assuming. (doc 08)
- **No committed `composer.lock`** — PHP dependency pinning is not enforced in
  this repo; the pinned set is whatever Wikimedia CI resolves. (doc 08)

### D. Inferences to confirm against code that isn't in this checkout

- **`Wikimedia\Services\ServiceContainer`** (the generic DI engine
  `MediaWikiServices` extends) is a vendor-only package and is **absent from this
  checkout** (no `vendor/`); its internals were inferred from usage + `docs/Injection.md`.
  (service-container deep dive)
- **`FileJournal`** (append-only backend op log) is referenced in the file-backend
  design notes but **no class exists** under `includes/libs/filebackend/` here —
  removed or relocated, unverified. (files deep dive; doc 04)
- **A few localisation defaults** — `$wgMaxMsgCacheEntrySize` and whether
  `LCStoreStaticArray` is the resolved default store in 1.47 — were read at the API
  level, not traced end-to-end. (localisation deep dive)
- **The JWT session-cookie path** (`$wgJwtPrivateKey`, `JwtSessionCookieHelper`,
  1.45-era) was not traced in depth; any concern about its key handling should be
  routed to the **private security channel**, not detailed in this handbook. (auth
  & security docs)

---

*This handbook was generated by surveying the repository, its `AGENTS.md`
foundation, and a structural knowledge graph (`graphify-out/`). No PHP/Node
toolchain was present in the checkout, so all build/test/maintenance commands are
transcribed from `composer.json` / `package.json` / `DEVELOPERS.md` and marked as
**documented, not executed here**; read-only `git` was used to date and source
decisions. Claims the repo could not substantiate are labeled as inference and
collected above.*
