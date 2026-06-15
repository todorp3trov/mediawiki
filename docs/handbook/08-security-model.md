# Security Model

> Part of the MediaWiki core senior-onboarding handbook. This is the **defensive**
> security overview: it describes how the engine *protects itself* so that a new
> senior engineer knows which guardrails exist, where the trust boundaries are,
> and which rules must never be broken when adding code. It is **not** an attack
> guide and deliberately does not enumerate exploits or bypass steps.
>
> This document is the **map**; the mechanisms live in the subsystem deep-dives,
> which are the authorities for their areas — this page links to them rather than
> duplicating them:
> - Authn/authz/sessions/blocks/CSRF tokens →
>   `docs/handbook/subsystems/auth-permissions-sessions.md`
> - HTML sanitization / the XSS boundary →
>   `docs/handbook/subsystems/parser-and-content-transform.md`
> - SQL-injection prevention (query builders) →
>   `docs/handbook/subsystems/database-rdbms.md`
> - Upload trust boundary →
>   `docs/handbook/subsystems/files-media-uploads.md`
>
> Foundation: root `AGENTS.md`, `includes/AGENTS.md`, the graph report at
> `graphify-out/GRAPH_REPORT.md`. MW_VERSION at time of writing: **1.47.0-alpha**;
> PHP ≥ 8.3.
>
> **No in-repo `SECURITY.md`.** MediaWiki's security policy and reporting process
> live on mediawiki.org ("Reporting security bugs"); private reports go to
> `security@wikimedia.org` and the Phabricator `Security` project. See the last
> section. Code review is on Gerrit, tasks on Phabricator.

---

## Trust boundaries (what's trusted vs not, and where untrusted input crosses in)

MediaWiki runs **untrusted, user-supplied content for anonymous editors at the
scale of Wikipedia**. That single fact shapes the whole model: almost everything
that arrives from the network is hostile until a specific control has cleansed or
constrained it. The defensive posture is **defense in depth** — multiple
independent layers, each of which assumes the others might fail.

**Untrusted (must be validated/escaped/authorized before it does anything):**

- **Page content / wikitext** — the single largest untrusted surface. Anonymous
  and temporary users can edit. Wikitext becomes HTML only through the parser,
  whose `Sanitizer` is the XSS boundary (see parser doc).
- **Uploaded files** — bytes *and* metadata are attacker-controlled. The upload
  pipeline (`includes/Upload/`) is a dedicated trust boundary (see files doc).
- **All web-request input** — query string, POST body, cookies, headers, and
  request-carried identity. Cookies asserting "I am user X" are *unverified* until
  the session store corroborates them (see auth doc, "Corroborate, don't trust").
- **API parameters** — Action API (`api.php`) and REST API (`rest.php`) inputs are
  request data; they cross in through `ParamValidator`.
- **Partly: on-wiki `MediaWiki:` namespace messages and certain config-like
  on-wiki pages** — these are editable by privileged users and can contain HTML or
  influence rendering, so they are *lower* trust than source code but *higher*
  trust than anonymous wikitext. Treat interface messages that allow raw HTML with
  the same care as code.

**Trusted (the TCB — trusted computing base):**

- PHP source in the repo and bundled Composer/npm libraries (subject to
  supply-chain controls, below).
- `LocalSettings.php` and operator-supplied secrets (`$wgSecretKey`, etc.).
- Server-side configuration in `MainConfigSchema.php` / `MainConfigNames.php`.

**Where untrusted input crosses in — and the control at each crossing:**

| Crossing point | Untrusted input | Primary control | Authority doc |
|---|---|---|---|
| Web view / edit save | wikitext → HTML | `Sanitizer` (in the parser) + `Html`/`OutputPage` escaping | parser doc |
| Any DB query built from input | strings/ids | Rdbms query builders that quote/escape | rdbms doc |
| `api.php` / `rest.php` | request params | `ParamValidator` type/range/format validation | this doc + rest/action-api docs |
| State-changing request | forged cross-site POST | CSRF / edit token (`CsrfTokenSet`) | auth doc |
| File upload | bytes + filename + MIME | `UploadBase` / `UploadVerification` | files doc |
| Request → identity | cookies/tokens/headers | session store corroboration in `SessionManager` | auth doc |
| Shelling out to a converter | command arguments | `Shell`/`BoxedCommand` arg-array escaping + sandbox | this doc |

The rest of this document walks the controls. For authentication, authorization,
and CSRF the **mechanism** is owned by the auth subsystem doc; this page
summarizes and points there.

