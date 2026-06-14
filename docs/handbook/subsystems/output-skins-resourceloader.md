# Subsystem: Output, Skins & ResourceLoader

> Part of the MediaWiki core senior-onboarding handbook. Read the
> [root AGENTS.md](../../../AGENTS.md), [includes/AGENTS.md](../../../includes/AGENTS.md)
> and [resources/AGENTS.md](../../../resources/AGENTS.md) first — this document
> builds on them and does not repeat them. Authoritative upstream doc for skins:
> [`docs/Skin.md`](../../Skin.md); for the front-end `mw.*` API:
> [`resources/README.md`](../../../resources/README.md).

This is the subsystem that turns "the request handler produced some content" into
"the browser has a fully themed HTML document with the right JS and CSS." It
spans three code areas that are tightly coupled at one seam:

- `includes/Output/` — **OutputPage**, the request-scoped accumulator that
  builds the page skeleton and *declares which RL modules the page needs*.
- `includes/Skin/` — **Skin**, which themes the page (chrome: sidebar, header,
  footer, personal tools) and wraps OutputPage's body. **Skins are extensions.**
- `includes/ResourceLoader/` + `resources/` — **ResourceLoader**, the back end
  for `load.php` that delivers JS/CSS modules on demand, plus the front-end
  *source* (`resources/`) those modules are built from.

OutputPage is the single most-connected class in the entire codebase
(the "god node": ~209 graph edges — see `graphify-out/GRAPH_REPORT.md`). Almost
every action, special page, and extension touches it.

---

## Responsibility & boundaries

**This subsystem owns:**

- Assembling the final HTML document for *web views* (`index.php` /
  `ActionEntryPoint`): `<head>`, body skeleton, closing scripts, HTTP caching
  headers, and the inline bootstrap that points the browser at `load.php`.
- The contract a **Skin** must satisfy and the registration model that makes
  skins pluggable like extensions (`SkinFactory`, `ValidSkinNames`).
- Defining, versioning, minifying, batching, and serving **ResourceLoader
  modules** over `load.php`; the client-side `mw.loader` that lazy-loads them.
- The registry of core front-end modules (`resources/Resources.php`) and the
  source files they bundle (`resources/src/`).

**This subsystem does NOT own (siblings):**

- *Producing* the article body HTML — that's the
  [parser](parser-and-content-transform.md) (wikitext→HTML, `ParserOutput`).
  OutputPage *ingests* `ParserOutput`; it does not parse.
- Routing a request to a handler, or the action/special-page logic that *calls*
  OutputPage — see [actions-special-pages-editing](actions-special-pages-editing.md)
  and [action-api](action-api.md)/[rest-api](rest-api.md) (the APIs do not use
  the Skin pipeline; the API "skins" `SkinApi`/`json` are thin shims).
- The HTTP caching *policy substrate* (CDN, WAN cache, message-blob cache)
  beyond what OutputPage/RL set on individual responses — see
  [caching-deferred-jobs](caching-deferred-jobs.md).
- The DI container and hook plumbing it rides on — see
  [service-container-and-config](service-container-and-config.md) and
  [hooks-and-extension-registration](hooks-and-extension-registration.md).
- Message text and language fallback chains — see [localisation](localisation.md).

