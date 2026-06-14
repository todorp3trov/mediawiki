# Code Ownership & Review Norms

> Scope: the **social process** of getting a change merged into MediaWiki core —
> who effectively owns what, how a change is reviewed and submitted on Gerrit,
> the change/commit conventions, the gate pipeline, and the unwritten team
> idioms that reviewers enforce beyond the linter. For *how to run* the
> lint/test gates locally, see **doc 06 (Testing Strategy)**; for the *why*
> behind backward-compat discipline, see **doc 07 (Release / Upgrade /
> Backward Compatibility)**.
>
> **Tagging convention used throughout:** `[in-repo]` = verifiable from files in
> this checkout (cited). `[history]` = derived from read-only `git` over the
> 135,996-commit history of this clone. `[external/social]` = Wikimedia process
> knowledge that lives on mediawiki.org / wikitech / Gerrit ACLs, **not** in
> this repo; treat as orientation, confirm against the live source before
> relying on it.

---

## Ownership map (no in-repo CODEOWNERS — de-facto from history + social/team ownership)

**There is no formal owner file in this repo.** `[in-repo]` Confirmed by search:
no `CODEOWNERS`, no `.github/` directory anywhere
(`find . -iname CODEOWNERS` and `ls .github` both return nothing). MediaWiki
core is **not** reviewed on GitHub PRs and has no GitHub-style auto-assignment.
Ownership is therefore two things layered on top of each other:

1. **De-facto ownership from commit history** `[history]` — who actually writes
   and lands code in an area. This is the only ownership signal *verifiable from
   the repo itself*. It is descriptive, not an authority list.
2. **Social / team ownership on the Wikimedia side** `[external/social]` — WMF
   product/platform teams and the volunteer maintainer community that hold the
   Gerrit `+2` rights and make the calls. This is the *real* authority, and it
   does **not** live in this repo.

### Where formal vs. real owner diverge

The single most important caveat: **because there is no CODEOWNERS, there is no
"formal" owner to diverge from.** The closest thing to an authority record is
the Gerrit ACL / group membership (external), and the de-facto contributor
history (in-repo). These two *can* diverge — e.g. a person may have stopped
committing but still holds `+2` rights and reviews, or a heavy committer may not
hold `+2` in an area and needs someone else to merge. Where I name a person
below, it is **strictly "heaviest committer to this path in recent history,"
not "the person empowered to approve your patch."** Verify approver rights in
Gerrit, not here.

### De-facto top contributors (whole repo)

`[history]` From `git shortlog -sn HEAD` (all-time; bots excluded from the
reading below but shown to make the bot volume visible):

| Rank | Contributor | Commits | Note |
|------|-------------|---------|------|
| — | `[BOT] jenkins-bot` | 35,204 | CI submit bot — *every* merge is authored/committed via it |
| — | `[BOT] Translation updater bot` | 4,390 | i18n sync from translatewiki.net |
| 1 | Aaron Schulz | 7,007 | DB/perf/jobqueue core |
| 2 | Brooke Vibber | 4,563 | long-time core (historical "Tim/Brion" era) |
| 3 | Timo Tijhof | 4,022 | ResourceLoader / front-end infra |
| 4 | Sam Reed | 3,877 | API / broad maintenance |
| 5 | Umherirrender | 3,657 | broad maintenance / cleanup (volunteer) |
| 6 | Tim Starling | 3,575 | parser / core architecture |
| 7 | Alexandre Emsenhuber | 2,931 | core |
| 8 | Siebrand Mazeland | 2,862 | i18n |
| 9 | Bartosz Dziewoński | 2,563 | core / editing |
| 10 | Raimond Spekking | 2,348 | i18n |

The **jenkins-bot dominance (35k)** is the single most telling fact about this
repo's process: *humans do not push to branches.* A human uploads a patch; the
**bot** is what actually commits the merge after the gate passes. Every line of
history is "submitted by jenkins-bot on behalf of a reviewer." See *Merge
strategy* below.

### De-facto current maintainers (last 2 years)

`[history]` `git shortlog -sn --since="2 years ago" HEAD` — this is the better
proxy for *who is active now*:

