# Subsystem Deep Dives

This is the index for the per-subsystem deep dives. Each linked document is the
reference a senior engineer needs to **own a change** in that subsystem without
asking around: its responsibility and boundaries, internal structure, main
flows, the state it owns, its dependencies in and out, extension points,
invariants and gotchas, and "how to make a typical change here."

Read [Architecture](02-architecture.md) first — it traces a request across these
subsystems and explains how they fit together. Each deep dive builds on the
module map in [`includes/AGENTS.md`](../../includes/AGENTS.md) (and, for the
front-end and CLI pieces, [`resources/AGENTS.md`](../../resources/AGENTS.md) and
[`maintenance/AGENTS.md`](../../maintenance/AGENTS.md)).

## The architectural spine (learn these first)

From the structural graph, the most-connected hubs — the abstractions almost
everything else touches — are the **hook system** (`HookRunner`, ~1084 edges),
the **service container** (`MediaWikiServices`), the **localisation** message
system (`wfMessage`), **`OutputPage`**, the **DB layer** (`Database`),
**`Title`**, and the parser's **`ParserOutput`**/**`Sanitizer`**. The four
subsystems that own those hubs — hooks, the service container, the database, and
the parser — are the ones to read before the rest.

## Platform / cross-cutting subsystems

These are the engine's foundations; every feature subsystem sits on top of them.

| Subsystem | What it owns | Foundation |
| --- | --- | --- |
| [Hooks & Extension Registration](subsystems/hooks-and-extension-registration.md) | The universal extension point: `HookContainer`/`HookRunner` dispatch, `XxxHook::onXxx()` interfaces, `ExtensionRegistry`/`extension.json` loading, and the newer Domain Event system. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Service Container & Configuration](subsystems/service-container-and-config.md) | The DI hub (`MediaWikiServices` over a generic `ServiceContainer`) and the staged config pipeline `MainConfigSchema → SettingsBuilder → $wg* → Config → ServiceOptions`. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Database (Rdbms)](subsystems/database-rdbms.md) | The framework-agnostic relational DB abstraction (`wikimedia/rdbms`): replica/primary split, `LoadBalancer`/`LBFactory`, lag & chronology handling, transaction rounds, query builders. | [includes/AGENTS.md](../../includes/AGENTS.md), [docs/database.md](../database.md) |
| [Caching, Deferred Updates & Job Queue](subsystems/caching-deferred-jobs.md) | The performance infrastructure: `BagOStuff`/`WANObjectCache` tiers, `ParserCache`/`MessageCache`/`LinkCache`, `DeferredUpdates`, the `JobQueue`, and `PoolCounter` stampede protection. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Localisation (i18n / L10n)](subsystems/localisation.md) | The message system (`wfMessage`), `Language` objects, `LocalisationCache` + on-wiki `MessageCache`, and locale-aware formatting. | [includes/AGENTS.md](../../includes/AGENTS.md), `languages/` |

## Content & identity subsystems

The core domain: pages, revisions, content, identity, and access control.

| Subsystem | What it owns | Foundation |
| --- | --- | --- |
| [Storage, Revisions & Content](subsystems/storage-revisions-content.md) | The canonical write path and the MCR data model: `page → revision → slots → content → blob`, `ContentHandler`, `RevisionStore`, `PageUpdater`/`DerivedPageDataUpdater`. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Title, Linking & Namespaces](subsystems/title-linking-namespaces.md) | Page identity (`Title` + the `LinkTarget`/`PageReference`/`PageIdentity` value-object migration), the namespace model, title normalization, and batched link rendering. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Authentication, Permissions & Sessions](subsystems/auth-permissions-sessions.md) | The security spine: how a request becomes a verified identity (`Session`/`AuthManager`), what it may do (`Authority`/`PermissionManager`), and how blocks/CSRF gate actions. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Files, Media & Uploads](subsystems/files-media-uploads.md) | The layered file model (`File` over `FileRepo` over `FileBackend`), media handlers/thumbnailing, and the security-critical upload pipeline. | [includes/AGENTS.md](../../includes/AGENTS.md) |

## Presentation & request-handling subsystems

The surfaces through which clients reach the engine.

| Subsystem | What it owns | Foundation |
| --- | --- | --- |
| [Parser & Content Transformation](subsystems/parser-and-content-transform.md) | Wikitext → safe HTML via the legacy PHP `Parser` or Parsoid, both producing `ParserOutput`, then the `OutputTransform` pipeline; `Sanitizer` is the XSS boundary. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Output, Skins & ResourceLoader](subsystems/output-skins-resourceloader.md) | HTML page assembly (`OutputPage`), theming (`Skin`), and versioned JS/CSS module delivery via `load.php` (ResourceLoader). | [includes/AGENTS.md](../../includes/AGENTS.md), [resources/AGENTS.md](../../resources/AGENTS.md) |
| [Actions, Special Pages & Editing](subsystems/actions-special-pages-editing.md) | The `index.php` web front door: `ActionEntryPoint` routing to an `Action` or `SpecialPage`, the `EditPage`→`PageEdit` save flow, and the `HTMLForm` framework. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [Action API](subsystems/action-api.md) | The classic module-based web API (`api.php` → `ApiMain` → `ApiBase` modules) with the `ApiQuery` prop/list/meta submodule model. | [includes/AGENTS.md](../../includes/AGENTS.md) |
| [REST API](subsystems/rest-api.md) | The modern route+verb HTTP API (`rest.php`): DI'd `Handler` classes via a `Router`/`Module` path matcher, with OpenAPI specs. | [includes/AGENTS.md](../../includes/AGENTS.md) |
