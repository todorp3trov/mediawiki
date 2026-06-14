# Performance & Production Constraints

> Part of the MediaWiki core senior-onboarding handbook (MW 1.47.0-alpha, PHP ≥ 8.3).
> This document is the **performance map**: where the time goes, what the hard
> limits are, and the codebase-specific traps that turn a correct-looking patch
> into an outage. It is deliberately thin on *mechanism* — the machinery lives in
> the subsystem deep-dives and is linked, not duplicated:
>
> - **The authority for caching, deferred work, jobs, and stampede protection is
>   [`subsystems/caching-deferred-jobs.md`](subsystems/caching-deferred-jobs.md).**
>   When this page says "WANCache does X" or "the job queue does Y", that page is
>   the source of truth; read it.
> - DB replication, transaction rounds, `ChronologyProtector`, replica lag:
>   [`subsystems/database-rdbms.md`](subsystems/database-rdbms.md).
> - Why the parse is the expensive op, ParserCache fragmentation, parser limits:
>   [`subsystems/parser-and-content-transform.md`](subsystems/parser-and-content-transform.md).
> - N+1 avoidance via `LinkBatch`/`LinkCache`:
>   [`subsystems/title-linking-namespaces.md`](subsystems/title-linking-namespaces.md).
> - ResourceLoader bundle size and the version-hash cache model:
>   [`subsystems/output-skins-resourceloader.md`](subsystems/output-skins-resourceloader.md).
>
> Foundation (not repeated): root `AGENTS.md`, `includes/AGENTS.md`,
> `docs/memcached.md`, `docs/deferred.txt`, `docs/database.md`.
>
> **The one-sentence model:** the same code must be fast enough for a single
> shared host *and* survive Wikipedia, so almost every performance feature is a
> cache or a deferral, and almost every limit is a guard against one pathological
> page or user melting the cluster. The framing question for any change is *"what
> happens when this runs a billion times a day, or on a page with a million
> backlinks?"*
>
> **Environment note:** no PHP/Composer/Node toolchain in this checkout. The
> benchmark scripts (`maintenance/benchmarks/`) and all `composer`/`npm` commands
> below are **documented, not run here.**

---

## Hot paths & known bottlenecks

### The dominant path: the logged-out page view

The single most-served request on a large wiki is an **anonymous (logged-out)
read of an article**, and the entire architecture is bent around making it never
touch PHP at all:

1. **CDN hit (cheapest).** Logged-out views are emitted with `s-maxage` so the
   CDN serves them without reaching an app server at all (`$wgUseCdn` +
   `$wgCdnMaxAge`, default **18000 s = 5 h**). This is the path that carries the
   bulk of Wikipedia traffic. See *Caching strategy* below.
2. **ParserCache hit (cheap PHP).** On a CDN miss, the request reaches PHP but
   the parsed `ParserOutput` is read from ParserCache; the skin assembles HTML
   around it. No wikitext is parsed.
3. **Uncached parse (expensive PHP — the thing to avoid).** On a ParserCache
   miss the page is *parsed*: wikitext → `ParserOutput`. **This is the single
   most expensive core operation**, which is the entire reason ParserCache
   exists (parser-and-content-transform.md). A logged-in view of a page that an
   anon never cached, a `?action=purge`, a template edit invalidating millions
   of pages — all funnel into this path.

**Writes are the rare path.** Reads dominate writes by orders of magnitude, which
is why the DB topology is one primary + many replicas (database-rdbms.md) and why
**no writes on GET** is a hard rule (see *Gotchas*).

### Where time actually goes (on a miss)

| Cost | Why | Mitigation in the code |
|---|---|---|
| **Wikitext parse** | template expansion, parser functions, link resolution, sanitization, tidy | ParserCache; PoolCounter (one server parses, others wait) |
| **DB replica reads** | link existence, page metadata, messages | LinkCache + `LinkBatch` (one query, not N); WANCache for derived data |
| **Localisation** | loading all `MediaWiki:` messages for a language | MessageCache (3-tier); LocalisationCache |
| **Output/RL assembly** | building `<head>`, module manifest, CSS/JS | startup manifest + version-hash CDN cache (output doc) |

### Known bottlenecks (the ones that actually page someone)

