# resources/ — front-end source

The client-side code MediaWiki ships: the `mediawiki.*` JavaScript/CSS modules,
bundled jQuery plugins, and Vue/Codex components. These are **source files**;
they are served to the browser by ResourceLoader (the back end is
`includes/ResourceLoader/`, the HTTP entry point is `/load.php`). Module
definitions live in `resources/Resources.php`.

## Layout

- `src/` — MediaWiki's own modules, one directory or file per module (e.g. `mediawiki.base`, `mediawiki.api`, `mediawiki.Title`, `mediawiki.action*`). The public front-end API (`mw.*`) is documented in `resources/README.md`.
- `lib/` — third-party libraries vendored for the browser.
- `assets/` — static images/fonts.
- `templates/` — shared HTML templates.
- `Resources.php` — registers every core ResourceLoader module (dependencies, scripts, styles, messages). Adding a front-end module means registering it here.

## Build, test & lint (canonical; needs `npm ci` first — not run in this checkout)

```sh
npm run lint            # eslint (.js/.json/.vue) + stylelint (.css/.less/.vue) + banana (i18n)
npm run jest            # JS unit tests (tests/jest)
npm run qunit           # browser QUnit against resources/ — needs a running wiki + MW_SERVER/MW_SCRIPT_PATH
npm run minify:svg      # optimize SVGs under resources/src and resources/assets
```
Lint config: `eslint-config-wikimedia` (`.eslintrc.json`), `stylelint-config-wikimedia` (`.stylelintrc.json`). The grunt `lint` task chains eslint + banana + stylelint (`Gruntfile.js`).

## Conventions & gotchas

- **Register modules in `Resources.php`** — a file added under `src/` does nothing until it's declared as (part of) a module there.
- **Styles**: LESS is the norm (`.less`); `cssjanus` handles LTR/RTL flipping automatically — author for LTR.
- **i18n in JS**: use `mw.msg`/`mw.message` with keys defined in `languages/i18n/`; the `banana` checker validates message files.
- **Vue/Codex**: Vue 3 + the Codex design system (`@wikimedia/codex`). Local Codex development against a clone is supported via `$wgCodexDevelopmentDir` (see `DEVELOPERS.md`).
- **Bundle size is enforced** — `bundlesize.config.json` plus `tests/phpunit/structure/BundleSizeTest`; large additions can fail the build.
- QUnit/Selenium need a real running wiki (they drive a browser against `MW_SERVER`), so they can't run from a bare source checkout.
