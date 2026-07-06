# dyna-query-engine-core — Technical Specification

**Version:** 1.0
**Date:** 2026-07-06
**Complexity:** HIGH
**Status:** Draft

> **Skills applied**: `skill-testing, skill-performance, skill-permissions` (loaded during spec design)

## 1. Overview

### Business Context
The core of Dyna Query Engine: parse a SQL-subset into an intermediate representation (IR), validate each source under the user's own security, and (spike-gated) execute a metadata-driven nested-loop join, materialize results and aggregate them. This spec is the first of three (see the parent architecture's §14 decomposition): it delivers the engine internals that the UI and security specs build on.

### Scope
**Included**: IR + Parser, Validator (permission/scope/license/key-coverage), Result Buffer table, Setup table, engine enums, and the Phase 0 performance/capacity spike. Join Engine, Aggregator, Materializer and Estimate Task are **inventoried and signed here but their detailed algorithm is gated by the Phase 0 spike** (see §12).
**Excluded**: pages/UI (→ `dyna-query-ui.spec.md`), permission sets + audit + telemetry codeunit (→ `dyna-query-security.spec.md`), write-back (architecture §6, later phase).

### Architecture Reference
Implements `dyna-query-engine.architecture.md` — two-tier engine, metadata-driven RecordRef nested-loop (TD-01), hybrid execution (TD-02), persistent run-scoped buffer (TD-03), explicit IR (TD-05). Every object below traces to an architecture component.

---

## 2. AL Object Inventory

Prefix **`DQ`**. All IDs within `app.json` idRanges **50100–50149** (unique per object type). App objects live in `app/`, tests in `test/` (AL-Go dual-project).

| Object Type | Object ID | Name | Extends / Source | Purpose |
|-------------|-----------|------|-----------------|---------|
| Enum | 50110 | DQ Operator | — | Filter/comparison operators in the IR |
| Enum | 50111 | DQ Aggregate Function | — | Sum/Count/Min/Max/Avg for GROUP BY |
| Enum | 50112 | DQ Join Type | — | Inner/Left (equi-join) |
| Enum | 50113 | DQ Execution Mode | — | Foreground / Background (router outcome) |
| Enum | 50114 | DQ Source Verdict | — | Validator outcome (Accepted / NoPermission / ScopeMismatch / NoLicense) |
| Table | 50100 | DQ Setup | — | Single-record setup (row cap, timeout, isolation, allow-list) |
| Table | 50101 | DQ Result Buffer | — | Persistent run-scoped result rows (key Run ID, Row No.) |
| Codeunit | 50100 | DQ Parser | — | SQL-subset → IR; explicit errors on unsupported constructs |
| Codeunit | 50101 | DQ IR | — | In-memory IR holder (sources, joins, filters, projections, group/order) |
| Codeunit | 50102 | DQ Validator | — | ReadPermission + Cloud/OnPrem scope + license + key-coverage |
| Codeunit | 50103 | DQ Join Engine | — | Nested-loop equi-join (spike-gated detail) |
| Codeunit | 50104 | DQ Aggregator | — | GROUP BY via Dictionary; ORDER BY on aggregate |
| Codeunit | 50105 | DQ Estimate Task | — | Page Background Task: row estimate + cartesian flag |
| Codeunit | 50106 | DQ Materializer | — | Execution router; buffer lifecycle + cleanup |
| Codeunit | 50130 | DQ Perf Spike | — | Phase 0 spike runner (variants A/B/C) |
| Query | 50131 | DQ Perf Join | Customer ⨝ Cust. Ledger Entry | Phase 0 variant C (server-side join) |
| PageExtension | 50121 | DQ Spike Launcher | Customer List | Phase 0 dev-only action to run the spike |

**Test project (`test/`)**

| Object Type | Object ID | Name | Purpose |
|-------------|-----------|------|---------|
| Codeunit | 50140 | DQ IR Tests | Parser → IR + unsupported-construct errors |
| Codeunit | 50141 | DQ Validator Tests | Permission/scope/license rejection + AC-02 security filter |
| Codeunit | 50142 | DQ Spike Equiv Tests | Assert A ≡ B ≡ C (row count + sum) |
| Codeunit | 50143 | DQ Aggregator Tests | GROUP BY Dictionary + locale ordering (AC-05) |
| Codeunit | 50145 | Library - DQ | Reusable test data/IR builders |