- **Uncached parses in bulk.** A change to a heavily-transcluded template marks
  every transcluding page's ParserOutput stale. The 2009 "Michael Jackson
  effect" — a single hot page repeatedly purged, every web server re-parsing it
  at once — is *the* origin story of **PoolCounter** (caching-deferred-jobs.md,
  Flow 3). Default `$wgPoolCounterConf` is unconfigured → `PoolCounterNull` → no
  cross-server limiting; a stock wiki relies only on WANCache's `lockTSE` mutex.
- **Pages with millions of backlinks.** Editing such a template/category cannot
  update every dependent page inline. The page's *own* `LinksUpdate` runs inline
  (deferred); **backlinked pages are refreshed asynchronously via
  `RefreshLinksJob`** (caching-deferred-jobs.md, Flow 2). Trying to do this
  synchronously is how you blow the request time limit.
- **Expensive parser functions** (`{{PAGESINCATEGORY}}`, etc.) are throttled per
  parse by `$wgExpensiveParserFunctionLimit` (default **100**); the preprocessor
  is bounded by `$wgMaxPPNodeCount` (default **1,000,000** nodes) and
  `$wgMaxPPExpandDepth`/`$wgMaxTemplateDepth` (default **100**). Hitting a limit
  can set `PREVENT_SELECTIVE_UPDATE` on the output (parser doc).
- **Large category / watchlist / `Special:WhatLinksHere` queries.** Backlink and
  category enumeration over a huge set is expensive; `$wgMiserMode` exists to
  disable the most database-intensive of these on small hosts (see *Scaling*).
- **`COUNT(*)` and unindexed scans.** `COUNT(*)` is O(N); unindexed queries are
  rejected in review except in `QueryPage`-derived special pages
  (database-rdbms.md gotcha 12).

---

## Resource limits (memory, time, article/upload size, query/API limits, pools)

These are real, enforced ceilings in core. Values are the **defaults** from
`includes/MainConfigSchema.php` unless noted.

### Per-request PHP limits

- **Memory:** `$wgMemoryLimit` (default `'50M'`) is the *floor* MediaWiki will
  try to raise PHP's `memory_limit` to if it is lower. The actual cap is PHP's
  `memory_limit` from `php.ini` — MediaWiki only nudges it up.
- **Execution time:** governed by PHP's `max_execution_time` (and the web
  server / FPM timeout), *not* a core config value. The design contract is that
  anything that might exceed it must be **deferred or enqueued** — this is the
  architectural reason the job queue and `DeferredUpdates` exist.

### Content size

- **`$wgMaxArticleSize`** — maximum wikitext size of a single page, **default
  2048 KiB (2 MiB)**. A larger article cannot be saved.
- **`$wgMaxUploadSize`** — **default 100 MiB** (`1024 * 1024 * 100`); also
  capped by PHP's `upload_max_filesize` / `post_max_size`. Chunked upload has a
  `$wgMinUploadChunkSize` (1 KiB default).

### Image / media decompression-bomb guards

- **`$wgMaxImageArea`** — **default 12,500,000 px** (the doc: ~50 MB decompressed
  to RGBA, i.e. 3500×3500). Above this, MediaWiki refuses to scale the image
  rather than risk an OOM decompressing a small-on-disk but huge-when-decoded
  file. **`$wgMaxAnimatedGifArea`** (same default) collapses oversized animated
  GIFs to a single frame. These are security/availability guards, not quality
  knobs.

### Shell / subprocess limits (image scaling, etc.)

Shelled-out tools (ImageMagick, etc.) run under hard caps:
`$wgMaxShellMemory` (**307,200 KiB ≈ 300 MiB** virtual memory),
`$wgMaxShellFileSize` (**102,400 KiB = 100 MiB** scratch),
`$wgMaxShellTime` (**180 s** CPU) and `$wgMaxShellWallClockTime` (**180 s**).
On Linux these are enforced via `ulimit` or, more reliably, a cgroup
(`$wgShellCgroup`). A runaway `convert` is killed, not allowed to wedge the box.

### Database & API limits

- **API result limits** (`includes/api/ApiBase.php`): `LIMIT_BIG1 = 500`
  (max per page for normal users on a "big"/fast query), `LIMIT_BIG2 = 5000`
  (for users with the `apihighlimits` right), `LIMIT_SML1 = 50` / `LIMIT_SML2 =
  500` for "slow" queries. Query modules cap their `limit` parameter at these.
