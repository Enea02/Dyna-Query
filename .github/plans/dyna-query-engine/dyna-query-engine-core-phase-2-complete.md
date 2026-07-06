## Phase 2 Complete: AL-Go dual-project scaffolding

Restructured the flat project into an AL-Go dual-project layout (`app/` + `test/`) and added a self-contained smoke test that proves the test runner. This establishes the TDD foundation for `dyna-query-engine-core`. **Build/test not executed in this environment — must be confirmed on Sandbox `Dyna-Query` via F5.**

**AL Objects Created/Modified:**
- Codeunit 50149 "DQ Smoke Tests" (Subtype = Test) — new
- PageExtension 50100 "CustomerListExt" (HelloWorld) — moved into `app/`, unchanged

**Files created/changed:**
- `app/app.json` — moved from root (main extension manifest)
- `app/HelloWorld.al` — moved from root
- `app/.vscode/launch.json` — copied (Production Online + Sandbox `Dyna-Query`)
- `test/app.json` — new test app (id `8d363ee8-…`, depends on Dyna-Query 28.0.0.0)
- `test/src/DQSmokeTests.Codeunit.al` — new smoke test
- `test/.vscode/launch.json` — copied
- `Dyna-Query.code-workspace` — new multi-root workspace (app + test)

**Functions created/changed:**
- `Smoke_TestRunnerWorks_Passes()` — [Test] proving the runner (self-contained assert)

**Tests created/changed:**
- Codeunit 50149 "DQ Smoke Tests" — 1 test procedure

**AL Patterns Applied:**
- Extension-only (no base object modification); test objects live in `test/` only
- AL-Go dual-project; test app depends on the main app
- Self-contained assert (no test-toolkit dependency yet — deferred to Phase 3/5)

**Skills Applied in This Phase:**

| Skill | Pattern Used | Evidence |
|-------|-------------|----------|
| skill-testing | Given/When/Then (self-contained) | test/src/DQSmokeTests.Codeunit.al |

**BCQuality Evidence:** 🔎 BCQuality not consulted (unavailable — `../bcquality` absent, `aldc.yaml enabled=auto`) → reviewed via ALDC native A–G checks + instructions.

**Review Status:** APPROVED_WITH_RECOMMENDATIONS — 0 blocker / 0 major / 4 minor / 1 info (see `dyna-query-engine-core-review-phase-2.json`). Build/test **not executed** here; GREEN pending Sandbox F5.

**Follow-ups (non-blocking):** reconcile namespace/prefix (Q1) before Phase 4; add verified test-toolkit GUIDs in Phase 3/5; tidy orphaned root `.vscode/launch.json`.

**Git Commit Message:**
```
chore: scaffold AL-Go app/ + test/ projects

Move app.json + HelloWorld.al into app/; add a test/
project (Dyna-Query Tests) with a self-contained smoke
test proving the runner. Establishes the TDD structure
for dyna-query-engine-core. Build/test to be verified on
the Sandbox (F5) — not run in this environment.
```
