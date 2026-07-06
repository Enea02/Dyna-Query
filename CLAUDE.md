# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Microsoft Dynamics 365 **Business Central AL extension**, targeting **BC Online (SaaS)**. The repo is currently an early scaffold — the only object is `HelloWorld.al` (a `pageextension` on Customer List). The substance of the project lives in [docs/Dyna-query.md](docs/Dyna-query.md): the technical spec ("Dyna Query Studio") for a **dynamic query engine** that runs equi-joins across BC tables at runtime. Treat that document as the source of truth for design decisions; most of it is **not implemented yet**.

## Target platform (from [app.json](app.json))

- Application/platform **v28** (BC 2026 wave 1), `runtime: 17.0`, **IT** localization.
- Object ID range: **50100–50149** — all new objects must fall inside this.
- Cloud target: use only `Cloud`-scoped APIs. `RecordRef` against `OnPrem`-scoped tables is not allowed and must be rejected by the Validator (see spec §2).

## Build / publish / debug workflow

There is no CLI build in this repo; development is driven through the **AL Language extension** in VS Code (command palette + function keys):

- **Download symbols** (populates `.alpackages/`): `AL: Download Symbols`. Required before the first compile; `.alpackages/` is empty until then.
- **Compile to `.app`**: `Ctrl+Shift+B` (`AL: Package`).
- **Publish + debug**: `F5`. **Publish without debug**: `Ctrl+F5`.
- **Auth issues**: `AL: Clear credentials cache`, then re-run — auth is Microsoft Entra (AAD), interactive.

### Environments ([.vscode/launch.json](.vscode/launch.json))

Two configs against tenant `63c268a7-2b11-40f3-a1db-a7a93552237a`:
- **Dyna-Query** — `Sandbox` environment. **Use this for day-to-day publish/test.**
- **Production Online** — `Production` environment. Publish here only intentionally.

Online configs are keyed on `tenant` + `environmentName` + `environmentType` (no `server`/`serverInstance`/`UserPassword` — those are on-prem only). `environmentName` must match the environment name exactly as shown in the [BC Admin Center](https://businesscentral.dynamics.com/admin).

## Tests

No test app exists yet. BC tests are `codeunit`s with `Subtype = Test`, run from the *Test Tool* page in-client or via the AL Test Runner extension — not from a shell. The spec (§8) mandates that acceptance is validated against **long-running AL / SQL telemetry** (Application Insights), not just pass/fail.

## Architecture the spec mandates (read before implementing the engine)

The query engine is a read-only, metadata-driven nested-loop join. Key invariants pulled from [docs/Dyna-query.md](docs/Dyna-query.md) that span multiple components:

- **Metadata, never physical SQL** — tables/fields are resolved via AL metadata (`RecordRef`/`FieldRef`), because physical SQL names aren't stable across versions and direct SQL isn't supported.
- **Security is mandatory before every read** — a source must pass `RecordRef.ReadPermission()`, then `SecurityFiltering(SecurityFilter::Filtered)` + `SetPermissionFilter()` before iteration. Skipping this causes runtime errors on out-of-scope records, not just missing filtering. The Validator rejects a source for two distinct reasons: missing permission *and* Cloud/OnPrem scope mismatch.
- **Hybrid execution model** — pre-flight row estimation runs in a **Page Background Task** (read-only, cancellable, returns only a `Dictionary<Text,Text>`); full materialization runs **foreground** (small sets) or via **`StartSession`** with a persistent, run-scoped buffer (large sets); **write-back is always foreground** (a PBT can't write).
- **Result buffer shape follows execution** — `Temporary` record for foreground; a **real table keyed `Run ID, Row No.`** with explicit cleanup for the `StartSession` path (a PBT's temp tables are per-session and can't be read by the parent page).
- **Partial records on the read path only** — `SetLoadFields` aggressively for joins/projection; on the write-back path load the **full** record (never `SetLoadFields`), or the runtime pays a JIT load.
- **GROUP BY via `Dictionary` accumulator** (key = ordered concat of group columns; value = Sum/Count/Min/Max/avg pair), sorting only the aggregated result — not sort-and-collapse over the raw buffer.
- **Audit survives rollback** — write business audit via a dedicated `StartSession` (so it isn't rolled back with a failed write-back); emit technical diagnostics to telemetry (`Session.LogMessage` / `Telemetry.LogError`).

### Object naming

The spec uses the **`DSC QS`** object-name prefix (e.g. Codeunit 50102 "DSC QS Validator", "DSC QS Estimate Task", table "DSC QS Audit Log"). Note the scaffold's `HelloWorld.al` still uses the template namespace `DefaultPublisher.DynaQuery` and publisher — align new objects to the `DSC QS` naming / DSC namespace, not the template defaults.