- **Recency flags** (`IDBAccessObject`: `READ_NORMAL`/`READ_LATEST`/…) gate how
  much primary-DB load a read incurs; default is the cheap replica read.
- **Job batch sizing:** `$wgUpdateRowsPerJob` (300) and `$wgUpdateRowsPerQuery`
  (100) bound how much one job touches at once, so large backlink sets are
  partitioned rather than done in one giant transaction.
- **`$wgMaxJobDBWriteDuration`** (default `false` = off) — a job whose write
  transaction exceeds this many seconds is rolled back with an error rather than
  committed, a guard against a single job holding locks too long.

### Concurrency pools (PoolCounter)

`$wgPoolCounterConf` configures cluster-wide semaphores limiting how many servers
may *simultaneously* run the same expensive task. Core pool types (from the
config docblock): `ArticleView`, `HtmlRestApi`, `ApiParser`, `FileRender`,
`FileRenderExpensive`, `GetLocalFileCopy`, `diff`, `SpecialContributions`.
**Default is unconfigured (`PoolCounterNull`, no limiting)** — real protection
requires the `poolcounterd` daemon or Redis. See caching-deferred-jobs.md Flow 3.

---

## Caching strategy & invalidation (overview → see Caching subsystem)

**The full model is in [`subsystems/caching-deferred-jobs.md`](subsystems/caching-deferred-jobs.md)
— read it. This is the at-a-glance map.** Caching is layered; a request falls
through the tiers and stops at the first hit:

```
Browser cache
  └─ CDN ($wgUseCdn, s-maxage = $wgCdnMaxAge=18000s)        ← anon page views stop here
       └─ HTMLFileCache (optional, on-disk full HTML, anon only)
            └─ ParserCache (parsed ParserOutput; $wgParserCacheType)   ← the crown-jewel derived cache
                 └─ WANObjectCache (multi-DC cache-aside for derived data)
                      └─ Local cluster cache (memcached; $wgMainCacheType)
                           └─ Local server cache (APCu, per-server)
                                └─ In-process caches (LinkCache, MessageCache tier-1, ...)
                                     └─ DB replicas → DB primary (source of truth)
```

Key facts a perf-conscious dev must hold:

- **ParserCache is the highest-value derived cache.** Invalidation on edit is
  **save-through, not delete**: `DerivedPageDataUpdater::doParserCacheUpdate()`
  *writes* a fresh entry for the new revision (caching-deferred-jobs.md). Its key
  is `page + ParserOptions::optionsHash(usedOptions)` — fragmentation is
  *value-and-usage* based, so **changing an option's default silently keeps old
  `"canonical"` entries valid; you must manually invalidate** (parser doc).
- **CDN invalidation is purge + TTL.** Edits enqueue CDN purges via
  `HTMLCacheUpdater`/`CdnCacheUpdate`. Under replica lag the CDN TTL is shortened
  to `$wgCdnMaxageLagged` (**30 s**) so stale anon views converge fast; under
  PoolCounter contention a stale ParserCache response is served with
  `$wgCdnMaxageStale` (**10 s**); a known-incomplete response gets
  `$wgCdnMaxageSubstitute` (**60 s**).
- **ResourceLoader invalidation is by version hash, not purge.** A module's
  content change → new `getVersionHash()` → new `version=` URL → automatic
  CDN/browser bust; versioned RL responses cache for ~30 days, the startup
  manifest only ~5 min (output-skins-resourceloader.md, invariants 2 & 11).
- **Defaults are unset on a stock install.** `$wgMainCacheType` defaults to
  `CACHE_NONE` and `$wgUseCdn` to `false` — a fresh wiki runs all the WAN-cache
  machinery against an `EmptyBagOStuff`. "Works but slow" is the default state;
  production wikis must opt in (caching-deferred-jobs.md, tier table).
- **Never gate a write on a cache read.** "Treat the cache as a replica DB" —
  purges are async across DCs (caching-deferred-jobs.md invariant 3).

---

## Concurrency model & its limits (shared-nothing per request, FPM, job queue)

MediaWiki is **shared-nothing per request**. There is **no shared in-process
state across requests** — every web request boots a fresh PHP process
(`WebStart.php` → `Setup.php`), serves one request, and dies. Concurrency is
"more processes," not threads.