---

## Authentication (how identity is established) → see auth subsystem

Authoritative source:
`docs/handbook/subsystems/auth-permissions-sessions.md` ("the security spine").
Summary of the controls a security-minded engineer must know:

- **Identity comes from a verified `Session`, not from the request directly.**
  `includes/Session/SessionManager.php` turns cookies/tokens/headers into a
  `Session`, but only after the **session store corroborates** the asserted
  user-id, user-name, and user-token. Mismatches degrade to anonymous;
  `SessionBackend` refuses to construct a session for an unverified user. This is
  invariant #1 in the auth doc: *corroborate, don't trust*.
- **`AuthManager` (`includes/Auth/AuthManager.php`)** runs the pluggable
  Pre → Primary → Secondary login pipeline (throttle/captcha → credential check →
  2FA / block-check / forced reset). Per-flow state lives in the session and is
  re-validated mid-flow so a config/hook change fails safe.
- **Account-existence non-leak:** the local password provider returns the *same*
  failure for "no such user" as for "wrong password" (T134100).
- **Re-authentication for sensitive operations:**
  `securitySensitiveOperationStatus()` gates actions like changing email behind a
  recent *interactive* login; a stolen session does not count.
- **Sessions narrow rights, never widen them** (OAuth / bot-password sessions are
  `array_intersect`ed with the account's rights).

Do not roll your own login UI against `AuthManager` directly — its own docblock
warns that doing so "will very likely end up in security vulnerabilities."
Subclass `AuthManagerSpecialPage` or use the `clientlogin` / `createaccount` API
(auth doc, "Extension / customization points").

---

## Authorization (how access is enforced & where) → see auth subsystem

Authoritative source:
`docs/handbook/subsystems/auth-permissions-sessions.md` (Flow A + the
permission-check vocabulary table). Summary:

- **The modern access object is `Authority`** (`includes/Permissions/Authority.php`),
  obtained from `RequestContext::getAuthority()` or injected. New code asks
  `Authority`, **never** `User->isAllowed()` and never trusts request-supplied
  identity without the session corroborating it.
- **The check vocabulary is a deliberate cost/rigor ladder:**
  `isAllowed` / `probablyCan` (UI decisions, cheap, may false-positive) →
  `definitelyCan` / `isDefinitelyAllowed` (thorough, blocks-aware, no side effect)
  → `authorizeRead` / `authorizeWrite` (immediately before acting; consult blocks
  *and* consume the rate limit). **`authorizeWrite` uses `RIGOR_SECURE`, which
  reads the primary DB** so a fresh block or protection change cannot be missed due
  to replication lag.
- **Where it is enforced:** the consuming subsystems must call into the auth layer
  before acting — `actions-special-pages-editing` (edit save), `action-api`,
  `rest-api`. The auth layer itself does not call them.
- **Blocks** are evaluated by `BlockManager` and consulted on every gated action;
  partial blocks, autoblocks, IP/range/system blocks, and `$wgBlockDisablesLogin`
  are all handled there.

The load-bearing rule for new code (gotchas, below): **authorize via `Authority`
immediately before a write, using `authorizeWrite` — never gate a write on
`probablyCan`/`isAllowed`.**

---

## Secrets management

MediaWiki has **no in-repo secrets vault**. Secrets are *operator-supplied
configuration* in `LocalSettings.php` (which is git-ignored). Core's job is to use
them correctly and to fail safe when they are absent.

Verified in `includes/MainConfigSchema.php`:

- **`$wgSecretKey`** (`MainConfigSchema::SecretKey`, default `false`) — the
  site-wide HMAC secret. Used to sign tokens and **block cookies** (a tampered
  block cookie is ignored; without a secret key the raw id is trusted —
  T152951, so operators *must* set it). The docblock says it "should always be
  customised in LocalSettings.php." The installer generates one automatically
  (`includes/installer/Installer.php` `generateKeys()` → `MWCryptRand::generateHex`).
- **`$wgUpgradeKey`** (`MainConfigSchema::UpgradeKey`, default `false`) — a
  password authorizing the web upgrader; also generated by the installer.
- **`$wgAuthenticationTokenVersion`** (`MainConfigSchema::AuthenticationTokenVersion`,
  default `null`) — when set, user tokens are HMAC-derived from `$wgSecretKey`
  rather than the raw secret, allowing global token invalidation by bumping the
  version. The installer defaults this to `1` for new installs.
- **`$wgJwtPrivateKey` / `$wgJwtPublicKey`** (`@since 1.45`, experimental) — RSA
  keypair for the newer JWT-based session-cookie path. *[Inferred from config
  presence; the JWT session rollout is flagged as an open question in the auth
  doc.]*

CSRF tokens and block cookies build on these (see auth doc, invariants 8–9): CSRF
tokens are per-session-secret HMACs compared with `hash_equals` (constant time);
block cookies are HMAC-signed and capped at 24h.

**Posture, not a vault:** because secrets are plain config, the security boundary
is operational — protect `LocalSettings.php`, set `$wgSecretKey`, and never commit
real secrets. Production Wikimedia injects these via private infrastructure
outside this repo; that mechanism is not in core.

---

## Input validation & output safety (the defensive layers)

These are the four big crossing-point controls plus the output-construction
helpers and the runtime backstop. Each is independent so a gap in one is caught by
another.

### Layer 1 — `Sanitizer` / parser: the HTML / XSS boundary

`includes/parser/Sanitizer.php` (~65 KB) is *the* XSS boundary: tag/attribute
allow-lists, CSS sanitization, character-reference normalization, ID/anchor
escaping, driving RemexHtml for tokenization. **Anything that emits HTML from
user-controlled wikitext must pass through it (or through Parsoid, which has its
own sanitization).** Bypassing it is how XSS gets into a wiki. Authority: the
parser doc ("`Sanitizer` is the security boundary").

### Layer 2 — Rdbms query builders: SQL-injection prevention

`includes/libs/rdbms/` exposes fluent query builders (`newSelectQueryBuilder()`,
`expr()`, etc.) that **quote values, apply table prefixes, and stay
DBMS-portable**. The rule (gotchas, below): **never build SQL by string
concatenation — use the query builder / `expr()`**, which escapes parameters.
Authority: the rdbms doc and `docs/database.md`.

### Layer 3 — `ParamValidator`: API input validation

`includes/libs/ParamValidator/ParamValidator.php` is the validation service for
both APIs. It enforces **type** (via `TypeDef` subclasses —
`includes/libs/ParamValidator/TypeDef/IntegerDef.php`, `StringDef.php`,
`EnumDef.php`, `TimestampDef.php`, `UploadDef.php`, `ExpiryDef.php`, …),
**required/default**, **min/max**, **allowed values**, and **multi-value limits**
(`PARAM_ISMULTI_LIMIT1`/`LIMIT2`), and flags sensitive params (`PARAM_SENSITIVE`,
kept out of logs). Both APIs consume it: the Action API through
`includes/api/ApiBase.php` (the legacy `PARAM_*` constants now map onto
ParamValidator), and the REST API through `includes/Rest/Handler.php`
(`getParamSettings()` / `getBodyParamSettings()` / `getHeaderSettings()`). See the
`action-api.md` and `rest-api.md` subsystem docs.

### Layer 4 — CSRF / edit tokens: state-changing-request protection

State-changing requests require a CSRF (edit) token. The modern API is
`includes/Session/CsrfTokenSet.php` (`getToken` / `matchToken` /
`matchTokenField`); the value object is `includes/Session/Token.php`, an HMAC of
`timestamp + salt` keyed by a **per-session secret**, compared with `hash_equals`
and optionally aged out. Use `CsrfTokenSet` in new code, **not**
`User::getEditToken`. The REST API has a `TokenAwareHandlerTrait`. Authority: the
auth doc, invariant 8.

### Output construction — the `Html` class and `OutputPage`

- **`includes/Html/Html.php`** is the safe HTML builder. `Html::expandAttributes()`
  applies `htmlspecialchars(..., ENT_QUOTES)` to **every** attribute value, so
  attribute injection is closed by default. The content distinction is the one to
  internalize: **`Html::element()` escapes its text content; `Html::rawElement()`
  does not** (it takes already-safe markup). Attributes are escaped in both.
- **`includes/Output/OutputPage.php`** assembles the response. Its raw sinks
  (`addHTML()` / `prependHTML()`) are annotated `@param-taint ... exec_html` —
  they take **trusted, pre-escaped HTML**; the safe path for user content is
  `addWikiTextAsContent()` (routes through the parser) or `addElement()` (routes
  through `Html::element()`). Treat `addHTML` as "I promise this is already safe."

### Output construction — `Message` (i18n) escaping

Interface text comes from `Message` (`includes/Language/Message/Message.php`), and
its terminal method chooses the escaping:

| Method | HTML-safe output? | Notes |
|---|---|---|
| `->escaped()` | **yes** | HTML-escapes the text; no wiki parsing |
| `->parse()` / `->parseAsBlock()` | **yes** | full wiki parse (sanitized) |
| `->text()` / `->plain()` | **no** (tainted) | for plaintext contexts only |
| `->rawParams(...)` | inserts **unescaped** params | only for already-safe HTML |

Rule (gotchas, below): **in an HTML context a `Message` must be `->escaped()` or
`->parse()`/`->parseAsBlock()` — `->text()`/`->plain()` output is unescaped.**
`->rawParams()` bypasses escaping and is only for HTML produced by `Html::*` or an
equivalent trusted source. Authority for the output-skin path:
`docs/handbook/subsystems/output-skins-resourceloader.md`.

### Runtime backstop — Content Security Policy

CSP is a **defense-in-depth backstop**, layered behind the controls above (so even
if HTML escaping somehow failed, inline/injected script is constrained by the
browser). Verified in `includes/Request/ContentSecurityPolicy.php`:

- It builds and sends `Content-Security-Policy` (and report-only) headers with
  `default-src` / `script-src` / `style-src` / `object-src` directives, supporting
  nonces/hashes.
- **It is off by default.** In `MainConfigSchema.php`, both `$wgCSPHeader`
  (`CSPHeader`) and `$wgCSPReportOnlyHeader` (`CSPReportOnlyHeader`) default to
  `false`; an operator opts in. *This is a real configuration nuance, not a
  defaulted-on control — do not assume CSP is protecting a given wiki.*
- **Exception:** uploaded-media output gets a restrictive CSP regardless, gated by
  `$wgCSPUploadEntryPoint` (default `true`) — a `default-src 'none'`-style policy
  applied to served user files (with a PDF variant). This pairs with the upload
  trust boundary in the files doc.

---

## Sensitive-data handling (passwords, suppression, IP hiding)

### Password hashing (layered, upgradable, constant-time)

`includes/password/` (note the lowercase directory). `PasswordFactory.php` is the
central policy engine:

- New hashes are created with the configured **default type**; the default in
  `MainConfigSchema::PasswordDefault` is **`pbkdf2`** (PBKDF2-SHA512). `Argon2`
  (`Argon2Password.php`, memory-hard) and `bcrypt` are also available and
  configurable via `PasswordConfig`.
- **Transparent upgrade on login:** `PasswordFactory::needsUpdate()` flags a hash
  whose type or cost no longer matches the default; on a successful login the
  plaintext is re-hashed to the stronger default (the auth provider schedules the
  DB write). Users never have to re-enter their password to be upgraded.
- **Layered hashes** (`LayeredParameterizedPassword.php`) let a site wrap an old
  weak hash already in the DB with a stronger outer algorithm **without knowing the
  plaintext** (e.g. legacy MD5-based `A`/`B` types wrapped by PBKDF2 as
  `pbkdf2-legacyA`/`-legacyB`). This is how a wiki migrates a whole user table off
  a weak algorithm safely.
- **Constant-time comparison:** verification uses `hash_equals` (base
  `Password::verify`); `Argon2Password` delegates to PHP's `password_verify`
  (constant-time by design).
- Legacy `MWOldPassword` (MD5) and `MWSaltedPassword` exist **only** as read paths
  for migration, never for new hashes; `InvalidPassword` always fails verification.

### Suppression / RevisionDelete (oversight)

Visibility is a bitfield on `includes/Revision/RevisionRecord.php`:
`DELETED_TEXT (1)`, `DELETED_COMMENT (2)`, `DELETED_USER (4)`, and the
oversight-level `DELETED_RESTRICTED (8)` (plus convenience masks
`SUPPRESSED_USER`, `SUPPRESSED_ALL`). Ordinary deletion hides content from the
public but leaves it visible to admins (`deletedtext`/`deletedhistory`);
**`DELETED_RESTRICTED` escalates the requirement** so the data is hidden even from
admins — only `suppressrevision` (perform) or `viewsuppressed` (read-only
oversight) can see it (`RevisionRecord::userCanBitfield()`). The orchestration
lives in `includes/RevisionDelete/`. This is the mechanism for removing
personal-information leaks, libel, etc. from public view at the oversight level.

### IP hiding / autoblock redaction (privacy of unregistered users)

- **Temporary accounts (TempUser)** replace the public recording of an anonymous
  editor's **IP address** with a pseudonymous handle (e.g. `~2024-1`). Anon and
  temp users are still caught by IP/soft/range blocks, but the IP is no longer the
  public actor. See the auth doc, "Temporary accounts."
- **Autoblocks must not leak the underlying IP:** XFF block lookups explicitly
  exclude autoblocks so a spoofed `X-Forwarded-For` cannot reveal an autoblocked
  user's IP (T285159); autoblock targets are never user-creatable and are redacted
  (`AutoBlockTarget` / `getRedactedTarget()`). See the auth doc, invariant 10.
- **`hideuser`/suppress** hides a username everywhere. See auth doc, invariant 11.

---

## Supply-chain / dependency security

- **Lockfiles:** `package-lock.json` (npm) **is committed** at the repo root.
  **`composer.lock` is NOT committed** — it is git-ignored (`.gitignore` line 71).
  So the JS dependency tree is pinned in-repo, but PHP dependency pinning is *not*
  enforced by an in-repo lockfile; Composer resolves against the constraints in
  `composer.json`. *This is a real, verified nuance — do not assume a committed
  `composer.lock`.*
- **Static analysis / hygiene in the repo:** `composer.json` wires
  `composer test` (parallel-lint + phpcs + minus-x), `composer phan` (static
  analysis, config in `.phan/`), and the codesniffer ruleset (`.phpcs.xml`). These
  catch some classes of issues at review time but are quality gates, not a CVE
  scanner.
- **External Wikimedia scanning (not in this repo):** dependency bumps are driven
  by Wikimedia's **libraryupgrader** bot (evidence: `[BOT] libraryupgrader`
  commits referenced in bundled library histories such as
  `resources/lib/ooui/History.md`). The bot and any CVE/dependency scanning run on
  Wikimedia infrastructure (Gerrit CI / Quibble), **outside** this checkout — there
  is no in-repo CI config (root `AGENTS.md`).