Umherirrender, C. Scott Ananian, Bartosz Dziewoński, Sam Reed, Timo Tijhof,
Alexander Vorwerk, Dreamy Jazz, James D. Forrester, Thiemo Kreuz, Tim Starling,
SomeRandomDeveloper, Amir Sarabadani, Ebrahim Byagowi, Sam Wilson, Daniel
Kinzler, Gergő Tisza, Aaron Schulz, Alangi Derick, Daimona Eaytoy, Máté Szabó,
Peter Hedenskog, Jon Robson, Isabelle Hurbain-Palatin.

### De-facto ownership by subsystem

`[history]` Heaviest human committers per path over the last ~3 years
(`git shortlog -sn --since="3 years ago" HEAD -- <path>`, bots removed). Read
this as **"ask these people first / expect them to review,"** not "they can
approve." Linked to the matching subsystem deep-dive where one exists.

| Area (path) | De-facto top committers (3y) | Subsystem doc |
|-------------|------------------------------|---------------|
| Parser / content transform (`includes/parser`) | C. Scott Ananian (dominant), James D. Forrester, Thiemo Kreuz, Arlo Breault, Subramanya Sastry | `subsystems/parser-and-content-transform.md` |
| DB layer (`includes/libs/rdbms`) | Aaron Schulz, Amir Sarabadani (co-lead), Umherirrender, Bartosz Dziewoński, Tim Starling | `subsystems/database-rdbms.md` |
| ResourceLoader (`includes/ResourceLoader`) | Timo Tijhof, James D. Forrester, Hannah Okwelum, Amir Sarabadani, Jon Robson | `subsystems/output-skins-resourceloader.md` |
| REST API (`includes/Rest`) | Daniel Kinzler, Bill Pirkle, C. Scott Ananian, Arlo Breault, Atieno | `subsystems/rest-api.md` |
| Auth / sessions (`includes/auth`) | Gergő Tisza, Umherirrender, Alangi Derick, Amir Sarabadani, Kosta Harlan | `subsystems/auth-permissions-sessions.md` |

Note the **parser is effectively Parsoid-team territory** (C. Scott Ananian,
Arlo Breault, Subbu Sastry are Parsoid/Content-Transform engineers) `[history,
inferred from names]`, and the **rdbms layer is co-owned** by Aaron Schulz and
Amir Sarabadani rather than having a single owner `[history]`.

### Social / team ownership (external — not in this repo)

`[external/social]` MediaWiki core areas are de-facto stewarded by WMF
engineering teams plus volunteers. Commonly cited groupings (confirm on
mediawiki.org, these are not encoded anywhere in the repo):

- **Platform / MediaWiki Engineering** — core services, DB abstraction, parser
  integration, REST, dependency injection.
- **Editing / Parsoid / Content Transform** — parser ↔ Parsoid, wikitext.
- **Growth, Editing, Web** — product teams owning user-facing surfaces.
- **Language / i18n (translatewiki.net + WMF Language team)** — the
  `languages/i18n/*.json` files; updated automatically by the **Translation
  updater bot** `[history]`.

**Contributor base is a genuine WMF + volunteer mix** `[history]`. Email-domain
distribution over the last 2 years (`git log --since="2 years ago"
--format='%ae' | sed 's/.*@//' | sort | uniq -c | sort -rn`):

- `wikimedia.org` 2,424 and `wikimedia.de` (WMDE) 267 → WMF/WMDE staff.
- `translatewiki.net` 501 → the i18n pipeline.
- `gmail.com` 1,451, `web.de`, `fastmail`, plus many personal/vanity domains
  (`cscott.net`, `samwilson.id.au`, `srd.dev`, `reedyboy.net`, …) → volunteers
  and staff-using-personal-addresses.

The takeaway: **you cannot infer employer from the repo reliably** (staff use
personal email; volunteers are heavy committers — Umherirrender is the #1 active
human contributor). Do not assume "wikimedia.org address = decision-maker" or
"gmail = outsider." `[history]`

---

## Review process on Gerrit (+2/-2, Verified, who can merge)

`[in-repo]` The review host is fixed by `.gitreview`:

```
[gerrit]
host=gerrit.wikimedia.org
port=29418
project=mediawiki/core.git
track=1
defaultrebase=0
```