**The defining mental model:** the server never ships module *bodies* with the
HTML page. OutputPage emits a tiny inline script + one `<script async>` pointing
at `load.php?modules=startup`. The startup module ships a *manifest* (every
module's name, version, dependencies, group) plus the `mw.loader` client. The
client then requests *batches* of modules on demand. The **version hash** is the
spine that ties cache invalidation together across server and client.

---

## Internal structure (key files & their roles)

### `includes/Output/`
| File | Role |
|---|---|
| `OutputPage.php` (~170 KB, ~5200 lines) | The accumulator + orchestrator. `extends ContextSource`. Holds head/body/module/config/cache state; `output()` triggers rendering by delegating to the Skin. |
| `OutputHandler.php` | Output-buffer callback (gzip, charset mangling) at the PHP layer. |
| `StreamFile.php` | Streams file responses (used by `thumb.php`/`img_auth.php`-style paths). |
| `Hook/` | The hook interfaces this area fires (`OutputPageBeforeHTMLHook`, `BeforePageDisplayHook`, `OutputPageParserOutputHook`, …). |

### `includes/Skin/`
| File | Role |
|---|---|
| `Skin.php` (~84 KB) | Abstract base, `@stable to extend`. One abstract method: `outputPage()`. Defines `getDefaultModules()`, `getTemplateData()`, sidebar, options. |
| `SkinTemplate.php` (~64 KB) | **Legacy** template engine (`QuickTemplate`-based). Still `@stable`. |
| `SkinMustache.php` (~3 KB) | **Modern, recommended** base (since 1.35). Runs a `.mustache` template via `TemplateParser` over `getTemplateData()`. |
| `SkinFactory.php` | DI service that registers (`register()`) and instantiates (`makeSkin()`) skins; `getInstalledSkins()`. |
| `SkinFallback.php`, `SkinApi.php`, `SkinAuthenticationPopup.php` | Built-in recovery / API-output / auth-popup skins (all extend `SkinMustache`). |
| `Components/` | `SkinComponent*` — pure *data providers* (logo, search-box, footer, copyright, TOC, menus) feeding Mustache. `SkinComponentRegistry` builds the standard set. |
| `Hook/` | Skin extension seams (`SkinTemplateNavigation::Universal`, `SkinBuildSidebar`, `SidebarBeforeOutput`, `SkinAfterPortlet`, `SkinAddFooterLinks`, …). |

### `includes/ResourceLoader/`
| File | Role |
|---|---|
| `ResourceLoader.php` (~72 KB) | The orchestrator. Module registration (`register`), `getModule()` (lazy instantiation), `respond()` (the load.php handler), version hashing (`makeHash`/`getCombinedVersion`), `filter()` (minify cache), `makeModuleResponse`. |
| `Module.php` (~34 KB) | Abstract base module: dependencies, group, messages, skins, `getVersionHash()` (final), `getType()`, `buildContent()`. |
| `FileModule.php` (~51 KB) | The workhorse, and the **implicit default class** when a module declares none. `scripts`, `styles`, `skinStyles`, `messages`, `packageFiles`, `languageScripts`. |
| `StartUpModule.php` (~15 KB) | The startup manifest: `mw.loader` client + the full module registry (names→version/deps/group/source/skip). Served raw, first. |
| `Context.php` / `DerivativeContext.php` | The parsed `load.php` request: `modules`, `skin`, `lang`, `debug`, `only`, `version`, `user`, `raw`. |
| `ClientHtml.php` (~17 KB) | Builds the `<script>`/`<link>` HTML that OutputPage emits to point the browser at `load.php`. The server→client seam. |
| `SkinModule.php` (~28 KB) | Special `FileModule` for skin styles via the **"features"** system (opt into core-provided CSS bundles instead of re-shipping common styles). |
| `WikiModule.php`, `SiteModule.php`, `UserModule.php`, `UserOptionsModule.php`, `UserStylesModule.php` | Modules backed by on-wiki pages (`MediaWiki:Common.css`, user JS/CSS) and per-user state. |
| `CodexModule.php`, `OOUI*Module.php`, `ImageModule.php` | Vue/Codex packaging, OOUI theme assets, CSS sprite/image modules. |
| `MessageBlobStore.php` | Bundles `mw.msg` translations per module per language; two-level cache invalidation. |
| `DependencyStore.php` | Tracks *indirect* file deps (images/`@import` a stylesheet references) so a changed background image bumps the module version. |
| `ResourceLoaderEntryPoint.php` | The `load.php` entry point (`define( 'MW_NO_SESSION' )` — RL responses must not vary on session). |

### `resources/` (front-end source — see `resources/AGENTS.md`)
| Path | Role |
|---|---|
| `Resources.php` (~3800 lines) | **The core module registry.** Returns a big array of module-definition arrays. *A file under `src/` does nothing until it's declared here.* |
| `src/` | MediaWiki's own modules: `mediawiki.base`, `mediawiki.api`, `mediawiki.Title`, `mediawiki.util`, `mediawiki.page.ready`, `mediawiki.jqueryMsg`, `mediawiki.action.*`, etc. |
| `src/startup/` | The `mw.loader` implementation itself (`mediawiki.js`, `mediawiki.loader.js`, `startup.js`, `clientprefs.js`) — string-injected into the startup module's response. |
| `lib/` | Vendored third-party browser libs (jQuery, OOjs, etc.). |
| `assets/`, `templates/` | Static images/fonts; shared HTML templates. |

---

## Main flows

### Flow 1 — Page render (`index.php` web view)

Trace of `OutputPage::output()`
(`includes/Output/OutputPage.php:3186`):

1. **Accumulation phase** (throughout the request): handlers and extensions call
   `addHTML()`, `addParserOutput($po)`, `addModules()`, `addModuleStyles()`,
   `addJsConfigVars()`, `setPageTitle()`, etc. OutputPage renders nothing yet.
2. `output()`: short-circuit if disabled (e.g. after a 304) or a redirect is set
   (`onBeforePageRedirect` hook, then `Location:` + `sendCacheControl()`, return).
3. Otherwise `ob_start()`, send response headers (`Content-language`,
   `X-Frame-Options`, CSP).
4. `loadSkinModules($sk)` pulls the skin's default modules/styles into the queue;
   fire **`onBeforePageDisplay($out, $sk)`** — the canonical "last chance to add
   modules/CSS" hook.
5. Call **`$sk->outputPageFinal($this)`** (`OutputPage.php:3313`) — the inversion
   point: the Skin now drives, calling *back* into OutputPage.
6. `Skin::outputPageFinal()` (`includes/Skin/Skin.php:678`) does, in this exact
   order (load-bearing — see Invariants):
   ```php
   ob_start(); $this->outputPage(); $html = ob_get_contents(); ob_end_clean(); // BODY first
   $head = $out->headElement( $this );   // HEAD last — freezes the RL queue (T259955)
   $tail = $out->tailElement( $this );   // closing scripts (getBottomScripts)
   echo $head . $html . $tail;
   ```
7. `headElement()` (`OutputPage.php:3871`) builds `<head>`: charset, `<title>`,
   then **`getRlClient()->getHeadHtml()`** (the inline bootstrap + startup
   `<script async>` + stylesheet links), exempt/legacy styles,
   `getHeadLinksArray()` (meta/link/feed tags), raw head items, then `<body>`.
8. The Skin's `generateHTML()` produces chrome and embeds `$out->getHTML()` (the
   accumulated body / `mBodytext`).