- **PHP-FPM workers.** Parallelism = the number of FPM worker processes the app
  servers run. Each worker handles one request at a time; the count caps
  in-flight requests. The implication for code: a slow request *occupies a
  worker*, so anything slow that can be deferred must be (see Gotchas).
- **In-process caches die with the request.** `LinkCache` (a `MapCacheLRU` of up
  to 10,000 entries), `MessageCache` tier-1, the `Title` instance cache (max
  1000), the deferred-updates scope stack — all per-process. Cross-request
  sharing only happens through the explicit cache tiers (APCu, memcached) or the
  DB. Do **not** assume anything persists between requests in PHP memory.
- **The job queue is the async escape hatch.** Work that is slow, retryable, or
  must fan out (RefreshLinksJob, HTMLCacheUpdateJob, thumbnail rendering) goes to
  the queue and runs in a *separate* process later (`JobRunner`). Jobs are
  **at-least-once, not exactly-once, ordering implementation-defined → must be
  idempotent** (caching-deferred-jobs.md invariant 8).
- **DeferredUpdates** runs slow-but-not-queue-worthy work *after the response is
  flushed* (POSTSEND, with `ignore_user_abort(true)`), so the user isn't waiting.
  Default stage is POSTSEND. Deferred updates get **no retry** unless they are
  `EnqueueableDataUpdate` (then they degrade to a job).
- **`$wgJobRunRate`** (default **1**) makes each web request opportunistically
  run ~1 queued job inline at the end. Big wikis set it to `0` and run jobs out
  of band (`runJobs.php`, changeprop) so user requests never pay for job
  execution.

**The limit of this model:** there is no in-process coordination across
requests, so any "only one of these may run at once across the cluster" need must
use an *external* coordinator — WANCache's `lockTSE` mutex (per cache key) or
PoolCounter (per task). See the PoolCounter vs `lockTSE` comparison table in
caching-deferred-jobs.md.

---

## Scaling approach & capacity assumptions (CDN, replicas, multi-DC, miser mode)

The same codebase scales **down** to a shared host and **up** to Wikipedia by
making every expensive thing optional and cacheable.

### Scaling up (Wikimedia-class)

- **Horizontal stateless app servers.** Because requests are shared-nothing,
  capacity = add more FPM app servers behind a load balancer. No app-server
  affinity is required (session state lives in the session store, not the
  process).
- **CDN absorbs read traffic.** Anonymous views are served from the edge; PHP
  only sees misses, logged-in users, and writes.
- **DB read scaling via replicas.** One writable **primary** + many read-only
  **replicas** per cluster, sharded across sections for wiki farms
  (`LBFactoryMulti`). Reads go to replicas (`getReplicaDatabase()`), writes to
  the primary (`getPrimaryDatabase()`). **Replication lag is real** (≤1s typical,
  up to ~30s) — see *Database performance*.
- **ChronologyProtector** gives read-your-writes across the replica fleet: after
  you write, your *next* request waits for the chosen replica to catch up to the
  saved primary position before reading (database-rdbms.md Flow 3). If the wait
  times out the request enters "lagged replica mode" and cache TTLs shorten.
- **Multi-DC.** WANCache purges are *broadcast* to all datacenters
  (mcrouter/dynomite, out of repo); the cache is eventually consistent
  cross-DC. POSTs are routed to the primary DC (the `UseDC=master` cookie). The
  precise edge-routing topology lives in Wikimedia infra, not this repo (see
  *Open questions*).

### Scaling down (small / shared hosts)

- **`$wgMiserMode`** (default `false`) — "disable database-intensive features."
  Turning it on makes the most expensive special pages (the `QueryPage`-derived
  ones) serve cached results from the `querycache` table instead of running live,
  and lets `$wgDisableQueryPages` switch them off entirely. The CDN/cache layers
  are optional; a tiny wiki can run with `CACHE_NONE` and no CDN (just slow).

**Capacity assumption baked into the code:** that the *anonymous read* is served
without parsing or, ideally, without PHP. Anything that breaks that assumption
(forcing parses, writing on GET, defeating the CDN with per-user variance) is a
scaling regression even if it is functionally correct.

---

