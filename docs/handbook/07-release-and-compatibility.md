# Release, Upgrade & Backward Compatibility

> Scope: how MediaWiki core is **versioned**, **released**, and how it keeps
> **backward compatibility** across releases — plus the concrete **upgrade**
> steps an operator runs and the **migration** work an extension developer does
> across a release. This is the part people skip and the part that causes
> incidents, so it is deliberately concrete.
>
> This doc owns *versioning, the release process, the deprecation
> timeline/policy, and upgrade*. It does **not** re-describe the *API surface or
> stability signaling itself* — that is owned by the Public API doc (`05`, see
> Foundation). Schema-migration mechanics are owned by the data-model doc (`04`)
> and the [Database (Rdbms) subsystem](subsystems/database-rdbms.md); this doc
> only covers the operator-facing `update` step and the compatibility *contract*
> around schema.
>
> Two consumers, two realities — keep them separate in your head throughout:
> - **Wikimedia (WMF)**: deploys ~`master` continuously via the weekly *train*.
> - **Third-party operators**: install cut releases (tarballs / `REL1_xx`).

---

## Versioning scheme (and why "1." is vestigial)

The current version is defined in one place:

```php
// includes/Defines.php
define( 'MW_VERSION', '1.47.0-alpha' );
```

The format is `1.MAJOR.MINOR[-suffix]`:

- **The leading `1.` is vestigial.** It has not been bumped to `2.` and there is
  no plan that this doc can verify to do so. Treat it as a constant prefix.
- **`MAJOR`** (the `47` in `1.47`) is the number that actually moves between
  feature releases. **Each `MAJOR` bump — e.g. `1.46` → `1.47` — is effectively a
  major release in semver terms**: breaking changes *are* allowed, but only
  through the deprecation policy (deprecate first, remove later). Every
  `RELEASE-NOTES-1.xx` file has both a `=== Breaking changes ===` and a
  `=== Deprecations ===` section precisely because this is where the contract
  changes (verified in `RELEASE-NOTES-1.47`, lines 168 and 212).
- **`MINOR`** (the trailing `.0`, `.1`, …) is the patch/point release within a
  branch — security and bug fixes only, no breaking changes. Tag history
  confirms this cadence: `1.43.0` … `1.43.8`, `1.44.0` … `1.44.5`,
  `1.45.0` … `1.45.3` (verified via `git tag`).

Suffixes seen in this repo (verified):

| Suffix | Meaning | Where seen |
|---|---|---|
| `-alpha` | unreleased development branch (current `master`) | `MW_VERSION = '1.47.0-alpha'` |
| `-rc.0` | release candidate before a `.0` | tags `1.45.0-rc.0`, `1.46.0-rc.0` |
| `-wmf.N` | a WMF *train* build cut from ~master | branches `wmf/1.44.0-wmf.21`, … |
| `-PRERELEASE` | header marker in an unreleased RELEASE-NOTES file | `RELEASE-NOTES-1.47` line 7 |

So the same `1.47` line passes through, roughly:
`1.47.0-alpha` (dev) → many `1.47.0-wmf.N` train builds (WMF) →
`1.47.0-rc.0` → `1.47.0` (first cut release) → `1.47.1`, `1.47.2`, …
(point releases on the `REL1_47` branch).

---

## Two release models: WMF train vs cut releases / LTS

MediaWiki core serves two audiences with **different release vehicles from the
same git history**.

### 1. WMF "train" — continuous deployment of ~master

- WMF runs **very close to `master`**. Roughly weekly, a build is cut and rolled
  out across the Wikimedia fleet — the "train."
- These builds live on `wmf/1.XX.0-wmf.N` branches. This repo contains dozens of
  them (e.g. `wmf/1.43.0-wmf.10` … `wmf/1.43.0-wmf.28`,
  `wmf/1.44.0-wmf.1` … `wmf/1.44.0-wmf.21`; verified via `git branch -a`).
- Implication for you: **a change merged to `master` is in production within
  ~a week at Wikipedia scale**, long before any third-party tarball exists. A
  regression's blast radius is "all of Wikimedia," fast. This is why
  performance-at-scale and backward compatibility are first-class even for
  "internal" code.