---

## 3. Data Model

### DQ Setup (Table 50100)

Single-record setup (PK = code '', ReadOnly PK on the future card).

| Field No. | Field Name | Type | Required | Description |
|-----------|-----------|------|----------|-------------|
| 1 | DQ Primary Key | Code[10] | Yes | Always '' (single record) |
| 10 | DQ Row Cap | Integer | Yes | Max rows materialized before warning/stop (default e.g. 100000) |
| 11 | DQ Query Timeout (ms) | Integer | Yes | Foreground execution budget |
| 20 | DQ Read Isolation | Enum (BC IsolationLevel) | Yes | Default read isolation for diagnostic reads (§12 Q3) |
| 30 | DQ Enforce Allow-List | Boolean | Yes | If true, only allow-listed tables are queryable |

DataClassification = `CustomerContent` on all fields.

### DQ Result Buffer (Table 50101)

Persistent, run-scoped result rows for the `StartSession` path (TD-03). Foreground path uses this table as `Temporary`.

| Field No. | Field Name | Type | Length | Key | Description |
|-----------|-----------|------|--------|-----|-------------|
| 1 | DQ Run ID | Guid | — | PK part 1 | Identifies one execution |
| 2 | DQ Row No. | Integer | — | PK part 2 | Ordinal within the run |
| 10 | DQ Column 1..N | Text | 250 | — | Projected values as text (type/locale handled by formatter, §12 Q2) |
| 90 | DQ Group Key | Text | 250 | key | Ordered concat of group columns (aggregation) |

Primary key: `DQ Run ID, DQ Row No.`. Secondary key on `DQ Run ID, DQ Group Key` for aggregation grouping. DataClassification = `CustomerContent`. Cleanup: idempotent delete by `DQ Run ID` on consume/rollback + reaper job (architecture R-04).

> The generic `Column 1..N` shape is a decision recorded in §12 Q2 (fixed-width text columns vs a normalized cell table). Kept text-based to preserve locale-invariant round-trips (AC-05).

---

## 4. Business Logic — Codeunit Procedures

### DQ Parser (Codeunit 50100)

```al
codeunit 50100 "DQ Parser"
{
    // Parse a SQL-subset string into the IR. Explicit Error on unsupported constructs.
    procedure Parse(QueryText: Text; var IR: Codeunit "DQ IR")
    // Validate grammar only (no source resolution). Called by the Query Builder before execution.
    procedure TryParse(QueryText: Text; var IR: Codeunit "DQ IR"; var ErrorText: Text): Boolean
}
```

### DQ IR (Codeunit 50101)

In-memory representation consumed by Validator, Join Engine, Aggregator and (later) the Query-object mapper. Holds: sources (table no. + alias), joins (left/right field + `DQ Join Type`), filters (field + `DQ Operator` + value), projections, group-by columns, order-by columns, aggregates (`DQ Aggregate Function`).

```al
codeunit 50101 "DQ IR"
{
    procedure AddSource(TableNo: Integer; Alias: Text)
    procedure AddJoin(LeftAlias: Text; LeftField: Integer; RightAlias: Text; RightField: Integer; JoinType: Enum "DQ Join Type")
    procedure AddFilter(Alias: Text; FieldNo: Integer; Op: Enum "DQ Operator"; ValueText: Text)
    procedure AddProjection(Alias: Text; FieldNo: Integer)
    procedure AddGroupBy(Alias: Text; FieldNo: Integer)
    procedure AddAggregate(Alias: Text; FieldNo: Integer; Func: Enum "DQ Aggregate Function")
    procedure SourceCount(): Integer
    // getters for the engine to walk the structure
}
```

### DQ Validator (Codeunit 50102)