So: **all review happens on `gerrit.wikimedia.org`, project `mediawiki/core`.**
The mechanics below are how Gerrit works for this project `[external/social]`
(Gerrit behavior is not encoded in the repo, but `.gitreview` proves Gerrit is
the system):

- **Code-Review label** — human votes:
  - `+2` = approved **and** authorized to merge (only trusted reviewers /
    maintainers / `+2`-group members can give it).
  - `+1` = "looks good to me, but I'm not authorizing merge."
  - `-1` = "please fix / I'd prefer changes" (soft, non-blocking).
  - `-2` = **veto / blocks merge** until withdrawn (strong; used to hold a
    change).
- **Verified label** — set by CI, not humans:
  - `Verified +2` from **jenkins-bot** once the Quibble gate passes.
  - `Verified -1/-2` if the gate fails. A change cannot be submitted without a
    passing Verified vote.
- **Who can merge:** only someone holding `+2` rights in the relevant Gerrit
  ACL. This is the **real authority**, and it is *not* discoverable from this
  repo — it lives in Gerrit group membership `[external/social]`. The 35k
  jenkins-bot commits `[history]` confirm that the *act* of merging is always
  performed by the bot after a human applies `+2` and CI applies `Verified +2`.
- **Self-merge norm:** `[external/social, inferred]` Trusted committers *can*
  technically `+2` their own patches, but the community norm is to seek
  independent review for non-trivial changes; self-`+2` is generally reserved
  for reverts, i18n/bot updates, and trivial/obvious fixes. **Open question
  (cannot verify in-repo):** the exact self-merge policy and which groups hold
  `+2` per area — both live in Gerrit ACLs.

---

## Change conventions (one change per commit, Change-Id, Bug: T#### footer, the .gitmessage template)

`[in-repo]` `.gitmessage` is the canonical template (enable with
`git config commit.template .gitmessage`):

```
component: Some awesome subject

Why:
- …

What:
- …

Bug: TXXXXX
```

Its embedded guidance (verbatim from the file) and the rules it points to
(`https://www.mediawiki.org/wiki/Gerrit/Commit_message_guidelines`):

- **Subject ≤ 50 characters**, imperative mood, avoid passive voice.
- A **`component:` prefix** on the subject (e.g. `tests:`, `ApiQueryAllImages:`,
  `HookContainer:`, `Authentication:`). The template even gives the heuristic:
  *"HookContainer" for `includes/HookContainer`, "phpunit" for PHPUnit tests,
  "Authentication" for changes spanning auth sections.*