9. `tailElement()` emits `getBottomScripts()` (deferred inline RLQ + late JS
   config vars), then `</body></html>`.
10. Back in `output()`: fire `onAfterFinalPageOutput($out)` (rewrite whole
    buffer), `sendCacheControl()`, flush.

### Flow 2 — `load.php` module delivery

Trace of `ResourceLoader::respond()`
(`includes/ResourceLoader/ResourceLoader.php:652`), reached via
`ResourceLoaderEntryPoint`:

1. Parse `Context` from query params; reject `GROUP_PRIVATE` modules from the web
   (security: T36907 — private modules are *embedded* in HTML, never served).
2. `preloadModuleInfo()` batch-loads file deps + message blobs so per-module
   version hashing doesn't fan out to DB/disk.
3. Compute `$versionHash = getCombinedVersion(...)`; form a weak ETag `W/"<hash>"`.
4. **304 check** (`tryRespondNotModified`): if `If-None-Match` matches and not
   debug, tear down output buffering and send `304`.
5. `makeModuleResponse()` builds the body — per module, scripts+styles+messages
   wrapped in `mw.loader.impl(function(){ return ["name@version", scripts, styles,
   messages, templates]; })` (plain function, not arrow — preserves V8 lazy
   compilation, T343407). `only=styles` → raw `text/css`; `only=scripts` → raw JS
   with state pre-set to `ready`.
6. Minify (unless debug) via cached `filter('minify-js'|'minify-css')`.
7. `sendResponseHeaders()`: cache tier by URL shape — `maxageVersioned` (30 days,
   safe because content change → new version → new URL), `maxageUnversioned`
   (~5 min, for startup/stylesheets linked from HTML that can't carry their own
   hash), or `MAXAGE_RECOVER` (60 s, on version mismatch / error).

