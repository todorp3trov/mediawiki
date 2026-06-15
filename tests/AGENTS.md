# tests/ — MediaWiki test suites

Tests for MediaWiki core, spanning PHP and the front end. Test base classes and
helpers live in `tests/phpunit/`; the JS/browser suites have their own dirs.

> **WARNING:** PHPUnit *integration* tests can alter or wipe your local
> database. Never run tests against a production wiki or any data you care about
> (`tests/phpunit/README.md`).

## Layout

- `phpunit/` — PHP tests. Base classes at the top level:
  - `MediaWikiUnitTestCase` — **pure unit tests**, no DB, no services, no globals. Source lives in `phpunit/unit/`.
  - `MediaWikiIntegrationTestCase` — **integration tests** with DB + service container. Source in `phpunit/integration/` and `phpunit/includes/`.
  - `phpunit/structure/` — repo-invariant tests (autoloader correctness, `extension.json` validity, hook registration, generated SQL up-to-date, bundle size, resources). These catch the "I forgot to regenerate X" class of mistakes.
  - `phpunit/maintenance/`, `phpunit/documentation/`, `phpunit/mocks/`, `phpunit/data/` — maintenance-script tests, doc tests, shared mocks, fixtures.
- `jest/` — JS unit tests (`npm run jest`; config `tests/jest/jest.config.js`).
- `qunit/` — browser QUnit tests for `resources/` modules (`npm run qunit`).
- `selenium/` — WebDriverIO end-to-end tests (`npm run selenium-test`).
- `api-testing/` — black-box REST/Action API tests over HTTP (`npm run api-testing`).
- `parser/` — wikitext parser test fixtures (`.txt` cases), run via PHPUnit.
- `phan/`, `Common/` — static-analysis fixtures and shared PHP test utilities.

## Running tests (canonical; not executed in this checkout — no PHP toolchain present)

PHPUnit is configured from a generated `phpunit.xml`; **generate it first**:
```sh
composer phpunit:config                 # writes phpunit.xml from phpunit.xml.template
composer phpunit:unit                   # all DB-less unit tests (testsuite core:unit)
composer phpunit                        # full suite
# single file/dir (run from tests/phpunit, per DEVELOPERS.md):
#   cd tests/phpunit && composer phpunit -- path/to/MyTest.php
```
Named testsuites (from `phpunit.xml.template`): `core:unit`, `includes`,
`structure`, `integration`, `maintenance_suite`, `parsertests`, `docs`.

JS / browser:
```sh
npm run jest            # JS unit
npm run qunit           # QUnit — needs a running wiki + MW_SERVER & MW_SCRIPT_PATH env
npm run selenium-test   # Selenium — needs a running wiki
npm run api-testing     # API tests — needs a running wiki + .api-testing.config.json
```

## Conventions & gotchas

- **Pick the right base class.** If a test needs the DB or services it must extend `MediaWikiIntegrationTestCase`; otherwise prefer `MediaWikiUnitTestCase` (much faster, enforces decoupling). Putting DB-dependent code in a unit test will fail.
- **`@covers` is mandatory** — `forceCoversAnnotation="true"` in the config; a test with no `@covers` is treated as risky and fails.
- The config is **strict**: `failOnWarning`, `failOnRisky`, deprecations/notices/warnings convert to exceptions, and output during tests is disallowed. Code that emits a PHP notice or stray output will fail tests even if assertions pass.
- The `Broken` group is excluded by default; mark known-broken tests `@group Broken`.
- Test style differs from production: `.phpcs.xml` relaxes several sniffs under `tests/` (line length, silenced errors, assignment-in-return).