```al
codeunit 50102 "DQ Validator"
{
    // Validate all sources in the IR; returns the first failing verdict (or Accepted).
    procedure Validate(var IR: Codeunit "DQ IR"): Enum "DQ Source Verdict"
    // Secure source open — mandatory before any iteration (architecture §2).
    procedure OpenSourceSecure(TableNo: Integer; var SourceRef: RecordRef)
    // Detect whether an existing key covers the join condition; suggest one if not.
    procedure JoinKeyCovered(TableNo: Integer; JoinFields: List of [Integer]; var SuggestedKey: Text): Boolean
}
```

`OpenSourceSecure` sequence (architecture §2): `SourceRef.Open(TableNo)` → if not `ReadPermission()` → verdict `NoPermission`; check table scope (Cloud vs OnPrem) → verdict `ScopeMismatch`; `SecurityFiltering(SecurityFilter::Filtered)` → `SetPermissionFilter()`. License/entitlement failure surfaces on `Open` → verdict `NoLicense`.

### DQ Join Engine / DQ Aggregator / DQ Materializer / DQ Estimate Task

Signatures fixed here; **detailed execution algorithm is gated by the Phase 0 spike** (§12 Q1) — the row-cap enforcement point, key strategy and whether the Query-object fast-path enters the MVP depend on measured numbers.

```al
codeunit 50103 "DQ Join Engine" { procedure Run(var IR: Codeunit "DQ IR"; var Buffer: Record "DQ Result Buffer") }
codeunit 50104 "DQ Aggregator" { procedure Aggregate(var Buffer: Record "DQ Result Buffer"; var IR: Codeunit "DQ IR") } // Dictionary accumulator
codeunit 50106 "DQ Materializer" { procedure Execute(var IR: Codeunit "DQ IR"): Guid } // returns Run ID; routes FG vs StartSession
codeunit 50105 "DQ Estimate Task" { trigger OnRun() } // PBT: returns {rowEstimate, cartesianRisk} via Dictionary
```

---

## 5. Event Integration

### Subscribers (base-app events)
**None.** The engine is invoked from pages and reads tables dynamically via `RecordRef` at runtime; it does not subscribe to base-app events. No base-event symbol verification is required for this spec. (Dynamic table access is validated at runtime by `DQ Validator`, not by compile-time subscription.)

### Publishers (extensibility hooks this feature exposes)

```al
// In: DQ Validator — allow partners to veto/extend source acceptance
[IntegrationEvent(false, false)]
local procedure OnBeforeValidateSource(TableNo: Integer; var Verdict: Enum "DQ Source Verdict"; var IsHandled: Boolean)

// In: DQ Join Engine — allow partners to post-process an emitted row
[IntegrationEvent(false, false)]
local procedure OnAfterEmitRow(var Buffer: Record "DQ Result Buffer")
```

---

## 6. Pages and UI

Out of scope — delivered by `dyna-query-ui.spec.md`. The only UI object here is the **dev-only** `PageExtension 50121 "DQ Spike Launcher"` (Customer List), a temporary action that runs `Codeunit 50130 "DQ Perf Spike"` for Phase 0 measurement; it is removed before release.

---

## 7. Tests (Given/When/Then)

Test project, `TestPermissions = Disabled` except the security test (`Restrictive`). Delegate base data creation to standard libraries; `Library - DQ` (50145) builds IR fixtures.

| Test Name | Given | When | Then |
|-----------|-------|------|------|
| Parse_SimpleTwoTableJoin_BuildsIR | a valid 2-table join query | `DQ Parser.Parse` | IR has 2 sources, 1 join, projections match |
| Parse_UnsupportedConstruct_RaisesError | a query with an unsupported keyword | `TryParse` | returns false with an actionable error text |
| Validate_NoReadPermission_ReturnsNoPermission | user lacking read on a source table | `Validate` | verdict = NoPermission, no iteration started |
| Validate_OnPremScopeInCloud_ReturnsScopeMismatch | a source table scoped OnPrem | `Validate` | verdict = ScopeMismatch |
| OpenSourceSecure_FilteredUser_ExcludesOutOfScope | user with a security filter | `OpenSourceSecure` + read | out-of-scope rows excluded, **no runtime error** (AC-02) |
| JoinKeyCovered_NoCoveringKey_SuggestsKey | join field not covered by any key | `JoinKeyCovered` | returns false + a suggested key |
| Spike_VariantsProduceSameResult | production-scale relation | run A, B, C | equal row count and equal sum across A/B/C |
| Aggregate_GroupBySum_NumericOrder | grouped numeric column | `Aggregate` | groups summed correctly, ordered by value not lexically (AC-05) |

