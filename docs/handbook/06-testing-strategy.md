# Testing Strategy

> Scope: how MediaWiki core decides **what to test at which level**, **what to
> mock vs. exercise for real**, and **the bar a patch must clear before +2 on
> Gerrit**. This doc owns the *strategy*; the mechanical "where things live /
> which command" reference is `tests/AGENTS.md` (read that first — it is the
> foundation this builds on). Subsystem docs under
> `docs/handbook/subsystems/*.md` describe how their own corner is tested; this
> doc ties them together.
>
> Environment note: this checkout has **no PHP/Node toolchain** (`vendor/`,
> `node_modules/` absent). Every command below is taken from
> `composer.json` / `package.json` / `phpunit.xml.template` and is **documented,
> not executed here**. Versions: MW 1.47.0-alpha, PHP ≥ 8.3, PHPUnit 9.6
> (`composer.json` requires `phpunit/phpunit: 9.6.34`).

## The test pyramid (unit / integration / structure / parser / browser / e2e / api) & where each lives

MediaWiki's pyramid has an unusual fourth tier — **structure tests** — sitting
alongside the classic unit/integration/e2e layers. The full picture:

```
                         ┌─────────────────────────────┐
        e2e (slow, few)  │ Selenium / WebdriverIO       │  tests/selenium/
                         │ real browser, real wiki      │  (Mocha+wdio)
                         ├─────────────────────────────┤
   black-box HTTP        │ api-testing                  │  tests/api-testing/
                         │ real wiki, HTTP, no PHP guts │  (Mocha, supertest)
                         ├─────────────────────────────┤
   golden-file           │ parser tests (.txt fixtures) │  tests/parser/
                         │ + QUnit (browser JS)         │  tests/qunit/
                         ├─────────────────────────────┤
   integration (medium)  │ MediaWikiIntegrationTestCase │  phpunit/integration/,
                         │ DB + service container       │  phpunit/includes/
                         ├──────────────┬──────────────┤
   structure (invariant) │ phpunit/     │ Jest (node)  │  phpunit/structure/,
                         │ structure/   │ jsdom, mocks  │  tests/jest/
                         ├──────────────┴──────────────┤
   unit (fast, many)     │ MediaWikiUnitTestCase        │  phpunit/unit/
                         │ no DB, no services, no globs │
                         └─────────────────────────────┘
```

| Tier | Base / runner | Lives in | Use it when |
|---|---|---|---|
| **Pure unit** | `MediaWikiUnitTestCase` | `tests/phpunit/unit/` | The class under test uses DI and touches **no** DB, services, or globals. Default choice — fastest, enforces decoupling. |
| **Integration** | `MediaWikiIntegrationTestCase` (and `MediaWikiLangTestCase`) | `tests/phpunit/integration/`, `tests/phpunit/includes/` | The code needs the real service container, config, or DB; or you're testing the wiring of several collaborators. |
| **Structure** | mostly `MediaWikiIntegrationTestCase`, some plain `TestCase` | `tests/phpunit/structure/` | You're not testing *behavior* but a **repo-wide invariant** (autoloader fresh, schema regenerated, every special page non-fatal, every REST route well-formed). See its own section below. |
| **Parser** | generated PHPUnit classes from `.txt` fixtures | `tests/parser/*.txt` | Wikitext-in / HTML-out behavior. Golden-file format; add a case, not a PHP method. |
| **Maintenance** | `MediaWikiIntegrationTestCase` | `tests/phpunit/maintenance/` | A `maintenance/` CLI script's logic. |
| **Docs** | PHPUnit | `tests/phpunit/docs/` | Documentation invariants (e.g. hook docs in sync). |
| **Jest** | `npm run jest`, config `tests/jest/jest.config.js` | `tests/jest/**/*.test.js` | Node-side JS/Vue unit tests (jsdom env, Codex/Pinia mocked). No browser, no wiki. |
| **QUnit** | `npm run qunit` | `tests/qunit/` | Browser-context JS for `resources/` modules that need a real `mw.*` runtime. Needs a running wiki (`MW_SERVER`, `MW_SCRIPT_PATH`). |
| **Selenium** | `npm run selenium-test`, `tests/selenium/wdio.conf.js` | `tests/selenium/specs/` | End-to-end user journeys through a real browser against a real wiki. |
| **api-testing** | `npm run api-testing` | `tests/api-testing/{action,REST}/` | Black-box HTTP tests of the Action and REST APIs against a running wiki. |