- **Security-relevant bundled libraries** include `lcobucci/jwt` (JWT),
  `wikimedia/common-passwords` (weak-password blocklist for the password policy),
  `guzzlehttp/guzzle` (HTTP client), and `symfony/mailer`.

*[Inference: the framing of libraryupgrader/CI as "external Wikimedia infra" is
consistent with the no-in-repo-CI note in the foundation docs; the bot's exact
scanning scope is not defined in this repo.]*

---

## Codebase-specific security gotchas (the rules a dev must internalize)

These are the rules that turn the model above into day-to-day discipline. Each is
backed by a control verified in the file cited.

1. **All user-influenced HTML must go through `Sanitizer` or the `Html` class —
   never echo raw, and never `Html::rawElement` user content.** Use
   `Html::element()` for text, `OutputPage::addWikiTextAsContent()` for wikitext.
   (`includes/parser/Sanitizer.php`, `includes/Html/Html.php`,
   `includes/Output/OutputPage.php`.)
2. **In an HTML context a `Message` must be `->escaped()` or
   `->parse()`/`->parseAsBlock()`.** `->text()` and `->plain()` are unescaped;
   `->rawParams()` is only for already-safe HTML.
   (`includes/Language/Message/Message.php`.)
3. **Never build SQL by string concatenation — use the query builder / `expr()`.**
   The builders quote and prefix; hand-built SQL is the SQL-injection path.
   (`includes/libs/rdbms/`; rdbms doc.)
