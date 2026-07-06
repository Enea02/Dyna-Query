# Project Memory (Global)

> **Rule**: This file is APPEND-ONLY. Never delete or overwrite existing content.
> New entries go at the bottom of each section or as new sections.

## Project Info

- **Project**: Dyna-Query (Dyna Query Studio — dynamic query engine for BC Online)
- **Repository**: Dyna-Query (BC AL extension, application 28.x, runtime 17.0, IT localization)
- **Started**: 2026-07-05
- **ALDC Core**: v1.1

## Active Requirements

| req_name | Complexity | Status | Last Updated |
|----------|-----------|--------|--------------|
| dyna-query-engine | HIGH | in-progress (architecture Approved) | 2026-07-06 |

## Completed Requirements

| req_name | Completed | Archived |
|----------|-----------|----------|
| | | |

## Decisions Log

### 2026-07-06 — Dyna Query Engine architecture approved
- **Context**: Need a runtime engine for arbitrary joins across BC tables on BC Online, within SaaS security and resource limits. Requirements in `docs/Dyna-query.md` (v1.0 + v1.1).
- **Decision**: Two-tier engine — metadata-driven RecordRef nested-loop as default (TD-01), Query-object fast-path for saved queries post-MVP (TD-04); hybrid execution PBT/foreground/StartSession (TD-02); persistent run-scoped buffer for large sets (TD-03); explicit IR between parser and engine (TD-05).
- **Rationale**: Only the nested-loop satisfies the dynamic requirement on SaaS; Query-object cache alternatives rejected for staleness/storage/write-amplification. Full options in `.github/plans/dyna-query-engine/dyna-query-engine.architecture.md`.
- **Impact**: dyna-query-engine (all phases).

### 2026-07-06 — Phase 0 performance/capacity spike mandated before build
- **Context**: The RecordRef nested-loop O(N×M) ceiling is an existential risk (§1 of the review).
- **Decision**: A de-risking Phase 0 spike (variants A no-key / B covering-key / C Query-object) precedes Phase 2; skeleton in `docs/Dyna-query.md` Allegato A.
- **Rationale**: Objective go/no-go via long-running AL/SQL telemetry before committing 21–30 days; also measure the concurrent background-session ceiling.
- **Impact**: dyna-query-engine (Phase 0 gates Phase 2 and the fast-path timing).

## Scope Changes

_(none yet)_

## Lessons Learned

### 2026-07-06 — Object IDs are unique per object type
- **Context**: An early concern that the 50100–50149 range (50 IDs) was too small for the full engine.
- **Takeaway**: BC object IDs are unique per object type, so the range yields ~50 objects *per type* — ample. The concern was dropped from the architecture (no idRanges expansion needed).

## Inter-Session Context

> Updated by agents/humans at each significant handoff.

### Last Session (2026-07-06)
- **Who**: al-architect
- **What was done**: Analyzed criticalities of `docs/Dyna-query.md`; designed and got approval for the Dyna Query Engine architecture (HIGH); created `.github/plans/dyna-query-engine/dyna-query-engine.architecture.md` (Status: Approved); decomposed into 3 specs.
- **What's next**: Run `al-spec.create` for the 3 sub-specs in order (engine-core → ui → security). Execute the Phase 0 spike on Sandbox `Dyna-Query` to validate performance before Phase 2.
- **Blockers**: None. Phase 0 spike results will confirm/refute whether the Query-object fast-path must move into the MVP.

## Next Steps

1. `@workspace use al-spec.create` — create `dyna-query-engine-core.spec.md` (read the architecture.md).
2. Then `al-spec.create` for `dyna-query-ui` and `dyna-query-security` (in order).
3. Run the Phase 0 perf/capacity spike on Sandbox and record numbers in the architecture's §9 / a `perf-triage` note.
4. Handoff to `@al-conductor` for TDD implementation once specs are ready.