## Database performance (indexes, N+1 / LinkBatch, replication lag)

Full mechanism: [`subsystems/database-rdbms.md`](subsystems/database-rdbms.md)
and [`subsystems/title-linking-namespaces.md`](subsystems/title-linking-namespaces.md).
The performance essentials:

- **Indexes.** Every query must hit an index; the abstract schema in
  `sql/tables.json` defines them. Unindexed queries are rejected in review except
  in `QueryPage`-derived special pages (the one tolerated exception). `COUNT(*)`
  is O(N) — prefer `estimateRowCount()`/`fetchRowCount()` consciously.
- **N+1 avoidance via `LinkBatch`/`LinkCache`.** A single article emits
  hundreds–thousands of links/transclusions; resolving existence one-by-one would
  be thousands of queries. The pattern is **batch once, then read from cache**:
  `LinkBatchFactory->newLinkBatch($titles)->execute()` runs *one*
  `makeWhereFrom2d()` query and warms `LinkCache`; subsequent `$title->exists()`
  calls hit the in-process cache with no query (title-linking doc, Flow 2). The
  contract from `docs/LinkCache.md`: when you write iterate-over-titles code,
  **verify in the `rdbms` debug channel that no per-title `page` query remains** —
  only the single `LinkBatch::doQuery`.
- **Replica vs primary, and recency flags.** `$dbr = getReplicaDatabase()` is
  read-only (the type system stops you writing to it); only escalate to
  `READ_LATEST`/`READ_LOCKING` when a read determines a write — higher QoS = more
  primary load.
- **The implicit transaction round holds locks until end of request.** In web
  mode your first write auto-BEGINs a transaction (`DBO_TRX`) that commits at
  `commitPrimaryChanges()` near request end → **compute first, write last** to
  minimize the lock window (database-rdbms.md gotchas 6–7).
- **Replication lag awareness in CLI / long scripts.** Maintenance scripts
  autocommit (no `DBO_TRX`) and **must call `waitForReplication()` between
  batches** (never while a transaction is open) or they will out-run the replicas
  and pile up lag. Long scripts must also drain `DeferredUpdates` opportunistically
  or the queue grows unbounded (caching-deferred-jobs.md invariant 14).
- **Slow-query discipline.** `TransactionProfiler` logs warnings and bumps stats
  when configured expectations are exceeded (too many writes/queries/connections,
  queries > ~0.25 s, lock-holding transactions > 3 s). `silenceForScope()` only
  when you genuinely know better.

---

## Rate limits & quotas

- **`$wgRateLimits`** — per-action throttles keyed by actor class
  (`ip`, `newbie`, `user`, `ip-all`, plus `apihighlimits` groups). Each entry is
  `[count, seconds]`. Defaults include: `edit` → 90/60s for users, 8/60s for IPs
  and newbies; `move` → 8/60s user, 2/120s newbie; `upload` → 8/60s;
  `rollback` → 10/60s; `mailpassword` → 5/3600s; `sendemail` → 20/86400s user;
  `purge`/`linkpurge` → 30/60s; `renderfile` → 700/30s. Counters live in the
  cluster cache / MicroStash (the rate limiter and ChronologyProtector are the
  documented MicroStash consumers — caching-deferred-jobs.md). `$wgRateLimits`
  merges with `array_plus_2d`, so site config extends rather than replaces.
- **`$wgRateLimitsExcludedIPs`** exempts trusted ranges (NAT gateways, etc.).
- **API `maxlag`** (`ApiMain`) — clients (especially bots) pass `maxlag=N`;
  if replica lag exceeds it the API returns an error with a `Retry-After`, telling
  the bot to back off. `$wgJobQueueIncludeInMaxLagFactor` can fold job-queue depth
  into the reported lag so bots also back off when the queue is deep (typical bot
  backoff is `maxlag=5`).
- **API result-size quotas** — `LIMIT_BIG1`/`BIG2`/`SML1`/`SML2` (see *Resource
  limits*) cap how many rows one query module returns.
- **PoolCounter** is effectively a *concurrency* quota (N simultaneous workers per
  expensive task) rather than a rate limit; see *Resource limits*.

---

## SLOs/metrics & observability (Profiler, stats, logging)