The PHPUnit testsuites that wrap these (from `phpunit.xml.template`,
lines 29–62) are: `core:unit`, `extensions:unit`, `includes`, `parsertests`,
`maintenance_suite`, `structure`, `tests`, `extensions`, `integration`, `docs`.

## Running tests (all / subset / single)

**Generate the config first.** `phpunit.xml` is *generated* from
`phpunit.xml.template` by `tests/phpunit/generatePHPUnitConfig.php`; running
PHPUnit without it will not pick up extensions or the parser-test classes (the
generator materializes one PHP class per `.txt` file into `tests/phpunit/gen/`).

```sh
# documented, not executed here (no toolchain)
composer phpunit:config        # writes phpunit.xml (+ parser-test classes)
composer phpunit:unit          # fast DB-less tier: --testsuite=core:unit,extensions:unit
composer phpunit               # full suite (runs phpunit:config first, see scripts)
composer phpunit:coverage      # --testsuite=core:unit --exclude-group Dump,Broken

# a subset by testsuite:
composer phpunit -- --testsuite structure
composer phpunit -- --testsuite parsertests

# a single file / dir (run from tests/phpunit, per DEVELOPERS.md & tests/AGENTS.md):
cd tests/phpunit && composer phpunit -- path/to/MyTest.php
# a single parser case by title:
composer phpunit -- --testsuite parsertests --filter="T6400"
```

Front end (all need their respective deps; QUnit/Selenium/api-testing also need
a **running wiki**):

```sh
npm run jest            # node JS unit, no wiki
npm run qunit           # browser JS — needs MW_SERVER + MW_SCRIPT_PATH
npm run selenium-test   # e2e — needs a running wiki
npm run api-testing     # HTTP API — needs a running wiki + an api-testing config
```

**Parallel split (CI).** `composer.json` ships a split harness used by Quibble,
not normally run by hand: `phpunit:prepare-parallel:*` list the tests
(`--list-tests-xml`) and partition them into `tests-list-{default,extensions}.xml`
via `PhpUnitXmlManager`, then `phpunit:parallel:{database,databaseless,custom-groups}`
fan the partitions out across workers (`ComposerLaunchParallel`). The DB vs
DB-less split is load-bearing: DB-less tests parallelize freely; DB tests need
isolated clones (see below). *Inference:* this is a CI-time optimization;
day-to-day local work uses the plain `composer phpunit` paths above.

There is **no in-repo CI config** — the authoritative command list is
`composer.json` + `package.json`; CI definitions live in Wikimedia's Quibble.

## Choosing a base class (unit vs integration) & the decoupling it enforces

This is the single most important strategic decision, and **the test framework
enforces the codebase's DI policy through it.** Pick by what the code *needs*:

- **`MediaWikiUnitTestCase`** (`tests/phpunit/unit/`) — pure unit. Read its
  header (`tests/phpunit/MediaWikiUnitTestCase.php`): it actively *denies* the
  environment so a unit test physically cannot reach the platform:
  - `mediaWikiSetUpBeforeClass()` **fails the test** if the file is not under
    `tests/phpunit/unit/` (line ~76).
  - `MediaWikiServices::disallowGlobalInstanceInUnitTests()` — no global service
    locator; `ExtensionRegistry::disableForTest()`; `SettingsBuilder` access
    disabled; the logger is swapped for `NullSpi`.
  - **Globals are wiped to a tiny allow-list** (`ALLOWED_GLOBALS_LIST`,
    ~8 entries: autoload maps, `wgUrlProtocols`, logging vars) and restored
    between tests, so leaning on a global throws.
  - `getServiceContainer()` returns a **mock** `MediaWikiServices` that only
    knows the services you hand it via `setService()` — anything else throws
    `NoSuchServiceException`.

  The payoff: if your class can be unit-tested, it is properly decoupled. If it
  *can't* without a DB, that's a design smell the test split surfaces. New code
  should default here.

- **`MediaWikiIntegrationTestCase`** (`tests/phpunit/integration/`,
  `tests/phpunit/includes/`) — the real service container, real config, and —
  **only if you opt in with `@group Database`** — a real (cloned) DB. Its
  header (lines 55–66) says it outright: extend this when you access globals,
  services, or storage; otherwise prefer the unit case. DB and config changes
  are rolled back after each test.