```mermaid
flowchart TD
    subgraph Server["index.php  (ActionEntryPoint)"]
        H["Action / SpecialPage / Article"] -->|"addParserOutput(po)<br/>addModules() / addModuleStyles()<br/>addJsConfigVars()"| OP["OutputPage<br/>(accumulator, 'god node')"]
        PO["ParserOutput<br/>(from parser subsystem)"] -.->|body HTML, categories,<br/>modules, JS vars, head items| OP
        OP -->|"output() -> Skin::outputPageFinal()"| SK["Skin (extension)<br/>SkinMustache + skin.mustache"]
        SK -->|"generateHTML() embeds $out->getHTML()"| OP
        OP -->|"headElement() -> getRlClient()"| CH["ClientHtml"]
    end

    CH -->|"emits inline bootstrap + tags"| HTML

    subgraph HTML["HTML document sent to browser"]
        RLCONF["inline &lt;script&gt;:<br/>RLCONF (mw.config),<br/>RLSTATE, RLPAGEMODULES"]
        STYLES["&lt;link rel=stylesheet&gt;<br/>load.php?only=styles&amp;modules=..."]
        STARTUP["&lt;script async<br/>src=load.php?modules=startup&amp;raw=1&gt;"]
    end

    subgraph Browser
        STARTUP -->|loads manifest + mw.loader client| LOADER["mw.loader<br/>(registry: name->version/deps/group)"]
        RLPAGEMODULES -.->|mw.loader.load(...)| LOADER
        LOADER -->|"resolves deps, checks<br/>mw.loader.store (localStorage)"| BATCH["batched request:<br/>load.php?modules=a,b,c&amp;version=HASH"]
        LOADER -->|state ready| STORE["localStorage<br/>MediaWikiModuleStore:DBname"]
    end

    subgraph LoadPHP["load.php  (ResourceLoaderEntryPoint)"]
        BATCH --> RESPOND["ResourceLoader::respond()"]
        STARTUP -.-> RESPOND
        STYLES -.-> RESPOND
        RESPOND -->|version mismatch? 304? minify| RESP["mw.loader.impl(function(){...})<br/>or raw CSS / raw JS"]
    end

    RESP -->|"Cache-Control: 30d if versioned"| LOADER
```

---

## State & data it owns

**OutputPage** is a request-scoped, mutable accumulator. Key state (all on
`OutputPage.php`):

- **Title/head:** `mPageTitle` (`<h1>`), `mHTMLtitle` (`<title>`), `displayTitle`,
  `mSubtitle`, `mMetatags`, `mLinktags`, `mCanonicalUrl`, `mFeedLinks` (RSS/Atom),
  `mHeadItems` (arbitrary raw `<head>` HTML keyed by name).
- **Body:** `mBodytext` (the accumulated `<body>` content; appended via
  `addHTML()`/`prependHTML()`, read via `getHTML()`), `mAdditionalBodyClasses`,
  `mIndicators` (status indicators), `mCategoryLinks`/`mCategories` (categories),
  `tocData`.
- **Modules:** `mModules` (JS+CSS modules loaded async via `mw.loader`) and
  `mModuleStyles` (style-*only* modules emitted as plain `<link>` so they work
  without JS). Both are ordered, deduplicated name→name maps.
- **Client config:** `mJsConfigVars` (page-specific `mw.config` vars added via
  `addJsConfigVars()`; merged in `getJSVars()`, with an early/late split — early
  vars go in the head `RLCONF`, late vars in the bottom inline script).
- **Caching:** `mEnableClientCache`, `mCdnMaxage`, `mLastModified`, `mVaryHeader`,
  `cacheIsFinal`. `checkLastModified()` does timestamp-based conditional GET (304).
- **Lazy RL rendering:** `rlClient` (a `ClientHtml`), `rlClientContext`,
  `rlExemptStyleModules` (site/noscript/private/user style groups handled
  separately so their CSS cascade order is correct).
- **`metadata`:** an internal `ParserOutput` used as the unifying accumulator for
  language links, robots policy, and clickjacking across article *and* non-article
  pages.

**ResourceLoader** owns: the registered module *info* (`$moduleInfos`, lazily
instantiated by `getModule()`), the minify cache (local-server `BagOStuff`), and
delegates to `MessageBlobStore` (WAN-cached message JSON) and `DependencyStore`
(indirect file deps, stored as relative paths, TTL 1 year).

**Client-side** state: `mw.loader.store` in `localStorage`
(`MediaWikiModuleStore:<DBname>`), varying on skin + storage version + language.

---

## Dependencies (in / out)

**OutputPage depends on:** the parser subsystem (consumes `ParserOutput`); the
Skin (it delegates final assembly via `outputPageFinal()`); ResourceLoader
(via `ClientHtml`); `Title`/`User`/config/hooks/localisation through
`ContextSource`.