**Caveat up front:** core ships the *instrumentation*; the SLO targets,
dashboards, and alerting are **Wikimedia-operational and live outside this repo**
(Grafana, Logstash, etc.). There are **no SLO numbers in this checkout** — do not
invent them. What core gives you:

- **Profiler** (`includes/Profiler/`). `Profiler` is the base; backends are
  `ProfilerXhprof` (Xhprof), `ProfilerExcimer` (Excimer sampling profiler),
  `ProfilerSectionOnly`, and `ProfilerStub` (the default no-op). Configured via
  `$wgProfiler`. Output sinks live in `includes/Profiler/Output/`
  (`ProfilerOutputText`, `ProfilerOutputDump`, `ProfilerOutputStats`). It also
  owns `TransactionProfiler` (the slow-query/too-many-connections watchdog).
  `SectionProfiler` measures named code sections.
- **StatsFactory** (`includes/libs/Stats/`, `Wikimedia\Stats\`, `@since 1.41`) —
  the modern metrics API. Counters, gauges, timings, histograms via
  `getStatsFactory()->withComponent(...)`. It is injected widely (WANCache,
  rate limiter, RDBMS, job runner, and ~20 other services in `ServiceWiring.php`).
  Emission format is selectable (`OutputFormats`: **statsd** or **dogstatsd**);
  the Prometheus exposure is downstream of the emitter/format (the in-repo
  formats are statsd-family — Prometheus scraping is an infra concern). The older
  statsd `IBufferingStatsdDataFactory` still exists and StatsFactory can bridge
  to it.
- **Structured logging** via PSR-3 (`LoggerFactory`); the `profiler` channel is
  one of many. Channels surface things like redundant parses (`ParserObserver`
  logs a duplicate parse of the same page+revid+options — a caching-bug signal)
  and the `rdbms` channel (where `LinkBatch::doQuery` and per-query callers
  appear — your N+1 verification tool).
- **`$wgShowHostnames`** controls whether server hostnames appear in output/headers
  (useful for tracing which app server served a response).

For local performance work, `maintenance/benchmarks/` has micro-benchmarks
(`benchmarkParse.php`, `benchmarkSanitizer.php`, `benchmarkTidy.php`,
`benchmarkPurge.php`, `benchmarkLruHash.php`, `benchmarkTitleValue.php`,
`benchmarkEval.php`, …). The README documents pairing them with `perf stat -e
instructions` for instruction-count precision. *(Not run here — no toolchain.)*

---

## Performance gotchas (the rules a dev must internalize)

These are the codebase-specific rules that separate a patch that scales from one
that pages someone. Each ties back to a subsystem doc.

1. **No writes on a GET request.** GETs must be cacheable and idempotent; writing
   on GET fights the implicit transaction round and ChronologyProtector. Defer to
   a POST handler, a job, or `DeferredUpdates` (database-rdbms.md gotcha 4).
2. **Defer or enqueue slow work — never make the user wait.** Slow-but-immediate
   → `DeferredUpdates` (POSTSEND). Slow + retryable + fan-out → a **job**.
   Remember deferred updates get **no retry** unless `EnqueueableDataUpdate`
   (caching-deferred-jobs.md, Flow 2). And jobs must be **idempotent**
   (at-least-once delivery).
3. **Batch DB access — never loop a query.** Use `LinkBatch` for title existence;
   use the query builders' set conditions, not per-row queries. Verify in the
   `rdbms` debug channel that the per-row query is gone (title-linking doc).
4. **Don't trigger uncached parses in a loop.** Parsing is the most expensive
   core op. Re-parsing many pages inline (e.g. in a special page or hook over a
   list) will blow the time limit; that work belongs in `RefreshLinksJob` /
   batched jobs. Watch `ParserObserver`'s redundant-parse log lines.
5. **In a WANCache callback, always
   `$setOpts += Database::getCacheSetOptions($dbr);`** — omitting it caches
   lagged-replica data at full TTL (sticky stale data); the single most common
   WANCache bug (caching-deferred-jobs.md invariant 1).
6. **Use `WANObjectCache::getWithSetCallback`, not raw `get()`/`set()`** for
   derived data; raw get/set is racy in multi-DC (caching-deferred-jobs.md
   invariant 2). Never gate a write on a cache read.
7. **Don't add a non-cache-varying, non-default `ParserOption` on a hot path** —
   it makes the parse *uncacheable* (`isSafeToCache()` → false). And changing an
   option's *default* requires manual cache invalidation (parser doc).
8. **Mind replication lag in CLI.** Maintenance scripts must
   `waitForReplication()` between batches and drain deferred updates; they don't
   get the web request's transaction-round / chronology guarantees
   (database-rdbms.md gotcha 8; caching-deferred-jobs.md invariant 14).
9. **Compute first, write last.** The implicit transaction round holds write
   locks from your first write to end of request — minimize that window
   (database-rdbms.md gotchas 6–7).
10. **Watch ResourceLoader bundle size.** `bundlesize.config.json` sets per-module
    limits enforced by `tests/phpunit/structure/BundleSizeTest`; adding code to a
    tracked module can fail CI even if correct. Keep `load.php` responses
    session-independent or you defeat the CDN (output doc invariants 3 & 8).
11. **Don't defeat the CDN with per-user variance** on otherwise-anonymous-cacheable
    responses; per-user data belongs in the `user`/`user.options` RL modules or
    deferred client-side, not inlined into a CDN-cached page (output doc).
12. **Profile with the real backend in production mode.** RL `debug=true` disables
    minification/caching/304s and changes behavior substantially (output doc
    invariant 9); the default Profiler is a stub.

---

## Foundation (links)

- **Caching, deferred updates, jobs, PoolCounter (the authority):**
  [`subsystems/caching-deferred-jobs.md`](subsystems/caching-deferred-jobs.md) —
  plus `docs/memcached.md`, `docs/deferred.txt`,
  `includes/libs/objectcache/README.md`, `includes/JobQueue/README.md`.
- **Database, replication lag, transaction rounds, ChronologyProtector:**
  [`subsystems/database-rdbms.md`](subsystems/database-rdbms.md) +
  `docs/database.md`.
- **Why the parse is expensive, ParserCache fragmentation, parser limits:**
  [`subsystems/parser-and-content-transform.md`](subsystems/parser-and-content-transform.md).
- **N+1 avoidance, LinkBatch/LinkCache:**
  [`subsystems/title-linking-namespaces.md`](subsystems/title-linking-namespaces.md) +
  `docs/LinkCache.md`.
- **ResourceLoader bundle size & version-hash caching:**
  [`subsystems/output-skins-resourceloader.md`](subsystems/output-skins-resourceloader.md).
- **Config source of truth:** `includes/MainConfigSchema.php` (every `$wg*`
  default cited here). **Instrumentation:** `includes/Profiler/`,
  `includes/libs/Stats/`, `includes/PoolCounter/`. **Benchmarks:**
  `maintenance/benchmarks/`.
- **Repo conventions / no-toolchain constraint:** root `AGENTS.md`,
  `includes/AGENTS.md`.

---

### Open questions / genuine unknowns

- **SLO targets and dashboards are not in this repo.** Core ships Profiler +
  StatsFactory + PSR-3 logging; the actual SLOs, Grafana dashboards, Logstash
  queries, and alert thresholds live in Wikimedia operations infra and are
  *not verifiable from this checkout*. Stated as fact: the instrumentation
  exists; *inferred / external*: the targets.
- **Multi-DC / CDN edge routing specifics** (mcrouter/dynomite purge broadcast
  topology, the exact `UseDC=master` cookie ↔ edge contract) are configured
  outside this repo; described here at the library level only (echoing the
  caching and database subsystem docs' own open questions).
- **Prometheus exposure.** The in-repo Stats emitters are statsd-family
  (`statsd`, `dogstatsd` in `OutputFormats`). Whether/how those are scraped into
  Prometheus is downstream infrastructure — *inferred to be external*, not
  confirmed in-tree.
- **Effective per-request time/memory limits at WMF** depend on PHP-FPM/`php.ini`
  settings that are deployment config, not core defaults; only `$wgMemoryLimit`
  (a floor, `'50M'`) and the shell caps are in-repo.
- **PoolCounter / cache backends are no-ops by default** (`PoolCounterNull`,
  `$wgMainCacheType = CACHE_NONE`, `$wgUseCdn = false`). The performance story
  above assumes a production wiki has configured them; a stock install has almost
  none of these protections active. This is a real and common source of "works in
  testing, melts in production" surprises.
