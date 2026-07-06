## Plan: Dyna Query Engine — Core Foundation

Establish AL-Go test infrastructure, de-risk the existential nested-loop performance question with the Phase 0 spike, and build the spike-independent foundations (IR + Parser + Validator) from `dyna-query-engine-core.spec.md`. Join Engine / Materializer / Aggregator are deferred to a post-spike run (their detail is spike-gated).

**AL Context:**
- Base Objects: Customer, Cust. Ledger Entry (spike reads only — no base modification).
- Extension Pattern: new Codeunits/Tables/Enums; PageExtension + Query for the spike; extension-only (event-driven where applicable).
- AL-Go Structure: **to be established** — `app/` (production) + `test/` (test app with Test Runner + Library Assert + Library - Lower Permissions).
- Dependencies: BC v28.2 base (matches environment); Test Framework apps for `test/`.

**Phases**

1. **Phase 1: Planning** — (this document) findings + approved plan; requirement set spec ✅ / architecture ✅ / test-plan ✅. No code.

2. **Phase 2: AL-Go dual-project scaffolding**
   - **Objective:** restructure to `app/` + `test/`; wire the test runner.
   - **AL Objects:** move pageextension 50100 (HelloWorld) into `app/`; add `test/` app.json (Test Framework deps).
   - **Event Architecture:** none.
   - **Files:** `app/app.json`, `app/HelloWorld.al`, `test/app.json`, `test/DQSmokeTests.Codeunit.al`.
   - **Tests:** one trivial passing test proves the runner works.
   - **AL Patterns:** AL-Go layout; test objects in `test/` only.
   - **Steps:** create test project → trivial failing test → wire runner → make it pass → verify app/ still builds.

3. **Phase 3: Performance & capacity spike** (architecture Phase 0)
   - **Objective:** measure variants A (no key) / B (covering key) / C (Query object); de-risk R-01; probe concurrent background-session ceiling.
   - **AL Objects:** codeunit 50130 "DQ Perf Spike", query 50131 "DQ Perf Join", pageextension 50121 "DQ Spike Launcher" (dev-only).
   - **Tests:** codeunit 50142 "DQ Spike Equiv Tests" — assert A ≡ B ≡ C (row count + sum) [T7].
   - **AL Patterns:** SetCurrentKey + push-down SetRange, SetLoadFields, ReadIsolation, telemetry `Session.LogMessage` (dq_variant/dq_rows/dq_ms).
   - **Steps:** write equivalence test (RED) → implement A/B/C + telemetry → test GREEN → publish to Sandbox → record A/B/C timings + session ceiling.

4. **Phase 4: IR + Parser** (architecture Phase 1a)
   - **Objective:** SQL-subset → IR; explicit errors on unsupported constructs.
   - **AL Objects:** enums 50110–50114; codeunit 50100 "DQ Parser"; codeunit 50101 "DQ IR".
   - **Tests:** codeunit 50140 "DQ IR Tests" [T1, T2].
   - **AL Patterns:** error handling (actionable errors); no base access.
   - **Steps:** write parse/error tests (RED) → implement IR + Parser (GREEN) → refactor.

5. **Phase 5: Validator** (architecture Phase 1b)
   - **Objective:** ReadPermission + Cloud/OnPrem scope + license/entitlement (3 distinct verdicts) + key-coverage detection.
   - **AL Objects:** table 50100 "DQ Setup", table 50101 "DQ Result Buffer", codeunit 50102 "DQ Validator".
   - **Tests:** codeunit 50141 "DQ Validator Tests" [T3, T4, T5 (AC-02, Restrictive), T6].
   - **AL Patterns:** `ReadPermission`/`SecurityFiltering(Filtered)`/`SetPermissionFilter`; DataClassification on all fields.
   - **Steps:** write verdict + security tests (RED) → implement Validator + tables (GREEN) → refactor.

**Open Questions**
1. Prefix `DQ` vs `DSC QS`? (affects all object names — decide before Phase 4) / Product Owner
2. Default read isolation: ReadUncommitted (dirty reads, declared) vs ReadCommitted? (Setup default) / Human
3. SQL-subset grammar boundary for the MVP (operators/joins/aggregates in scope)? / Human
4. Result Buffer column shape: fixed-width text `Column 1..N` vs normalized cell table? / Human
5. Should the Query-object fast-path move into the MVP? — resolved by Phase 3 spike numbers / spike