### 2. Cut releases + LTS — for third parties

- Third-party operators install **cut releases**: signed tarballs from
  <https://releases.wikimedia.org/mediawiki/> (cited in `UPGRADE`), or check out
  a stable `REL1_xx` branch.
- Each feature line has a release branch: `REL1_40` … `REL1_46` exist as remote
  branches in this repo (verified). `master` is `1.47.0-alpha`; `REL1_46` is the
  most recent stable line.
- **LTS (Long Term Support):** some releases are designated LTS with a longer
  support window. *(Inferred from `UPGRADE`: it speaks of "the oldest supported
  upgrading version" and "older than two LTS release[s]" — see Upgrade section.
  The exact LTS cadence and which specific releases are LTS is policy maintained
  on mediawiki.org, not encoded in this repo — see open questions.)*
- **Support window, verifiable fact:** `UPGRADE` states that upgrading from a
  version older than **two LTS releases** is unsupported, and that **any upgrade
  from a version older than 1.39 will fail** today. So 1.39 is the current floor.

### Same code, two truths

| Aspect | WMF train | Third-party cut release |
|---|---|---|
| What runs | ~`master`, weekly `-wmf.N` | tagged `1.XX.Y` / `REL1_XX` |
| Cadence | weekly | feature releases ~quarterly-ish; point releases as needed |
| Upgrade mechanic | automated deploy tooling (Wikimedia infra) | manual: replace files + run `update` |
| Schema migrations | run as part of deploy automation | operator runs `maintenance/run update` |
| Tolerance for churn | high (fast follow-up) | low (months between upgrades) |

When you read "breaking change," remember it lands on WMF in a week but a
third-party operator may not see it for a year and will jump *several* breaking
changes at once. That gap is the whole reason the deprecation policy exists.

---

## The release process (high level)

There is **no in-repo CI/release workflow** (confirmed: no release YAML in the
tree). Release management happens on **Wikimedia infrastructure** by the Release
Engineering team; the repo only carries the *inputs* to that process. What is
verifiable from the repo:

1. **Branching.** A feature line is cut to a `REL1_XX` branch off `master`;
   `master` then advances to the next `-alpha` (currently `1.47.0-alpha`).
   `.gitreview` pins the canonical project: Gerrit
   `gerrit.wikimedia.org`, project `mediawiki/core.git` — **review is on
   Gerrit, not GitHub PRs**.
2. **Release candidates.** `-rc.0` tags precede each `.0` (e.g. `1.46.0-rc.0`).
3. **Tagging.** Final releases are annotated git tags `1.XX.Y` (492 tags exist
   in this repo). Point releases (`1.XX.1`, `1.XX.2`, …) are tagged off the
   `REL1_XX` branch.
4. **Tarballs, signed.** Releases are published as compressed tar archives at
   <https://releases.wikimedia.org/mediawiki/>. (Signing/GPG verification is part
   of the published release process on mediawiki.org; the `mediawiki-announce`
   list — see `RELEASE-NOTES` "Mailing list" — is the official channel for
   security-fix notifications.)
5. **Bundled dependencies are vendored at release.** `composer.json` pins exact
   versions of bundled libraries (e.g. `guzzlehttp/guzzle: 7.10.0`,
   `wikimedia/parsoid: 0.24.0-a8`, `oojs/oojs-ui: 0.54.0`); a release tarball
   ships `vendor/` so operators don't need Composer. Note `composer.json`
   `replace` declares core *provides* certain polyfills (e.g.
   `symfony/polyfill-mbstring: 1.99`, `symfony/polyfill-php80/81: 1.99`) so they
   are never installed — core already targets a PHP new enough to make them
   no-ops.

> WMF train builds (`-wmf.N`) are produced by the same Release Engineering
> tooling but are deploy artifacts, not public downloads.

---

## Changelog conventions (RELEASE-NOTES-x.xx)