- **Blank line between subject and body**; wrap body at **72 chars**.
- Body explains **"why" and "what"** (the template's two sections); delete a
  section if it doesn't apply.
- **`Bug: TXXXXX` footer** linking the Phabricator task — and *"Don't leave a
  blank line after the Bug: line"* (so the `Change-Id` trailer stays attached).

`[history]` Real commits in this repo match the template exactly. Three recent
`HEAD` examples (`git log --format='%B'`):

```
tests: Convert OutputPageTest::assertTransformCssMediaCase to provider
…body…
Change-Id: Ibaf33b030b2ab9673c12046c63ff8fed890b51d0
```
```
ApiQueryAllImages: Use fr_id as secondary sort with new file tables
…body…
Bug: T428181
Change-Id: I5c62aa7dedb3a0efa6d583a99a71e1413d6eb1ba
```

Note both end with a **`Change-Id:` trailer** — a stable `I…` hash that ties all
revisions of one patch to one Gerrit change. It is **added automatically by
Gerrit's `commit-msg` hook**, not typed by hand `[external/social]`. The `Bug:`
footer is present only when a task exists (the first example has none).

**One logical change per commit / Change-Id** `[in-repo via AGENTS.md +
history]`: root `AGENTS.md` states *"small, focused commits with a `Bug: T12345`
footer."* In Gerrit each commit is a separate reviewable change; a series is a
**stacked chain** of dependent Change-Ids, each reviewed and merged in order.
Squash unrelated work into separate changes.

---

## Merge strategy (Gerrit submit / Zuul gate pipeline)

`[in-repo + external/social]` This is **not** GitHub. There is no "merge
button," no merge commit, no squash-and-merge UI.

- `.gitreview` has `defaultrebase=0` `[in-repo]` — controls the client-side
  `git review` rebase behavior, *not* the server submit type.
- **Submit type:** Gerrit "submit" on this project produces a **linear history**
  — the change is rebased/cherry-picked onto the tip of the target branch on
  merge, so there are **no GitHub-style merge commits** `[external/social;
  corroborated by linear `[history]`]`.
- **Gate-and-submit (Zuul/Quibble):** when a maintainer applies `Code-Review
  +2`, the change enters the **Zuul gate pipeline**, which runs the full
  **Quibble** test job on Wikimedia CI. On success, **jenkins-bot** applies
  `Verified +2` and performs the actual submit/merge. This is exactly why
  jenkins-bot has 35,204 commits `[history]` — it is the only "committer" of
  merges.
- **Default branch:** the project default/track branch is `master` (this
  checkout is on `master`; release branches are cut as `wmf/*` and `REL1_xx`
  externally) `[in-repo: current branch; external for branch scheme]`.

Practical consequence for an onboarding engineer: **rebase your chain, keep it
linear, and let CI + a `+2` do the merge.** You never `git push` to the
upstream branch.

---

## CI gates that must pass (→ see Testing Strategy)

`[in-repo]` The gate is defined by the `composer.json` / `package.json` scripts
(there is **no in-repo CI config** — see root `AGENTS.md`: *"CI runs on
Wikimedia infrastructure (Quibble); the authoritative build/test/lint
definitions are the `composer.json` and `package.json` scripts."*). Quibble
orchestrates these on CI. **Do not duplicate doc 06 (Testing Strategy) — this is
just the "what must be green to submit" checklist:**

PHP (`composer.json` `scripts`):
- `composer test` → `parallel-lint` + `phpcs` (style, `.phpcs.xml` /
  mediawiki-codesniffer) + `minus-x check` (no stray executable bits).
- `composer phan` → static analysis (config in `.phan/`).
- `composer phpunit` (auto-runs `phpunit:config` first; `phpunit:unit` for the
  DB-less subset).
- Structure tests (e.g. `AutoLoaderStructureTest`, `AbstractSchemaTest`) — see
  AGENTS.md Gotchas; these catch stale generated `autoload.php`/SQL.

JS / CSS / i18n (`package.json` `scripts`):
- `npm run lint` → `grunt lint` = eslint + **banana** (i18n message
  completeness) + stylelint.
- `npm test` → `grunt lint` + `jsdoc` + **jest**.
- `npm run qunit` (browser) and `npm run selenium-test` run in CI against a live
  wiki.

A change gets `Verified +2` only when the relevant subset passes. **Failing any
gate blocks submit.** Details, how to run each locally, and coverage philosophy
live in **doc 06**.

---

## Coding standards beyond lint (the team idioms enforced in review)

These are the things a reviewer will `-1` you for that **the linter does not
catch** — the tribal layer. All are `[in-repo via AGENTS.md / docs]` unless
noted:

- **Constructor dependency injection, not the service locator.** New services go
  in `includes/ServiceWiring.php` with a typed accessor on `MediaWikiServices`;
  `docs/Injection.md` is the authority. **Do not inject `MediaWikiServices`
  itself** into business logic — reviewers reject this on sight.
- **No new `wf*()` global functions.** The legacy globals in
  `includes/GlobalFunctions.php` exist but are being migrated away from; new
  global-namespace classes/functions are discouraged. New code uses the
  `MediaWiki\` namespace.
- **`@stable` interface discipline + deprecation cycles.** `[in-repo,
  measured]` Stability is annotated in docblocks: `880` files carry
  `@stable to call` / `@stable to extend` and `313` carry `@deprecated since`
  (grep over `includes/`). Reviewers enforce: don't break a `@stable`
  contract; mark removals `@deprecated since <version>` and keep them through a
  deprecation cycle rather than deleting. **Why this matters → doc 07
  (Backward Compatibility).** `@internal` marks "no external callers; change
  freely."
- **Hooks follow the interface pattern** — each hook is an `XxxHook` interface
  with `onXxx`, invoked via a `HookRunner`; see `docs/Hooks.md` and
  `subsystems/hooks-and-extension-registration.md`.
- **Database access via `IConnectionProvider`** — `$dbr` replica for reads,
  `$dbw` primary for writes; prefer the query builders
  (`newSelectQueryBuilder()`), not raw SQL. See `docs/database.md` and
  `subsystems/database-rdbms.md`.
- **No hard-coded UI English.** Messages go in `languages/i18n/en.json` with
  documentation in `qqq.json`; the **banana** checker enforces presence (lint),
  but reviewers also enforce *good message keys and qqq docs* (not lint).
- **Tabs for indentation** (`.editorconfig`) — caught by phpcs, but worth
  stating.
- **Performance-at-scale and backward-compat are first-class** (root
  `CLAUDE.md`): this engine runs Wikipedia and thousands of third-party wikis,
  so reviewers weigh schema migrations, query cost, and public-interface impact
  heavily. `[in-repo via CLAUDE.md]`

---

## Where design is discussed (Phabricator, RFC/TDM, wikitech-l)

`[in-repo anchor + external/social]` Big changes are *not* designed in the code
review. The `Bug: T####` footer in every change `[in-repo: .gitmessage,
history]` is the visible thread back to where the discussion happened:

- **Phabricator** (`phabricator.wikimedia.org`, tasks `T12345`) — the primary
  place for bug reports, feature design, and scoping. The `Bug:` footer links
  here. `[in-repo references it; the tracker itself is external]`
- **RFC / Technical Decision-Making (TDM) process** — cross-cutting or
  architectural changes (new public interfaces, schema-wide changes, removing a
  `@stable` API) go through the Wikimedia **Technical Decision-Making Process**
  (formerly the RFC process), tracked on mediawiki.org / Phabricator.
  `[external/social]`
- **wikitech-l mailing list** — announcements, deprecation notices, and
  broad-impact proposals. `[external/social]`
- **mediawiki.org** — canonical home for the commit-message guidelines (cited
  by `.gitmessage` `[in-repo]`), coding conventions, stable-interface policy,
  and team ownership pages.

**Rule of thumb for a senior onboarding:** before writing a non-trivial patch,
find or file the Phabricator task; for anything touching a public/`@stable`
interface or the schema, expect a TDM/RFC discussion first. The code review on
Gerrit ratifies a decision; it is not where the decision is made.

---

## Foundation (links)

- Root `AGENTS.md` — "Conventions" → **Commits/review** line and the DI / hooks
  / DB / i18n conventions this doc expands on.
- Root `CLAUDE.md` — Gerrit-not-GitHub, Phabricator `T####`, GPL-2.0, the
  "backward-compat & performance-at-scale are first-class" framing.
- `includes/AGENTS.md` — module-level conventions for the PHP core.
- In-repo governance anchors: `.gitreview` (Gerrit host/project/branch),
  `.gitmessage` (commit template), `.mailmap` (658-line contributor identity
  map → CREDITS), `.git-blame-ignore-revs` (bulk-reformat commits to skip in
  blame).
- Authority docs: `docs/Injection.md`, `docs/Hooks.md`, `docs/database.md`.
- **Doc 06 — Testing Strategy** (the CI gate commands in detail; do not
  duplicate).
- **Doc 07 — Release / Upgrade / Backward Compatibility** (the *why* behind
  `@stable`/deprecation discipline).
- Subsystem deep-dives this ownership map points into:
  `subsystems/parser-and-content-transform.md`,
  `subsystems/database-rdbms.md`,
  `subsystems/output-skins-resourceloader.md`,
  `subsystems/rest-api.md`,
  `subsystems/auth-permissions-sessions.md`,
  `subsystems/hooks-and-extension-registration.md`.

---

### Open questions / unverifiable-in-repo

- **Exact `+2` rights per area** — lives in Gerrit ACLs/groups, not in this
  repo. The subsystem owners above are *committers from history*, not the
  authorized approver list.
- **Self-merge policy specifics** — the norm is "independent review for
  non-trivial changes," but the precise rule is community/Gerrit-side.
- **Current WMF team→area mapping** — the team ownership grouping is
  external/social and shifts with WMF reorganizations; confirm on mediawiki.org
  rather than trusting any in-repo inference.
- **Gerrit submit type** is stated as linear/rebase from Wikimedia practice;
  `.gitreview`'s `defaultrebase=0` is a *client* setting and does not by itself
  prove the *server* submit strategy.
