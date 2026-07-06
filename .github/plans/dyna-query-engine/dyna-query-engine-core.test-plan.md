# Test Plan: dyna-query-engine-core

## Test scope
- Unit tests: Parser→IR, unsupported-construct errors, Validator verdicts (permission/scope/license), key-coverage detection, Aggregator GROUP BY + locale ordering.
- Integration tests: `OpenSourceSecure` under a real security filter (AC-02); spike variant equivalence (A≡B≡C) on a production-scale relation.
- Non-regression: existing `HelloWorld.al` pageextension still compiles/publishes after AL-Go restructuring.

## Minimum scenario matrix
| ID | Given | When | Then | Type |
|---|---|---|---|---|
| T1 | a valid 2-table join query | `DQ Parser.Parse` | IR has 2 sources, 1 join, projections match | Unit |
| T2 | a query with an unsupported keyword | `TryParse` | returns false + actionable error text | Unit |
| T3 | user lacking read on a source table | `Validate` | verdict = NoPermission, no iteration | Unit |
| T4 | a source table scoped OnPrem | `Validate` | verdict = ScopeMismatch | Unit |
| T5 | user with a security filter (Restrictive) | `OpenSourceSecure` + read | out-of-scope rows excluded, **no runtime error** (AC-02) | Integration |
| T6 | join field not covered by any key | `JoinKeyCovered` | returns false + suggested key | Unit |
| T7 | production-scale relation | run spike A, B, C | equal row count and equal sum across variants | Integration |
| T8 | grouped numeric column | `Aggregate` | groups summed, ordered by value not lexically (AC-05) | Unit |

## Data and setup
- Base data: `Library - Sales` (customers), `Library - ERM` / posted entries for Cust. Ledger Entry; `Library - Random`.
- Helpers/libraries: `Library - DQ` (50145) for IR fixtures; `Library - Lower Permissions` for T5; `Assert` (Library Assert).

## Quality gates
- No compilation errors (app/ + test/)
- Tests pass on Sandbox `Dyna-Query`
- Review completed (native A–G; BCQuality not mounted)