**`RELEASE-NOTES-1.xx` *is* the changelog.** There is one file per feature line,
hand-maintained as changes land on `master`. When a line ages out, its notes are
folded into the giant `HISTORY` file ("For notes on 1.46.x and older releases,
see HISTORY," `RELEASE-NOTES-1.47` line 24). `HISTORY` is ~1.8 MB — do not read
it wholesale.

The section structure is **stable across releases** (verified identical between
`RELEASE-NOTES-1.46` and `-1.47`). In order:

- `== Upgrading notes for 1.XX ==` — release-specific upgrade caveats; always
  leads with "back up your database."
- `=== Configuration changes for system administrators ===` with
  `New / Changed / Removed configuration` subsections — **the `$wg*` contract
  delta.**
- `=== New user-facing features ===`, `=== New features for sysadmins ===`,
  `=== New developer features ===`.
- `=== External library changes ===` — `New / Changed / Removed` for both
  runtime and dev-only bundled libs (this is the bundled-dependency delta).
- `=== Bug fixes ===`.
- **`=== Action API changes ===`** and `=== Action API internal changes ===` —
  the **on-the-wire** Action API delta (e.g. 1.47: "php response format has been
  removed"). This is its own section *because the wire contract is a separate,
  stricter promise than PHP* (see next section).
- `=== Languages updated ===`.
- **`=== Breaking changes ===`** — things actually removed/changed-incompatibly
  this release. Each entry names what was removed, what to use instead, and the
  release it was deprecated in (e.g. "`IDatabase::lockIsFree`, deprecated in
  1.46, was removed").
- **`=== Deprecations ===`** — what is *newly* deprecated this release (soft or
  hard), with the replacement. This is the "remove me in a future release" queue.
- `== Compatibility ==` — required PHP version + extensions, and supported DB
  engines/versions.

**Convention to internalize:** a removal in release *N*'s Breaking-changes
section should trace back to a deprecation entry in some earlier release *N-k*'s
Deprecations section. That paper trail *is* the deprecation policy in action.
When you remove something, you edit `=== Breaking changes ===` and cite the
deprecating release; when you deprecate something, you add to `=== Deprecations
===` and name the replacement.

---

## Backward-compatibility guarantees (PHP @stable / API / DB / config)

MediaWiki makes **different promises to different consumers**. Know which surface
you are touching.

### 1. PHP code — the `@stable` / `@internal` contract

Stability is signaled by docblock annotations, not by visibility alone. The
Public API doc (`05`) owns the full taxonomy; what matters *here* is that
**these annotations define what the deprecation policy must protect.** Verified
usage counts across `includes/` (via grep):

| Annotation | Count | Promise to extensions |
|---|---|---|
| `@internal` | ~1061 | **No promise.** May change without deprecation. Do not use. |
| `@stable to override` | ~869 | You may override the method; signature is stable. |
| `@stable to implement` | ~594 | You may implement this interface; it won't gain methods without a cycle. |
| `@newable` | ~176 | You may `new` this class directly. |
| `@stable to extend` | ~174 | You may subclass. |
| `@stable to call` | ~174 | You may call it. |

The default for unannotated classes is **closed** — extending/implementing is
*not* guaranteed safe unless marked stable. Changing or removing anything marked
`@stable to *` requires the deprecation cycle below; changing `@internal` does
not.

### 2. Action / REST API — the on-the-wire contract

The HTTP-level contract (request params, response shape, formats) is a
**separate, stricter promise** tracked in its own changelog section
(`=== Action API changes ===`). Clients can't be recompiled, so wire changes are
done carefully and announced. Example removal in 1.47: the `php` response format
was dropped (clients must move to `json`). See the
[Action API](subsystems/action-api.md) and [REST API](subsystems/rest-api.md)
subsystem docs for how stability is signaled per-endpoint, and the Public API
doc (`05`) for the surface taxonomy.

### 3. Database schema — covered by migrations, not frozen

The schema is **not** promised stable, but **transitions are**: every schema
change ships with an updater entry so `maintenance/run update` can migrate an
existing wiki in place. The mechanics (abstract `sql/tables.json` → generated
per-DB SQL; `getCoreUpdateList()` in `includes/installer/DatabaseUpdater.php`;
idempotency via the `updatelog` table) are owned by doc `04` and the
[Database (Rdbms) subsystem](subsystems/database-rdbms.md). The *guarantee* you
rely on here: **an operator who runs `update` after upgrading files ends up with
a correct schema**, and reruns are safe (`updateRowExists()` /
`insertUpdateRow()` make each step run at most once).

### 4. Configuration — `$wg*` defaults and the schema

Config defaults live in `includes/MainConfigSchema.php`. The guarantee is
"reasonable behavior on upgrade with an unchanged `LocalSettings.php`," but
**defaults can change between feature releases** and *that is a compatibility
event*. Every such change is recorded in the
`=== Configuration changes ===` section. Real example from `RELEASE-NOTES-1.47`:
`$wgGroupPermissions['*']['autocreateaccount']` now defaults to `true` — the
note explicitly tells operators how to restore the old behavior. Renamed config
is also possible across releases (`UPGRADE` cites
`$wgDisableUploads` → `$wgEnableUploads`). **Read the config section of the
release notes before every upgrade.**

---

## Deprecation policy & timelines

The repo enforces deprecation *mechanically*; the formal *policy text* (exact
number of releases, hard vs soft rules) lives on mediawiki.org (the "Stable
interface policy" / "Deprecation policy"). Below: what is verifiable in-repo vs
what is policy-on-the-wiki.

### Soft vs hard deprecation (verifiable mechanics)

`wfDeprecated()` is a **god node** in this codebase (the graph report records
~251 edges into it — it is one of the most-called helpers in core). It and
`wfDeprecatedMsg()` route to `MWDebug::deprecated()`:

```php
// includes/GlobalFunctions.php
function wfDeprecated( $function, $version = false, $component = false, $callerOffset = 2 ) { ... }
// includes/Debug/MWDebug.php → "Use of $function was deprecated in $component $version."
```

- **Soft deprecation:** add `@deprecated since 1.XX` to the docblock and name the
  replacement, but do **not** call `wfDeprecated()` yet. No runtime warning;
  signals intent and starts the clock. (Many `=== Deprecations ===` entries are
  soft — "deprecated" with no warning mentioned.)
- **Hard deprecation:** call `wfDeprecated()` / `wfDeprecatedMsg()` (or, for
  overridden methods, `MWDebug::detectDeprecatedOverride()`), so callers get a
  **runtime deprecation warning**. Release notes phrase these as "deprecated and
  **will trigger deprecation warnings**" (e.g. `Title::canUseNoindex()`,
  `PatrolLog::record`, `$wgLang` in `RELEASE-NOTES-1.47`).
- **Removal:** after the deprecation period, the symbol moves to the
  `=== Breaking changes ===` section, citing the release it was deprecated in.

### The "deprecate for N releases, then remove" norm

The norm visible in the notes is "**hard-deprecate, wait at least one feature
release, then remove**." Verified examples in `RELEASE-NOTES-1.47` Breaking
changes:

- `IDatabase::lockIsFree` — deprecated 1.46, removed 1.47 (one release).
- `FeedUtils::checkFeedOutput` null arg — deprecated 1.46, removed 1.47.
- `ResourceLoader::makeConfigSetScript` — deprecated 1.44, removed 1.47.
- `BaseSearchResultSet::next()/rewind()` — deprecated since **1.32**, removed
  1.47 (long-lived deprecations are common; the minimum is one cycle, but things
  often linger much longer).

> *Inference:* the practical minimum is one feature release between hard
> deprecation and removal, but the exact required minimum and the soft-vs-hard
> sequencing rules are governed by the mediawiki.org Stable interface policy, not
> by anything in this checkout. Treat the wiki policy as authoritative.

### Controlling deprecation noise (operator/dev knobs)

From `includes/MainConfigSchema.php` (verified):

- **`$wgDevelopmentWarnings`** (default `false`) — when `true`, MediaWiki throws
  notices for deprecated functions and possible error conditions. Turn on in
  development/CI to surface deprecations.
- **`$wgDeprecationReleaseLimit`** (default `false`) — set to a release number to
  *suppress* deprecation warnings introduced after that release. Lets a wiki
  upgrade incrementally without drowning in warnings for newly-deprecated APIs.
- `$function`/`$version`/`$component` args on `wfDeprecated()` feed these knobs
  (the component+version are what `$wgDeprecationReleaseLimit` filters on).

Deprecation warnings are emitted **once per unique caller** (dedup in `MWDebug`),
so they identify the offending call site without flooding logs.

---

## Feature flags & rollout

MediaWiki has no dedicated feature-flag framework; **`$wg*` config variables in
`MainConfigSchema.php` are the feature-flag mechanism.** Patterns:

- **`$wgEnable*` / boolean toggles** gate features (e.g. the `$wgUseLeximorph`
  flag in `RELEASE-NOTES-1.47` New developer features — when enabled, new modular
  language handlers replace the legacy implementations; off by default, so the
  feature ships dark and is opt-in).
- **Temporary flags** exist to stage a migration and are removed once complete.
  Verified: `$wgThumbnailStepsRatio` is described in `RELEASE-NOTES-1.47` as "a
  temporary config" that **has been removed** — the canonical lifecycle of a
  rollout flag (introduce default-off → flip default → remove flag).
- **Default flips are compatibility events**, recorded under
  `=== Changed configuration ===` (see the `autocreateaccount` example above).

**Rollout reality differs by consumer:** WMF can introduce a flag, enable it on a
few wikis via per-wiki config, watch, and roll forward across the train within
weeks. Third-party operators get the flag's *default* in a cut release and flip
it by hand in `LocalSettings.php`. A feature that is "rolled out" at WMF may
still be default-off in the tarball.

---

## Upgrading (operators) & migration guidance (extension devs)

### Operator upgrade — the verified steps (from `UPGRADE`)

Documented in `UPGRADE`; commands are **documented-not-run** (no PHP toolchain in
this checkout):

1. **Consult the release notes first.** Read `RELEASE-NOTES-1.XX`, especially the
   `Upgrading notes`, `Configuration changes`, and `Breaking changes` sections.
2. **Back up the database and files — and verify the backup.** `UPGRADE` is
   emphatic: schema upgrades can leave the DB inconsistent if they fail.
3. **Replace the files.** Download the new tarball (or check out `REL1_XX`).
   **Preserve** `LocalSettings.php`, the `extensions/` and `images/` directories,
   and any custom upload dir / deleted-file archive / custom skins.
4. **Run the database upgrade.** Either:
   - Web: browse to `./mw-config/index.php` and follow the script; or
   - **CLI (preferred for servers):** `php maintenance/run.php update`
     (class `UpdateMediaWiki` in `maintenance/update.php`). It inserts missing
     tables, updates existing ones, and moves data as needed. It is idempotent
     (tracked via the `updatelog` table), so it is safe to re-run.
   - To split schema DDL from data changes (for least-privilege DB accounts),
     use `--schema` / `--noschema` plus `$wgAllowSchemaUpdates`.
5. **Check configuration settings.** Reconcile `$wg*` renames/default changes
   against the release notes (the `$wgDisableUploads`→`$wgEnableUploads` style of
   change).
6. **Upgrade extensions in lockstep.** "Extensions usually need to be upgraded at
   the same time as the MediaWiki core" — match the extension to the core
   release line.
7. **Test.** Page views, edits, special pages, and each extension.

**Supported upgrade range (verified):** upgrades from versions older than **1.39
will fail**, and jumping more than **two LTS releases** is unsupported — upgrade
to an intermediate LTS first, then to the target. The WMF fleet never does this
(it is always ~master); this section is purely third-party reality.

### Extension-developer migration across a release

When you maintain an extension and core moves `1.46` → `1.47`:

1. **Read the new `=== Deprecations ===` and `=== Breaking changes ===`
   sections.** They are your migration checklist; each entry names the
   replacement.
2. **Turn on `$wgDevelopmentWarnings`** in your test/CI wiki so hard-deprecated
   calls surface as warnings, and fix them while the old symbol still exists.
3. **Migrate before the removal release**, not after. A symbol hard-deprecated in
   1.47 is liable to vanish in 1.48; the deprecation window is your grace period,
   not a permanent state.
4. **Respect the stability annotations** — if you extend/implement something not
   marked `@stable to *`, you have no compatibility promise and core may break
   you without a deprecation entry. Conversely, anything `@internal` you depend
   on is on you.
5. **Replace removed hooks/services with the named successor** (e.g. 1.47:
   `EditFilter` → `EditFilterMergedContent`/`MultiContentSave`;
   `ParserOptionsRegister` → `ParserOptionsDefaults`). See
   [Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md).
6. **Pin your extension to a core release line** (`REL1_XX`) for third-party
   users; track `master` separately if you want to ride the WMF train.

---

## Foundation (links)

This doc builds on, and should be read alongside:

- **Root `AGENTS.md` / `CLAUDE.md`** — conventions: deprecation via
  `@deprecated` + `wfDeprecated()`; `@stable` markers define the contract;
  commit footer `Bug: T12345`; review on **Gerrit**; tasks on **Phabricator**;
  "no in-repo CI/release workflow."
- **`includes/AGENTS.md`** — the PHP core layout these guarantees protect.
- **Handbook `02` Architecture** (`docs/handbook/02-architecture.md`) and
  **`01` Local Development** (`docs/handbook/01-local-development.md`).
- **Public API doc (`05`)** — *owns* the API surface and stability-signaling
  taxonomy (`@stable`, `@internal`, `@newable`, `@deprecated`). This doc covers
  versioning/release/deprecation-timeline/upgrade; cross-reference, don't
  duplicate.
- **Data model & schema doc (`04`)** plus the
  [Database (Rdbms) subsystem](subsystems/database-rdbms.md) — *own* schema
  evolution mechanics (`sql/tables.json`, generated SQL, `DatabaseUpdater`,
  `updatelog`). This doc only covers the operator `update` step and the
  schema-migration *guarantee*.
- Subsystem deep-dives most relevant to the wire/extension contract:
  [Action API](subsystems/action-api.md),
  [REST API](subsystems/rest-api.md),
  [Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md),
  [Service Container & Configuration](subsystems/service-container-and-config.md).
- **In-repo source of truth:** `RELEASE-NOTES-1.46`, `RELEASE-NOTES-1.47`
  (changelogs), `UPGRADE`, `HISTORY` (archived notes — large, grep don't read),
  `includes/Defines.php` (`MW_VERSION`), `composer.json` (PHP/platform reqs,
  bundled-lib pins, `replace`), `includes/MainConfigSchema.php`
  (`$wgDevelopmentWarnings`, `$wgDeprecationReleaseLimit`, config defaults),
  `includes/GlobalFunctions.php` + `includes/Debug/MWDebug.php`
  (`wfDeprecated()`), `maintenance/update.php` +
  `includes/installer/DatabaseUpdater.php` (the upgrade step), `.gitreview`
  (Gerrit project + branch policy).
- **Authoritative off-repo policy:** the Stable interface / Deprecation policy
  and the LTS schedule live on **mediawiki.org** — they are *not* encoded in this
  checkout. Defer to the wiki for exact timelines and LTS designations.

---

### Open questions / genuine unknowns

- **Exact deprecation timeline.** The repo proves a "≥1 feature release" norm by
  example but not the formal minimum or the soft→hard sequencing rules; those are
  on mediawiki.org's Stable interface policy.
- **LTS cadence and designations.** `UPGRADE` references "two LTS releases" and a
  1.39 floor, but which specific releases are LTS and the support-window lengths
  are policy on mediawiki.org, not in the tree.
- **Release signing specifics.** Tarball GPG signing/verification is part of the
  published release process; no signing artifact or key policy is in this repo.
- **Train scheduling/automation.** The `-wmf.N` branches confirm a weekly-ish
  train, but the cutting cadence, rollback, and deploy tooling live on Wikimedia
  infra (Release Engineering), outside this repo.
