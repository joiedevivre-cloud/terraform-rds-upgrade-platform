# Evidence index

Replace each `PENDING` entry with an immutable artifact link, timestamp and commit SHA.
Do not claim a control passed until the corresponding artifact exists.

Verified baseline: [`2026-08-03-blue-baseline.md`](2026-08-03-blue-baseline.md).

| Control | Status | Required artifact |
|---|---|---|
| Native S3 lock contention | PENDING | Runner A lock and Runner B `412 PreconditionFailed` output |
| Human production apply denied | PENDING | CloudTrail/IAM AccessDenied event |
| PR plan and required checks | PENDING | Pull request URL and plan artifact SHA |
| Approval before apply | PENDING | GitHub production environment approval screenshot |
| Security scan blocks a defect | PENDING | Intentionally failing Checkov/TFLint run and fixing commit |
| PostgreSQL precheck | **DONE** | [`2026-08-03-postgresql-precheck.json`](2026-08-03-postgresql-precheck.json) — PASS, all fail-closed gates clear |
| SQL metadata triage (Blue vs Green) | **DONE** | [`2026-08-04-query-stats-comparison.md`](2026-08-04-query-stats-comparison.md) — 8 compared, 0 require review. Raw: [Blue](2026-08-04-blue-15-query-stats.csv) / [Green](2026-08-04-green-16-query-stats.csv) |
| Query plan structural comparison | **DONE** | [`2026-08-04-plan-hash-comparison.md`](2026-08-04-plan-hash-comparison.md) — 8/8 plans identical. Raw: [Blue](2026-08-04-blue-15-critical-plans.txt) / [Green](2026-08-04-green-16-critical-plans.txt) |
| Replication lag | **DONE** | [`2026-08-04-switchover-and-reconciliation.md`](2026-08-04-switchover-and-reconciliation.md) — live LSN distance 0 bytes on all 3 slots, cross-checked twice, immediately before switchover |
| PostgreSQL 15/16 performance | **DONE** | [`2026-08-04-performance-comparison.md`](2026-08-04-performance-comparison.md) — pre-switchover comparison: P95 regression **-1.10%** (Green faster), 0% workload error rate, checksums match. Raw: [Blue](2026-08-04-blue-15-latency.csv) / [Green](2026-08-04-green-16-latency.csv) |
| Switchover gate rejection | **DONE** | [`2026-08-04-switchover-gate-rejection.md`](2026-08-04-switchover-gate-rejection.md) — 5 failing invocations, each blocked before any AWS mutation |
| Successful switchover | **DONE** | [`2026-08-04-switchover-and-reconciliation.md`](2026-08-04-switchover-and-reconciliation.md) — AWS control-plane status reached `SWITCHOVER_COMPLETED` in 54 seconds; client errors/reconnect time were not measured |
| Data validation | **DONE** | [`2026-08-04-switchover-and-reconciliation.md`](2026-08-04-switchover-and-reconciliation.md) — identical row count/checksums on Blue, Green and post-switchover production |
| Switchover connection resilience | PENDING | Continuous canary showing disconnect reason, retry count, error rate and reconnect duration during switchover |
| Sequence synchronization | PENDING | Blue/Green/post-switchover inventory, ownership, `last_value`, and collision-free application insert evidence |
| Environment-specific resources | PENDING | Auto Scaling/attached roles/Proxy/zero-ETL/IAM auth/endpoints inventory with `NOT USED` or verified disposition |
| State reconciliation | **DONE** | [`2026-08-04-switchover-and-reconciliation.md`](2026-08-04-switchover-and-reconciliation.md) — refresh-only + normal plan, 0 downgrades/replacements/deletions proposed |
| Temporary-resource cleanup | **DONE** | [`2026-08-04-cleanup-inventory.md`](2026-08-04-cleanup-inventory.md) — workload runner, VPC endpoints and former Blue were removed; only the intended production cluster and retained recovery snapshot remained at capture time |
| Actual AWS cost | PENDING / NOT MEASURED | Cost Explorer/Budget evidence was unavailable because the operator role had no billing read access |

`tests/fixtures` contains synthetic pass/fail data used only to verify the report
generator. Synthetic output is never accepted as production evidence.

Generate the live PostgreSQL precheck artifact with
`scripts/run-sql-precheck.ps1`. Generated reports remain ignored until reviewed and
promoted deliberately. PASS requires SSM success, response code zero and the final
machine-readable `PRECHECK_JSON` marker from the fail-closed SQL.
