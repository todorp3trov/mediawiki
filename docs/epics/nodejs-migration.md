# Epic: Reimplement MediaWiki core as a TypeScript/Node engine (greenfield, data-compatible)

> **Outcome:** A TypeScript/Node engine serves what `index.php` / `api.php` /
> `rest.php` serve today — running against the *existing* MediaWiki database
> schema — and the PHP core is retired, leaving the stack on one language (JS/TS)
> plus a single PHP **Parsoid** sidecar for wikitext.
>
> **Feasibility:** Feasible as a **multi-year greenfield reimplementation pursued
> incrementally (strangler)**, *not* as a translation of the PHP. Rests on the
> language-agnostic abstract schema (the enabler) and on reusing PHP Parsoid as a
> sidecar (removes the hardest workstream from the critical path). · **Confidence:
> medium** — the live uncertainties are write-path data-compat correctness, the
> Parsoid-over-network contract, and the multi-year runway, not the architecture.

---

## Motivation

The stack is split across two languages: the back-end engine is ~1.28M lines of
PHP (672K in `includes/` alone), while the front end (`resources/`) is **already**
JavaScript (Vue/Codex + ~640 JS files). The goal is to **unify on one language
(JS/TS)** across the whole stack — simpler hiring, one mental model, and the
option to share validation/i18n logic between client and server.

Two scoping decisions, made up front with the requester, define this Epic and are
load-bearing for everything below:

- **Greenfield — the PHP extension/skin ecosystem is out of scope.** This is *not*
  a compatible migration of MediaWiki; it is a **new wiki engine, forked
  permanently** from the PHP ecosystem. There will be no VisualEditor, Wikibase,
  CirrusSearch, or any in-process PHP extension/skin. (See *Risks* for the
  standing cost this implies.)
- **Full replacement, reached incrementally.** The end-state retires PHP core; the
  *path* there is a strangler, not a big-bang rewrite, made possible by data
  compatibility.

This Epic is a **feasibility-and-direction** document. It is deliberately
high-level; the per-subsystem decomposition is the job of the downstream breakdown
stage (see *Handoff*).

## Feasibility summary

**Verdict: feasible as a long-horizon, incremental greenfield rebuild — with three
caveats that the team must accept going in.**

What makes it feasible (confirmed against the repo):

- **The schema is language-agnostic and generated.** `sql/tables.json` is the
  abstract source of truth; per-DB SQL is *generated* from it (`AbstractSchemaTest`
  byte-matches it). A TS engine can target the **identical** MySQL/Postgres/SQLite
  schema, so the PHP and TS engines can run against the **same database**. This is
  the single fact that turns "full replacement" from a big-bang rewrite into an
  incremental strangler (read paths first → writes → retire PHP). See
  [`docs/handbook/04-data-model.md`](../handbook/04-data-model.md).
- **The hardest subsystem can be reused, not rebuilt.** Wikitext parsing is the
  long pole (`Parser.php` is ~217KB, stateful, dual-engine, with a ~540KB shared
  test contract). The decision to run the existing **PHP Parsoid as a sidecar
  service** removes that rewrite from the critical path and preserves true
  MediaWiki-wikitext compatibility. See
  [`docs/handbook/subsystems/parser-and-content-transform.md`](../handbook/subsystems/parser-and-content-transform.md).