```al
// AC-02 — the security-critical test
[Test]
[TestPermissions(TestPermissions::Restrictive)]
procedure OpenSourceSecure_FilteredUser_ExcludesOutOfScope()
var
    LowerPermissions: Codeunit "Library - Lower Permissions";
    // Given a user restricted below full access, When a filtered source is opened and read,
    // Then out-of-scope records are excluded and no runtime error is raised.
begin
end;
```

Coverage targets (skill-testing): core logic 95%, error paths 100%.

---

## 8. Permission Sets

Full permission model is delivered by `dyna-query-security.spec.md`. Core tables introduced here (`DQ Setup`, `DQ Result Buffer`) require, at minimum: `DQ Setup` = R for User / RIMD for Admin; `DQ Result Buffer` = RIM for User (own runs). Engine codeunits = X. Documented here as the contract the security spec must satisfy; **no permissionset object is created in this spec**.

---

## 9. API Endpoints

Not applicable — the engine exposes no API in the MVP.

---

## 10. AL-Go / CI Considerations

- [ ] Dual-project AL-Go: `app/` (production) + `test/` (test app with Test Framework dependencies: `Test Runner`, `Library Assert`, `Any`, `Library - Lower Permissions`).
- [ ] All object IDs within `app.json` idRanges 50100–50149; test objects likewise (per type).
- [ ] `HelloWorld.al` (pageextension 50100) moved into `app/` during scaffolding.
- [ ] No new BC version dependency; base is v28.2 (matches environment).
- [ ] Captions added to XLF for any user-facing text (spike launcher action is dev-only).

---

## 11. Acceptance Criteria

### Functional
- [ ] A 2-table equi-join parses to IR and executes returning correct rows (AC-01 relation).
- [ ] Out-of-scope records never appear in results; no runtime error under a security filter (AC-02).
- [ ] Row-count pre-flight runs in a PBT and is cancellable, UI stays responsive (AC-03).
- [ ] Aggregated numeric/date output sorts/groups by value under IT locale (AC-05).

### Technical
- [ ] All AL objects compile; test project builds and runs on Sandbox `Dyna-Query`.
- [ ] Validator returns three distinguishable verdicts (permission/scope/license).
- [ ] No base-object modification; extension-only.

### Quality
- [ ] GWT tests above implemented and green; error paths covered.
- [ ] Code review APPROVED by al-review-subagent (native A–G; BCQuality not mounted).
- [ ] Phase 0 spike numbers recorded (A/B/C timings + concurrent-session ceiling).

---

## 12. Open Questions

| # | Question | Owner | Status |
|---|---------|-------|--------|
| 1 | Join Engine detail (row-cap enforcement point, key strategy, fast-path in MVP?) is gated by the Phase 0 spike numbers | Human + spike | Open |
| 2 | Result Buffer column shape: fixed-width `Column 1..N` text vs normalized cell table? | Human | Open |
| 3 | Default `DQ Read Isolation` for live diagnostic reads: ReadUncommitted (dirty reads, declared) vs ReadCommitted? | Human | Open |
| 4 | Object/name prefix: `DQ` (this spec, matches architecture) vs `DSC QS` (original v1.0 doc)? | Product Owner | Open |
| 5 | SQL-subset grammar boundary for MVP (which operators/joins/aggregates are in scope)? | Human | Open |

---

## Next Steps (HIGH)

✅ Spec complete. Next:
1. Human reviews/approves this spec.
2. Resume `@al-conductor` — it now has spec + architecture and orchestrates planning → implementation → review for the approved scope (scaffolding + spike + IR + Validator).