**Skin depends on:** OutputPage (wraps its body, reads title/categories/etc.);
ResourceLoader (`SkinModule` for styles, `getDefaultModules()` for behavior);
`SkinComponent*` data providers; localisation (messages); config (`$wgLogos`,
`$wgFooterIcons`, …).

**ResourceLoader depends on:** the registry (`resources/Resources.php` +
extension/skin `ResourceModules`); config; the message cache and language
fallback (for blobs); the object/WAN caches; the filesystem (`FileModule`).
It is deliberately **session-independent** (`load.php` defines `MW_NO_SESSION`).

**Consumed by:** virtually every web-facing handler —
[actions-special-pages-editing](actions-special-pages-editing.md) (every action
and special page writes to OutputPage), the installer, error pages, and any
extension that adds UI. Front-end code everywhere consumes `mw.*` modules.

---

## Extension / customization points

### Skins (skins are extensions)

A skin is just an extension whose manifest declares a `ValidSkinNames` key.
The chain (verified):

```
skin.json  "ValidSkinNames": { "foobar": { "displayname": "...", "class": "..." } }
  → ExtensionProcessor::extractSkins()  (writes $wgValidSkinNames, rewrites templateDirectory to absolute)
  → ExtensionRegistry pushes into $GLOBALS
  → the 'SkinFactory' service (ServiceWiring.php) reads ValidSkinNames and calls
      SkinFactory::register($name, $displayName, $spec, $skippable) per entry
```

- `wfLoadSkin( $skin )` is *identical* to `wfLoadExtension` except it defaults the
  manifest path to `$wgStyleDirectory/$skin/skin.json`. The `"type": "skin"` field
  is credit metadata only; what makes it a skin is the `ValidSkinNames` key.
- `$wgDefaultSkin` (default `'vector-2022'`) picks the default; unknown keys fall
  back via `Skin::normalizeKey()` → default → `$wgFallbackSkin` (`'fallback'` →
  `SkinFallback`, a recovery skin that prints `wfLoadSkin(...)` hints). The default
  is chosen at *install time* (`Installer::getDefaultSkin()`), baked into
  `LocalSettings.php`, not re-decided per request.
- `skins/` in this checkout is an **empty placeholder**; the bundled skins
  (Vector 2022, Vector legacy, MinervaNeue, Timeless, MonoBook — see `docs/Skin.md`)
  are cloned in separately.

**Writing a new skin (recommended path):** extend `SkinMustache`, ship
`templates/skin.mustache`, and declare a `SkinModule` with a `features` map (opt
into core CSS bundles like `normalize`, `elements`, `content-media`, `interface`,
`toc` rather than re-shipping them). Override `getDefaultModules()` and
`getTemplateData()` as needed. Do *not* extend the raw `Skin` or `SkinTemplate`
for new work.

**Key skin hooks** (the seams for *modifying* existing skins):
`SkinTemplateNavigation::Universal` (the structured tabs/menus array — the big
one; the only surviving `SkinTemplateNavigation` variant), `SkinBuildSidebar`
(cacheable sidebar), `SidebarBeforeOutput` (per-request sidebar),
`SkinAfterPortlet`, `SkinAddFooterLinks`, plus the OutputPage-level
`onBeforePageDisplay` / `onOutputPageBeforeHTML` / `onOutputPageBodyAttributes`.

### ResourceLoader modules

Register in `resources/Resources.php` (core) or a `ResourceModules` block in
`extension.json`/`skin.json` (extensions/skins). A module is configured *by array*,
not by subclassing, in the common case; omitting `class` gives you a `FileModule`.
Common keys: `scripts`, `styles`, `skinStyles`, `messages`, `dependencies`,
`packageFiles` (modern multi-file with scoped `require()`), `group`, `skins`.

### Server-side output

Call `OutputPage` from any handler: `addHTML()`, `addWikiTextAsContent()`,
`addParserOutput($po)`, `setPageTitle()`, `addModules('foo')`,
`addModuleStyles('foo.styles')`, `addJsConfigVars('wgKey', $value)`. To inject
into someone else's page, use the hooks above.

---

## Invariants & gotchas

1. **`headElement()` must run *after* the body is generated.** Calling
   `getRlClient()` *freezes the ResourceLoader module queue* (T259955). Skins and
   late hooks add modules right up until the body is built, so the head is built
   last to capture them all. This is why `outputPageFinal()` does
   `ob_start(); outputPage(); ... headElement()` in that order.