**The DB opt-in is explicit and guarded.** Helpers like `getTestUser()`,
`getExistingTestPage()`, `getNonexistingTestPage()`, and `editPage()` throw a
`LogicException` if the class is **not** tagged `@group Database`
(`MediaWikiIntegrationTestCase.php` ~lines 290–406): e.g. *"When testing with
pages, the test must use @group Database."* DB-backed tests run against a
**clone with temporary tables** (`$useTemporaryTables = true`, `CloneDatabase`,
schema set up per run), which is why the suite is destructive and why the split
isolates them.

> **DESTRUCTIVE-DB WARNING (repeated because it bites people):** integration
> tests can wipe your local database. Never point them at a production or
> data-bearing wiki (`tests/phpunit/README.md`, root AGENTS.md).

## Fixtures, factories, mocks & service overrides

**The decision tree:** mock at the unit tier; override real services at the
integration tier; never reach for a global.

- **Unit tier — hand-built mocks.** Use PHPUnit's mock builder for
  collaborators and `setService(name, $obj)` to register them into the mock
  container returned by `getServiceContainer()`
  (`MediaWikiUnitTestCase.php` ~lines 164–218). The container resolves *only*
  what you register. Shared lightweight fakes live in `tests/phpunit/mocks/`
  (e.g. `DummyServicesTrait`, `MockTitleTrait`, `MockMessageLocalizer`,
  `MockServiceDependenciesTrait`, `TestLogger`) and `tests/Common/`.

- **Integration tier — override the real wiring.** The same method names exist
  but mean "replace in the live local container":
  - `setService(name, $service|callable)` swaps a service and **resets
    dependents** (`resetServices()`), restoring the original in tearDown
    (`MediaWikiIntegrationTestCase.php` ~line 886). It throws if the global
    `MediaWikiServices` instance was replaced by test code — so you override
    *through* the helper, not around it.
  - `overrideConfigValue($key, $value)` / `overrideConfigValues([...])`
    set config for the test's lifetime and roll back after (~lines 980, 1046).
    They currently also `setMwGlobals("wg$key", ...)` for legacy readers, and
    note that **overriding config resets affected service instances**.
  - `setTemporaryHook($name, $handler)` / `clearHook($name)` install or remove a
    hook handler in the `HookContainer` for one test (~lines 2587–2618) — the
    standard way to test extension-point behavior without a real extension.
  - `setGroupPermissions()`, `setUserLang()`, `setMainCache()` cover the common
    "tweak the environment" cases.

- **Factories for fixtures.** Don't fabricate rows by hand. Use the test-user
  and test-page factories: `getTestUser([$groups])`, `getTestSysop()`,
  `getExistingTestPage()`, `getNonexistingTestPage()`, `editPage()`,
  `insertPage()` (all `@group Database`-gated). Prefer `Authority`
  (`UltimateAuthority`) over real users where you only need permissions.

- **HTTP must be mocked, never live.** `MockHttpTrait`
  (`tests/phpunit/mocks/MockHttpTrait.php`) provides `installMockHttp()` /
  `makeMockHttpRequestFactory()` which inject a fake `HttpRequestFactory`
  (and Null Guzzle / MultiHttp clients) so tests never hit the network. There
  are dedicated `Null*` mocks (`NullHttpRequestFactory`, `NullGuzzleClient`,
  `NullMultiHttpClient`) for the same reason.

- **JS fixtures.** Jest mocks browser/Codex/Pinia: see the `moduleNameMapper`
  (icons → `@wikimedia/codex-icons`, etc.), `jest.setup.js`, `jsdom` env, and
  per-suite setup files like `SpecialBlock.setup.js` (`mockMwApiGet`,
  `mockMwConfigGet`). `clearMocks: true` resets between tests.

## Structure tests — the repo-invariant guard rail

A MediaWiki specialty and a force multiplier: instead of one assertion per case,
these scan the **whole repo** and fail if an invariant is violated — they catch
the entire "I forgot to regenerate / register X" class of bug that would
otherwise slip past review. Living in `tests/phpunit/structure/` (most tagged
`@coversNothing` because they assert structure, not a class):