4. **Validate every API parameter through `ParamValidator`** (declare type /
   limits / allowed values) — don't read raw request values in a handler.
   (`includes/libs/ParamValidator/`, `includes/api/ApiBase.php`,
   `includes/Rest/Handler.php`.)
5. **Authorize via `Authority` immediately before a write, with `authorizeWrite`**
   (RIGOR_SECURE / primary DB + rate-limit). Gating a write on
   `probablyCan`/`isAllowed` is a bug — those are UI-only and may false-positive.
   (auth doc, invariant 2.)
6. **Every state-changing request needs a CSRF/edit token** via `CsrfTokenSet` —
   not `User::getEditToken`. (`includes/Session/CsrfTokenSet.php`.)
7. **Shell out only via the `Shell`/`BoxedCommand` wrapper, passing an arg
   array.** `Shell::command([...])` escapes each argument; raw shell strings are
   never accepted (use `unsafeParams()` only as a deliberate, reviewed exception).
   By default it applies `Shell::RESTRICT_DEFAULT = NO_ROOT | SECCOMP | PRIVATE_DEV
   | NO_LOCALSETTINGS`, and on Linux wraps the command in **firejail** (hardened
   profile: capabilities dropped, sensitive paths blocked, seccomp) when available;
   `ShellboxUrls` can move execution to an isolated remote microservice. This is
   the command-injection boundary. (`includes/Shell/Shell.php`,
   `includes/Shell/Command.php`, `includes/Shell/firejail.profile`,
   `includes/Shell/ShellboxClientFactory.php`.)
