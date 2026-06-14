# languages/ — localisation data & messages

The **data** side of MediaWiki's internationalisation: translatable UI strings,
per-language configuration, and language data tables. The localisation *code* —
`Language`, `LanguageFactory`, `LanguageConverter`, the `LocalisationCache` — is
**not** here; it lives in `includes/Language/` and `includes/Languages/`. This
directory is what that code reads. See `docs/Language.md`.

## Layout

- `i18n/` — translatable UI message strings as JSON, **one file per language code** (`en.json`, `de.json`, … ~500 of them). `en.json` is the source language; `qqq.json` holds the *documentation* for each message key. Feature-grouped subdirs (`codex/`, `exif/`, `interwiki/`, `preferences/`, `userrights/`, `languageconverter/`, `datetime/`, `botpasswords/`, `nontranslatable/`) hold messages for specific areas, each with its own `en.json`/`qqq.json`.
- `messages/` — `MessagesXx.php`, one per language: the language-specific *configuration* that isn't a simple string — `$fallback` (the fallback chain), `$namespaceNames`, `$namespaceAliases`, `$specialPageAliases`, `$magicWords`, `$datePreferences`, `$linkTrail`, etc. `MessagesEn.php` is the base; other files override only what differs.
- `data/` — language data tables: `plurals.xml` (CLDR plural rules) + `plurals-mediawiki.xml` (MW overrides), `LanguageNameSearchData.json`, `first-letters-root.php` (collation first-letters), `grammarTransformations/`.

## Conventions & gotchas

- **Only edit `en.json` (and its `qqq.json`).** Every other `i18n/*.json` is imported from **translatewiki.net** — hand-editing translations will be overwritten. Add a new UI string to `i18n/en.json` and document it in the matching `qqq.json`.
- **Never hard-code UI English** in PHP/JS — add a message key and use `wfMessage()` / `mw.msg()`. The `banana` checker (part of `npm run lint`) enforces that keys exist and are documented in `qqq.json`.
- **Namespace names, magic words, and special-page aliases are localised in `messages/MessagesXx.php`, not in `i18n/`.** That's the split to remember: JSON = interface strings; `Messages*.php` = structural/config localisation.
- `$fallback` defines the chain used for missing messages (e.g. a regional variant falling back to its base language, then to `en`). Leave the line out to accept the default fallback to `en`; never set `$fallback = false` outside `MessagesEn.php`.
- At runtime these files are compiled into the `LocalisationCache` (an `LCStore` backend) for performance — changes may require clearing that cache (`maintenance/run rebuildLocalisationCache`, or it rebuilds in dev) to take effect.
- Authoritative references: `docs/Language.md` and <https://www.mediawiki.org/wiki/Localisation>.