| Test | Bug class it catches |
|---|---|
| `AutoLoaderStructureTest` | `autoload.php` stale or a file defines a class it doesn't register (relying on load order). Run `generateLocalAutoload` after add/move/rename. |
| `AbstractSchemaTest` | Per-DB generated SQL (`sql/{mysql,sqlite,postgres}`) out of sync with abstract `sql/tables.json` — i.e. you edited the schema but didn't regenerate. |
| `ExtensionJsonValidationTest` | Any loaded `extension.json`/`skin.json` violating the schema. |
| `ResourcesTest` | Bad ResourceLoader module registration (missing files, bad media types). |
| `BundleSizeTest` / `PerformanceBudgetTest` | A front-end module exceeding its declared size budget (`bundlesize.config.json`) — a perf regression guard. |
| `SpecialPageFatalTest` | Any registered special page that fatals on a basic run (executes under `UltimateAuthority`). |
| `RestStructureTest` / `ApiStructureTest` / `ApiPrefixUniquenessTest` | Malformed REST routes / API module params / colliding API prefixes. |
| `StructureTest` | Test files not ending in `Test` (so silently never run), and other test-layout bugs. |
| `AvailableRightsTest`, `PasswordPolicyStructureTest`, `CodexMessageDefinitionTest`, `CodexTokenDefaultsTest`, `EventSubscriptionTest`, `DumpableObjectsTest` | Registry/definition drift in their respective subsystems. |
| `OwnersStructureTestBase` | Malformed `OWNERS.md` files — ties into code-ownership (doc 11). |
| `PHPUnitConfigTest` | The generated PHPUnit config itself is well-formed. |

Treat a structure-test failure as a "you skipped a generate step" signal first,
a real bug second.

## Parser tests & other golden-file tests

The **parser tests** are MediaWiki's largest golden-file corpus: declarative
`.txt` fixtures in `tests/parser/` (`parserTests.txt` is the main file; others
cover tables, links, quotes, etc.). `generatePHPUnitConfig.php` turns each file
into a generated PHPUnit class (in `tests/phpunit/gen/`, via
`ParserTest.php.template`) under the `parsertests` suite.

Fixture format (see the header of `tests/parser/parserTests.txt` and
`tests/parser/comments.txt`): blocks delimited by `!!` markers.

```
!! article            ← define a page available to later tests
Template:Foo
!! text
FOO
!! endarticle

!! test               ← one test case
Comment test 2b       ← case name (use a T-number to filter, e.g. "T6400")
!! wikitext           ← input
asdf
<!-- comment 1 -->

jkl
!! html               ← expected HTML output (the "gold")
<p>asdf
</p><p>jkl
</p>
!! end
```

Per-file `!! options` (e.g. `parsoid-compatible=wt2html,wt2wt`, `version=2`)
and per-case options (`pst`, `cat`, `links`, `language=XXX`, `title=[[XXX]]`,
`showflags`, …) tune the mode and what metadata is rendered into the expected
section. **To add a case:** append a new `!! test … !! end` block to the
relevant `.txt` (no PHP), with the wikitext and the exact expected HTML; run
`composer phpunit:config` then `composer phpunit -- --testsuite parsertests
--filter="<name>"`. The standalone `tests/parser/parserTests.php` runner offers
more options (e.g. regenerating expected output) — see `tests/parser/README`.

Other golden-file style checks exist outside the parser suite (e.g. fixtures
under `tests/phpunit/data/` for OutputTransform, ParserCache, messages, schema,
resourceloader). The parser-and-content-transform subsystem deep dive covers the
behavioral side.

## The strict config (what trips newcomers) & coverage expectations

`phpunit.xml.template` runs in a deliberately strict mode — the most common
"my assertions pass but the test fails" surprises come from here:

- **`forceCoversAnnotation="true"`** — every test **must** declare `@covers`
  (or `@coversNothing`). A test with neither is treated as *risky* and, with
  `failOnRisky="true"`, **fails**. This is enforced for real, not advisory.
- **`failOnRisky="true"`** + **`beStrictAboutTestsThatDoNotTestAnything="true"`**
  — a test that makes no assertions fails.
- **`failOnWarning="true"`** — any PHPUnit warning is a failure.
- **`convert{Deprecations,Errors,Notices,Warnings}ToExceptions="true"`** — a PHP
  deprecation/notice/warning thrown by the code under test becomes an exception
  and fails the test, even if your assertions would have passed. Calling a
  deprecated MW API in a test is therefore a hard error.