8. **Trust the session store, not the request, for identity.** Never act on a
   request-asserted user without `SessionManager` corroboration. (auth doc,
   invariant 1.)
9. **Uploads are bytes *and* metadata from an attacker.** Don't weaken the upload
   verification (`UploadBase`/`UploadVerification`: MIME allow/deny, embedded
   script detection, SVG scanning, optional antivirus). Note that several upload
   checks are *configurable and can be disabled* (e.g.
   `$wgDisableUploadScriptChecks`) — defense in depth, not a hard wall. (files doc.)
10. **Set `$wgSecretKey`.** Tokens and block cookies fail *open* in specific ways
    without it (T152951). Never commit real secrets. (`includes/MainConfigSchema.php`.)
11. **`UltimateAuthority` bypasses all checks** — its use is a deliberate, audited
    decision (system/maintenance actors, tests), not a convenience. (auth doc.)
12. **CSP is off by default** — don't assume a wiki is protected by it; it is a
    backstop, not the primary escaping layer. (`ContentSecurityPolicy`,
    `$wgCSPHeader` default `false`.)
13. **Don't leak account existence or private mappings** in auth responses (same
    failure for "no user" vs "wrong password"). (auth doc, invariant 6.)

---

## Reporting a concern (private channel)

MediaWiki handles security issues through a **private** channel — **do not** file a
public Phabricator task or push a fix to public Gerrit for an unfixed
vulnerability, and do not add exploit detail to this handbook.