2. **Cache invalidation is by version hash, not by purge.** A module's
   `getVersionHash()` (final, `Module.php`) hashes its definition summary
   (FileModule hashes *file contents*, never mtimes — T102578: git checkouts and
   multi-server fleets disagree on timestamps; never order-significant lists —
   T39812). The hash appears in the `version=` query param of batched `load.php`
   URLs, so a content change → new URL → automatic CDN/browser cache bust. The PHP
   combine algorithm **must stay identical to the JS `mw.loader#getCombinedVersion`**
   or clients and server disagree and you get stale or thrashing caches.

3. **`load.php` responses must not depend on the session** (`MW_NO_SESSION`).
   They are shared across users (modulo skin/lang/user-group params), so anything
   user-specific must go through the `user`/`user.options` modules (which carry a
   `version` param) — never inline a per-user value into a CDN-cached response.

4. **`GROUP_PRIVATE` modules cannot be served over `load.php`** (T36907). They are
   *embedded* into the HTML. `respond()` rejects them outright.

5. **`module` (JS) vs `moduleStyles` (style-only).** Use `addModuleStyles()` for
   render-blocking CSS that must work *without* JavaScript (it becomes a plain
   `<link>`); `addModules()` for everything loaded asynchronously by `mw.loader`.
   Mixing them up causes flash-of-unstyled-content or JS-gated styling.

6. **A `src/` file is invisible until registered in `Resources.php`.** This is the
   single most common front-end onboarding trap.

7. **RTL flipping is automatic via cssjanus** — author LESS for *LTR only*;
   ResourceLoader generates the RTL variant. Don't hand-write `[dir=rtl]` overrides
   for layout that cssjanus can flip.

8. **Bundle size is enforced.** `bundlesize.config.json` lists per-module limits;
   `tests/phpunit/structure/BundleSizeTest` (via `BundleSizeTestBase`) fails the
   build if a module exceeds `maxSize` (compressed) / `maxSizeUncompressed`. Each
   module must specify *exactly one* of the two (or `null` to opt out). Adding code
   to a tracked module can break CI even if your code is correct.

9. **Debug mode (`debug=true`) changes everything:** no minification, version hash
   becomes `''` (stable URLs for breakpoints, T235672), modules load in *separate*
   requests, `mw.loader.store` is disabled, no HTTP caching, no 304s. Production
   behavior differs substantially — always reproduce caching bugs in production
   mode.

10. **Dependency cycles** are handled (the startup module catches
    `CircularDependencyError` and prunes transitively-implied deps to shrink the
    manifest), but a real cycle in *your* module deps will mis-order execution —
    `ResourcesTest::testValidDependencies` guards the registry.