- **The API contracts are documented.** REST (`rest.php`) is the clean re-impl
  target (DI-clean, JSON-native, OpenAPI'd); the Action API's default output shape
  is a well-specified (if unbreakable) contract.
  See [`docs/handbook/05-public-api-and-extensions.md`](../handbook/05-public-api-and-extensions.md).

The three caveats the verdict rests on:

1. **It is multi-year for a team, and scope scales with staffing.** Even
   greenfield (dropping extensions, deprecated paths, exotic DB support), the
   *useful* core — storage/MCR, revisions, the two APIs, output/skinning, auth,
   i18n, media, search, jobs, maintenance — is hundreds of thousands of lines of
   genuine functionality. A small team produces a "useful subset wiki engine," not
   feature-parity MediaWiki. **This is the dominant risk and it is non-technical.**
2. **Write-path data-compatibility is the correctness cliff.** Sharing a live DB
   with (or inheriting a DB from) MediaWiki means the TS write path must replicate
   subtle invariants *exactly* — CAS on `page_latest`, content-address
   immutability, inherited slots (`slot_origin`), `NameTableStore`
   transaction-volatility, actor/comment dedup. Get these wrong and you corrupt a
   shared database. Reads are far safer than writes here.
3. **"One language" is ~95%, not 100%, and the front end was already JS.** The
   Parsoid sidecar keeps one PHP component (revisitable later). And because
   `resources/` is already JavaScript, the unification win is essentially the
   *backend* — to be weighed against a **permanent upstream-fork tax** (every
   future MediaWiki security fix and feature becomes yours to re-implement).

## How it fits the system

The TS engine must re-stand-up the shape documented in
[`docs/handbook/02-architecture.md`](../handbook/02-architecture.md), but is free
to modernize the runtime model:

- **Entry points.** Replace the seven thin web entry scripts + CLI runner
  (`index.php`, `api.php`, `rest.php`, `load.php`, `thumb.php`, `img_auth.php`,
  `opensearch_desc.php`, `maintenance/run.php`) with TS handlers.
- **The two hubs.** `MediaWikiServices` (DI) → a TS DI container; `HookContainer`/
  `HookRunner` (in-process extension) → can be *much* simpler or dropped, since
  extensions are out of scope. This is where greenfield buys the most simplicity.
- **Backing services.** Rdbms (DB cluster), `BagOStuff`/`WANObjectCache`, and the
  JobQueue are backed by language-agnostic infrastructure (MySQL, memcached,
  Redis/Kafka), but their *client logic* (connection provider + replica/primary
  split + `ChronologyProtector`; the WAN cache tombstone/hold-off semantics) is
  sophisticated and must be re-implemented in TS.
- **Runtime-model shift (a real re-architecture, not a port).** MediaWiki is
  *shared-nothing, boot-per-request*; Node is a resident event loop. Core's
  PRESEND/POSTSEND deferred updates, `ChronologyProtector`, and opcache-as-boot-
  mitigation are all shaped by the PHP model. The TS engine gets to rethink this
  (likely a net win — no per-request boot cost), but must redesign request
  isolation and the deferred-work model accordingly.

**Impact map (where it lands):**

- **Data model & schema** — *reuse* the abstract schema as the contract; generate
  TS types/migrations from `sql/tables.json`. (handbook ch. 04)
- **Public API / backward-compat** — match REST and Action-API *output contracts*
  so the existing `resources/` front end and external clients keep working;
  internal PHP `@stable` interfaces are irrelevant (no extensions). (handbook ch. 05)
- **Security boundaries** — re-establish the `Sanitizer`/CSP/`ParamValidator`/CSRF
  guarantees in TS; Parsoid's own sanitization comes with the sidecar. (handbook ch. 08)
- **Performance / hot paths** — re-earn the caching/CDN/replica-lag model that
  makes MediaWiki scale; the parse is the expensive op and now crosses a network
  boundary to the sidecar. (handbook ch. 09)

## Proposed direction

**Incremental strangler toward full replacement, anchored on data compatibility,
with PHP Parsoid as a sidecar.**

1. **Foundation + data layer.** TS service skeleton (entry points, config, DI,
   logging, observability) + a data-access layer generated from `sql/tables.json`;
   get *read* access to a real MediaWiki DB working. Decide the resident-process
   runtime model and request isolation.
2. **Read-path vertical slice.** Title → revision (MCR read) → render via the
   Parsoid sidecar → output-transform → skin, for a *constrained* content set,
   served behind the same URL/REST contract and A/B'd against PHP. Proves the
   architecture end-to-end and forces the sidecar contract to be real.
3. **API surface.** REST first, then Action API read modules (match output shape),
   so the existing front end and clients can run on the TS backend.
4. **Write path.** The correctness-critical edit pipeline (MCR write, CAS on
   `page_latest`, links/derived-data updates, deferred work), dual-writing against
   the shared DB for safety.
5. **Auxiliary breadth.** Auth/permissions, i18n (the message JSON is *reusable*),
   media/files, search, job workers, special pages, maintenance scripts.
6. **Cutover & retire PHP.** Progressive per-surface cutover validated by reused
   parser-test fixtures + API contract tests; retire PHP, leaving the Parsoid
   sidecar.

**Alternatives considered and why they lost:**

- **Big-bang full rewrite** — rejected: on a system this size it is the classic
  second-system death march with no running product in between. Data compatibility
  makes the safer strangler available, so take it.
- **Rewrite the parser in TS** — rejected *for now*: highest-risk, multi-year
  single workstream; the sidecar gets a working, wikitext-compatible wiki far
  sooner. Can be revisited once the rest of the engine exists.
- **Constrain the wikitext dialect** — rejected: fastest and fully-TS, but it
  changes the product (no longer MediaWiki-compatible wikitext).
- **Clean-room new schema** — rejected: forfeits the run-both-engines-on-one-DB
  property that makes incremental replacement safe.

## Scope

**In scope:**
- A TS/Node engine for the core read + write paths, REST + Action APIs, output/
  skinning, auth/permissions, i18n, media, search, jobs, and the maintenance CLI
  needed to operate.
- Data compatibility with the existing abstract schema (same DB, both engines).
- A PHP Parsoid sidecar and the network DataAccess contract it needs.
- Reuse of the existing `resources/` front end against contract-compatible APIs
  (subject to the coupling audit — see *Handoff*).

**Out of scope / non-goals:**
- The entire in-process **PHP extension and skin ecosystem** (VisualEditor,
  Wikibase, CirrusSearch, all skins) — *accepted loss*.
- Landing anything upstream (Gerrit/TDM); this is a fork, not a contribution to
  `mediawiki/core`.
- Reproducing deprecated/legacy code paths, the `wf*()` globals, or DB engines
  beyond what the target deployment needs.
- A TS wikitext parser (deferred; sidecar instead).
- 100%-single-language purity (one PHP sidecar remains).

## Workstreams (coarse)

> Coarse on purpose — these convey size and sequence and feed the breakdown stage.
> They are **not** child stories.

1. **Runtime foundation, DI & entry points.** TS service skeleton; the entry-point
   handlers; config system; logging/observability; DI container; the resident-
   process runtime model + request isolation. *(handbook ch. 02; service-container
   & hooks subsystem docs.)*
2. **Data-access layer on the shared schema.** TS DBAL generated from
   `sql/tables.json`; connection provider + replica/primary split + a
   `ChronologyProtector`-equivalent; the MCR **read** model
   (page→revision→slots→content→text, actor/comment, `NameTableStore`).
   *(handbook ch. 04; storage-revisions-content, database-rdbms.)*
3. **Read path + Parsoid sidecar.** The canonical view path end-to-end through the
   sidecar; a `ParserCache`-equivalent; the OutputTransform-equivalent + server-
   side skinning; the sidecar service contract & deployment. **The proving vertical
   slice.** *(parser, output-skins-resourceloader, title-linking subsystem docs.)*
4. **API surfaces.** REST API (re-impl against the documented contract), then
   Action API read modules (match the unbreakable default output shape); enable
   `resources/` + external clients on the TS backend. *(rest-api, action-api;
   handbook ch. 05.)*
5. **Write path & derived data.** MCR write via a `PageUpdater`-equivalent; CAS on
   `page_latest`; parser-cache invalidation; links/categories/`page_props` derived
   updates; deferred updates + job queue — with dual-engine safety on the shared
   DB. **Correctness-critical.** *(storage-revisions-content, caching-deferred-jobs;
   handbook ch. 04.)*
6. **Identity, i18n, media, search, maintenance (breadth).** Authority-equivalent
   permissions + sessions; localisation (reuse message JSON + an LCStore-
   equivalent); FileBackend/media/thumbs; search; job workers; special pages; the
   operational maintenance scripts. *(auth, localisation, files subsystem docs;
   `maintenance/AGENTS.md`.)*
7. **Cutover, dual-run & PHP retirement.** Both engines on one DB; traffic
   shadowing / A-B; parity validation (reuse parser-test fixtures + API contract
   tests); progressive per-surface cutover; retire PHP. *(handbook ch. 06 testing,
   ch. 07 release/compat.)*

## Sequencing & dependencies

- **WS1 + WS2 are the foundation** (can proceed in parallel internally). Everything
  depends on them.
- **WS3 depends on WS1 + WS2** and is the de-risking proof. **Stand up the Parsoid
  sidecar as the first spike** — the network DataAccess contract is the biggest
  unproven piece and gates the read path.
- **WS4 (REST read) can start once WS3's read path exists.**
- **WS5 (writes) is gated on WS2 + WS3** and is the hardest correctness work; it
  needs the deferred-update/job model from WS1 decided.
- **WS6 is broad and largely parallel** once foundations land — i18n and auth can
  start early; media/search later.
- **WS7 is a discipline that runs continuously** (dual-run from WS3 onward) and
  concludes the Epic with PHP retirement.

**Out-of-repo / external dependencies:** a deployable PHP Parsoid service; a real
MediaWiki database to validate data-compat against; the runtime/hosting choice for
a resident Node process; the front-end reuse decision for `resources/`.

## Risks, unknowns & open questions

> The highest-value section. Kept honest by separating what is **confirmed from
> code/docs**, **assumed from docs**, and **genuinely unknown**.

**Confirmed (from code / handbook):**

- **The upstream-fork tax is permanent and large.** Dropping the in-process PHP
  ecosystem is inherent to the chosen direction: no extensions/skins, and every
  future MediaWiki security fix or feature must be re-implemented by hand, forever.
  (handbook ch. 02 "Core vs extensions", ch. 10.)
- **Wikitext parsing is the long pole** — mitigated by the sidecar, but the sidecar
  *adds* a network boundary, latency on the parse hot path, and one residual PHP
  component. (parser subsystem.)
- **Action API output shape is an unbreakable contract** — the TS re-impl must
  match it for existing clients. (handbook ch. 05; decision history.)
- **Runtime-model mismatch** (boot-per-request → resident process) forces a
  redesign of deferred updates, chronology protection, and request isolation —
  re-architecture, not translation. (handbook ch. 02, ch. 09.)
- **"One language" is backend-only** — `resources/` is already JS. (handbook ch. 02.)

**Assumed (from docs — and which):**

- **Same schema ⇒ true data compatibility** (handbook ch. 04). Very likely for
  *reads*; the *write* path must match subtle invariants exactly or corrupt a
  shared DB — **must be hard-verified in breakdown.**
- **Parsoid runs cleanly as a sidecar** (parser subsystem: the core↔Parsoid seam is
  a defined adapter — `PageConfig`/`SiteConfig`/`DataAccess` in
  `includes/parser/Parsoid/Config/`). But those adapters currently let Parsoid read
  *this* wiki via in-process PHP; a TS engine must serve an equivalent **DataAccess
  over the network**, which is unproven and may strain Parsoid's synchronous data
  expectations.
- **`resources/` can be largely reused** against contract-compatible APIs
  (handbook ch. 02, output-skins). Assumed, not verified — and skins are PHP
  (`SkinMustache`), so server-side skinning/output assembly is a *rewrite* even
  though client JS is reusable.

**Unknown — needs investigation:**

- **Team size / multi-year runway** — the dominant non-technical risk; determines
  whether the result is feature-parity or a useful subset.
- **Exact deferred-update / `ChronologyProtector` semantics** needed for write
  correctness on a shared DB (caching-deferred-jobs not yet read in depth).
- **i18n / LocalisationCache resolution details** (the handbook flags some of these
  as inferred).
- **The Parsoid-sidecar DataAccess-over-network contract** — latency, batching, and
  whether a network boundary is acceptable on the parse path.
- **Performance/scale parity** — MediaWiki's CDN/cache/replica model is load-bearing
  at scale and must be re-earned by the TS engine.

## Handoff to breakdown

The downstream child-story chat should do the deeper **code verification** this
stage deliberately did not, starting with the highest-risk areas:

1. **Write-path data-compat invariants (highest correctness risk).** Read
   `subsystems/storage-revisions-content.md` + `subsystems/caching-deferred-jobs.md`
   + `sql/tables.json`, and pin down the exact write semantics the TS engine must
   replicate to safely share a DB: CAS on `page_latest`, `slot_origin`/inherited
   slots, content-address immutability, `NameTableStore` transaction-volatility,
   actor/comment dedup, derived-data update ordering.
2. **Parsoid sidecar contract (biggest unproven piece).** Read
   `includes/parser/Parsoid/` (`ParsoidParser`, and `Config/` —
   `SiteConfig`/`PageConfig`/`DataAccess`) to define the DataAccess-over-network
   contract; **de-risk with an early spike** before committing the read path.
3. **Runtime model.** Decide resident-process architecture, request isolation, and
   the deferred-work/job model — this gates WS1.
4. **First vertical-slice scope.** Choose the constrained content set for the
   read-path proof (e.g. simple anonymous article views, one skin) and define
   parity tests by **reusing the parser-test fixtures** (handbook ch. 06) + API
   contract tests.
5. **Front-end reuse assessment.** Audit `resources/` coupling to PHP-rendered
   output and server-side skinning to size the skin/output rewrite.

**Docs to start from:** handbook ch. 02 (architecture), 04 (data model), 05 (APIs),
06 (testing/parser fixtures), 07 (release/cutover), 08 (security), 09 (performance);
subsystem docs for storage, parser, caching-deferred-jobs, rest-api, action-api,
auth, localisation, files. The Graphify graph (`graphify-out/GRAPH_REPORT.md`) is
useful for sizing god-node blast radius (`ParserOutput`, `Title`, `HookRunner`).

---

*Stage 1 (feasibility + direction) of a two-stage plan. This Epic establishes that
the work is sound and points it in a direction; the child-story breakdown is a
separate downstream step. Confirmed/assumed/unknown are kept distinct on purpose —
do not let an assumption (especially write-path data-compat) be planned around as a
fact until breakdown verifies it against the code.*