- **Email:** `security@wikimedia.org`.
- **Phabricator:** the non-public `Security` project (see mediawiki.org →
  "Reporting security bugs" for the current process and PGP details).
- **Disclosure:** coordinated; fixes are prepared privately and released together
  with the advisory.

If, while working in core, you find something that *looks* like a real
vulnerability, treat the area as sensitive: note in the relevant doc/review that
"a concern exists in this area" without publishing the exploit, and route the
detail to the private channel above. (Areas this document flagged as worth a
second look are listed under "Open questions / things to verify privately.")

---

## Foundation (links)

- **Authn / authz / sessions / blocks / CSRF (the security spine):**
  `docs/handbook/subsystems/auth-permissions-sessions.md` — authority for those
  mechanisms; this page summarizes and links.
- **HTML sanitization / XSS boundary:**
  `docs/handbook/subsystems/parser-and-content-transform.md` (`Sanitizer`).
- **SQL-injection prevention:**
  `docs/handbook/subsystems/database-rdbms.md` and `docs/database.md`.
- **Upload trust boundary:**
  `docs/handbook/subsystems/files-media-uploads.md`.
- **API input validation:** `docs/handbook/subsystems/action-api.md`,
  `docs/handbook/subsystems/rest-api.md`.
- **Output / skins / ResourceLoader (where `Html`/`Message`/CSP reach the page):**
  `docs/handbook/subsystems/output-skins-resourceloader.md`.
- **Config & secrets wiring:**
  `docs/handbook/subsystems/service-container-and-config.md`,
  `includes/MainConfigSchema.php`, `docs/Injection.md`.
- **Repo map / graph:** root `AGENTS.md`, `includes/AGENTS.md`,
  `graphify-out/GRAPH_REPORT.md`.

### Open questions / things to verify privately

- The **JWT-based session-cookie path** (`$wgJwtPrivateKey`/`PublicKey`,
  `JwtSessionCookieHelper`, `SessionManager::getJwtData`) is newer (1.45-era) and
  its full rollout/intent was not traced here; the auth doc lists it as an open
  question. Any concern about its key handling should go to the private channel,
  not this handbook.
- **Upload checks are individually disableable** by config
  (e.g. `$wgDisableUploadScriptChecks`, `$wgVerifyMimeType`). That is defense in
  depth by design, but a wiki that has disabled them is materially weaker — worth
  confirming production defaults rather than assuming.
- **No committed `composer.lock`** means PHP dependency pinning is not enforced
  in-repo; the actual pinned set is whatever Wikimedia CI resolves. Whether a given
  deployment audits its resolved PHP tree is out of scope for core.
- The exact scope of Wikimedia's **external dependency/CVE scanning**
  (libraryupgrader and CI) is not defined in this repo and was inferred.