- **`beStrictAboutOutputDuringTests="true"`** — any stray `echo`/`print`/header
  output fails the test (config also forces stderr-only to dodge "headers
  already sent").
- A **slow-test detector** (`Ergebnis\PHPUnit\SlowTestDetector`) flags tests
  over 100 ms; `@group medium` / `@group large` annotate intentionally slower
  tests.

Coverage: `composer phpunit:coverage` runs the unit suite with coverage
(`--exclude-group Dump,Broken`); `phpunit:coverage-edit` rewrites the config to
narrow the covered paths. The `coverage` block in the template scopes coverage
to `includes/`, `languages/`, `maintenance/` (and extensions/skins), excluding
generated data dirs. There is **no global line-coverage gate** in core's PHPUnit
config (`includeUncoveredFiles="false"`); the *Jest* side does enforce
per-module thresholds (`jest.config.js coverageThreshold`, e.g.
`mediawiki.special.block` ≥ 60% statements). *Inference:* core's expectation is
"cover the behavior you changed," judged in review, rather than a hard repo-wide
percentage — confirm the current Gerrit norm (open question).

## Flaky tests & the Broken group

- **`@group Broken` is excluded by default** (`<groups><exclude>` in the
  template). Tag a test you know is failing-but-shouldn't-block as `@group
  Broken` to keep the suite green while a fix is pending — but that hides it, so
  it needs a follow-up task, not permanent residence.
- **Selenium retries flakes**: `tests/selenium/wdio.conf.js` sets
  `mochaOpts.retries: 1`, acknowledging browser e2e is the flakiest tier;
  screenshots-on-failure are on by default. Strategy: keep logic in lower tiers
  and reserve Selenium for genuine end-to-end journeys.
- Other excludable groups appear in scripts (e.g. `Dump` excluded from
  coverage); `@group Database` is the inverse — an *opt-in* that pulls a test
  into the (slower, isolated) DB lane.

## Writing a new test (the house style) & the bar before merge

House style:

1. **Default to a unit test.** Put it in `tests/phpunit/unit/`, extend
   `MediaWikiUnitTestCase`, inject mocks via `setService()`. Only escalate to
   `MediaWikiIntegrationTestCase` (and add `@group Database` *only if* you truly
   need storage) when the code genuinely needs the container or DB.
2. **Add a `@covers`** for every class/method the test exercises (mandatory —
   see strict config). Use `@coversNothing` only for structure-style tests.
3. **Use factories, not hand-rolled fixtures** (`getTestUser`,
   `getExistingTestPage`, `editPage`, …) and **mock all I/O** (`MockHttpTrait`).
4. **Name the file `*Test.php`** (or `StructureTest` will catch that it never
   runs) and mirror the source path under the right `phpunit/` subtree.
5. **Make zero noise** — no deprecations, notices, or stray output, or the
   strict runner fails you.
6. **Mirror the right tier on the front end**: Jest for node-side logic, QUnit
   for `mw.*`-dependent browser code, api-testing for HTTP contracts, Selenium
   for true e2e.
7. For wikitext behavior, **add a parser-test fixture** rather than a PHP test.

The bar before merge (Gerrit +2): a behavioral change is expected to ship with
tests at the **lowest tier that can prove it** — a bug fix with a regression
test, a new method with unit coverage, an API/route change with an api-testing
or structure assertion. CI (Quibble) runs lint + the full PHPUnit suite + JS
suites and must pass; the strict config means coverage of *new* behavior plus a
clean (warning-free, output-free) run is effectively required, not optional. The
precise reviewer expectations and ownership/approval norms live in the code
ownership & review doc (doc 11) — *that doc is the authority on the +2 bar; this
one is the authority on what tests to write.*

## Foundation (links)

- `tests/AGENTS.md` — **read first**: layout, base-class rule, run commands,
  strict-config gotchas. This doc is the strategy layer on top of it.
- Root `AGENTS.md` — generated-file gotchas (`autoload.php`, `phpunit.xml`,
  schema), destructive-DB warning, "no in-repo CI" note.
- `docs/handbook/01-local-development.md` (doc 01) — the run→change→test inner
  loop and environment setup.
- doc 11 (code ownership & review norms) — the merge/+2 bar and `OWNERS.md`.
- Key source: `tests/phpunit/MediaWikiUnitTestCase.php`,
  `tests/phpunit/MediaWikiIntegrationTestCase.php`,
  `tests/phpunit/mocks/`, `tests/phpunit/structure/`,
  `phpunit.xml.template`, `tests/phpunit/generatePHPUnitConfig.php`,
  `tests/jest/jest.config.js`, `tests/selenium/wdio.conf.js`,
  `tests/parser/parserTests.txt`, `tests/parser/README`.
- Subsystem deep dives that detail their own testing:
  `subsystems/parser-and-content-transform.md` (parser tests),
  `subsystems/service-container-and-config.md` (service overrides),
  `subsystems/database-rdbms.md` (DB cloning / temp tables),
  `subsystems/rest-api.md` & `subsystems/action-api.md` (api-testing,
  structure tests),
  `subsystems/output-skins-resourceloader.md` (bundle-size / Resources tests).
