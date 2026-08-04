# Switchover gate rejection evidence

Captured 2026-08-04, against the completed deployment `bgd-REDACTED`
(after a successful switchover, so the AWS-side status check would also refuse —
these runs demonstrate the **client-side quantitative gates** in
`scripts/switchover.ps1` reject bad values before any AWS mutation is attempted).

| Test | Input | Result |
|---|---|---|
| P95 regression | `-P95RegressionPercent 20` (threshold: below 15%) | `Gate failed: p95 regression must be below 15%.` |
| Error rate | `-ErrorRatePercent 2` (threshold: below 1%) | `Gate failed: error rate must be below 1%.` |
| Replication LSN distance | `-ReplicationLsnDistanceBytes 500` (must be 0) | `Gate failed: logical replication LSN distance must be zero bytes.` |
| Row-count mismatch | `-RowCountMismatch 3` (must be 0) | `Gate failed: row-count mismatch must be zero.` |
| Missing mandatory metric | `-P95RegressionPercent` omitted | `Cannot process command because of one or more missing mandatory parameters: P95RegressionPercent.` |

Each failing case aborted before `aws rds switchover-blue-green-deployment` was
ever called — confirmed by no corresponding API activity and by the script
throwing from its own `if (...) { throw }` gate checks (or, for the missing-
parameter case, from PowerShell's own mandatory-parameter binding, before the
script body executes at all).

Compare against the actual passing invocation recorded in
Compare against the reviewed successful-switchover evidence:
`-P95RegressionPercent -1.0983 -ErrorRatePercent 0 -ReplicationLsnDistanceBytes 0
-RowCountMismatch 0` → `All quantitative gates passed. Requesting switchover.` →
`SWITCHOVER_COMPLETED` in 54 seconds.