11. **The startup module carries no `version` param** (it's linked from HTML and
    can't know its own hash), so it gets the short ~5-min cache. That is the
    propagation latency for any registry/dependency/version change to reach clients
    — a deploy's RL changes are not instant.

12. **`output()` is terminal and side-effectful** (sends headers, flushes). Don't
    call it twice; for tests, prefer `headElement()`/`getHTML()` directly.

---

## How to make a typical change here

### Add output to a page (from an action / special page / hook)

```php
// Inside an Action, SpecialPage, or a BeforePageDisplay hook handler:
$out = $this->getOutput();             // or $context->getOutput()
$out->setPageTitle( $this->msg( 'my-feature-title' ) );
$out->addModuleStyles( 'mediawiki.foo.styles' );   // render-blocking CSS
$out->addModules( 'mediawiki.foo' );               // async JS behavior
$out->addJsConfigVars( 'wgMyFeatureFlag', true );  // -> mw.config in the browser
$out->addHTML( Html::element( 'p', [], $this->msg( 'my-feature-body' )->text() ) );
```

For article-style content, build a `ParserOutput` and `$out->addParserOutput($po)`.
To modify *another* feature's output, hook `onBeforePageDisplay`
(add modules/CSS) or `onOutputPageBeforeHTML` (rewrite the parsed body HTML).

### Add a ResourceLoader module

1. Create source under `resources/src/mediawiki.myfeature/` (e.g. `index.js`,
   `styles.less`, `App.vue`).
2. **Register it in `resources/Resources.php`:**
   ```php
   'mediawiki.myfeature' => [
       'packageFiles' => [
           'resources/src/mediawiki.myfeature/index.js',
           'resources/src/mediawiki.myfeature/util.js',
       ],
       'styles'       => [ 'resources/src/mediawiki.myfeature/styles.less' ],
       'dependencies' => [ 'mediawiki.api', 'mediawiki.util' ],
       'messages'     => [ 'myfeature-label', 'myfeature-error' ],
   ],
   ```
   (Extensions/skins put the identical array under `ResourceModules` in
   `extension.json`/`skin.json`.)
3. Add i18n keys to `languages/i18n/en.json` (+ `qqq.json`) — see
   [localisation](localisation.md). Use `mw.msg('myfeature-label')` in JS.
4. Load it from a page via `$out->addModules('mediawiki.myfeature')`.
5. **Tests/lint (canonical; toolchain not present here — do not run from this
   checkout):**
   - `npm run lint` — eslint + stylelint + banana (i18n).
   - `npm run jest` — JS unit tests (`tests/jest/`).
   - `npm run qunit` — browser QUnit (needs a *running* wiki + `MW_SERVER`).
   - `composer phpunit` (after `composer phpunit:config`) runs
     `ResourcesTest` (schema, valid deps, missing messages),
     `BundleSizeTest` (size limits — add an entry to `bundlesize.config.json` if
     the module should be tracked), and `OutputPageTest`.
6. If you added a new RL *class* (rare), regenerate `autoload.php`
   (`php maintenance/run.php generateLocalAutoload`).

### Add a skin

Extend `SkinMustache`, ship `templates/skin.mustache`, register via a `skin.json`
with `ValidSkinNames` + a `SkinModule` (`features` map) for styles, then
`wfLoadSkin('YourSkin')` in `LocalSettings.php`. See `docs/Skin.md`.

---

## Foundation

- **Foundational reading (don't duplicate):** root [`AGENTS.md`](../../../AGENTS.md),
  [`includes/AGENTS.md`](../../../includes/AGENTS.md),
  [`resources/AGENTS.md`](../../../resources/AGENTS.md).
- **Authoritative upstream docs:** [`docs/Skin.md`](../../Skin.md) (skins),
  [`resources/README.md`](../../../resources/README.md) (the `mw.*` front-end API),
  upstream `https://www.mediawiki.org/wiki/ResourceLoader/Architecture`.
- **Sibling subsystems:** [parser-and-content-transform](parser-and-content-transform.md)
  (produces the `ParserOutput` OutputPage ingests),
  [actions-special-pages-editing](actions-special-pages-editing.md) (the primary
  callers), [localisation](localisation.md) (messages/blobs),
  [caching-deferred-jobs](caching-deferred-jobs.md) (the cache substrate),
  [service-container-and-config](service-container-and-config.md) and
  [hooks-and-extension-registration](hooks-and-extension-registration.md)
  (the DI + hook plumbing and how `extension.json`/`skin.json` is processed),
  [auth-permissions-sessions](auth-permissions-sessions.md) (why `load.php` is
  session-free; user/user.options modules).
- **Key tests encoding the contract:**
  `tests/phpunit/includes/Output/OutputPageTest.php`,
  `tests/phpunit/structure/ResourcesTest.php`,
  `tests/phpunit/structure/BundleSizeTest.php`(+`BundleSizeTestBase.php`),
  `tests/qunit/` (browser JS — needs a running wiki).
- **God node:** `OutputPage` (~209 graph edges) — `graphify-out/GRAPH_REPORT.md`.

### Open questions / genuine unknowns

- **Codex/Vue packaging depth.** `CodexModule.php` + `VueComponentParser.php`
  handle `.vue` single-file components and on-demand Codex icon bundling
  (`CodexModule::getIcons`); the exact tree-shaking / icon-subsetting strategy and
  its interaction with bundle-size limits was not traced in detail here. *(Not
  verified — flag for a Codex/Design-System owner.)*
- **`mw.loader.store` eviction/quota behavior** (localStorage size limits, what
  happens on quota-exceeded) is implemented in `resources/src/startup/` JS that was
  only skimmed; the precise eviction policy is an inference, not confirmed.
- **`adaptCdnTTL()` / `lowerCdnMaxage()` tuning** — the heuristics OutputPage uses
  to shorten CDN TTL for recently-edited pages were noted but not fully traced;
  exact thresholds live in config and were not enumerated.
- The split between **early vs late** `mw.config` JS vars
  (`LateJSConfigVarNames`) — the policy for *which* vars are safe to defer to the
  bottom script is extension-extensible and not exhaustively documented here.
