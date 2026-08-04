# Performance and data evidence procedure

Use a funnel rather than executing every production SQL:

1. Observe all statements during a fixed window with `pg_stat_statements`.
2. Select the union of Top-N by total time, calls, mean time, shared reads and temp
   I/O. The capture does not execute application statements.
3. Match versions using a normalized-SQL SHA-256 fingerprint. Keep each environment's
   `queryid` as evidence, but do not use it as the cross-major-version key.
4. Capture JSON EXPLAIN only for approved important SQL; use EXPLAIN ANALYZE only for
   safe SELECTs or in an isolated clone.
5. Treat p50/p95/p99 as a secondary workload gate.

For a fair lab window, `run-ranked-workload.ps1` performs warm-up, calls
`pg_stat_statements_reset()`, and then runs the measured fixed-predicate workload.
Capture immediately afterward. Never reset production statistics without DBA approval.

```powershell
./scripts/run-ranked-workload.ps1 -InstanceId <runner-id> -SecretArn <secret-arn> `
  -DbHost <blue-endpoint>
./scripts/capture-query-stats.ps1 -InstanceId <runner-id> -SecretArn <secret-arn> `
  -DbHost <blue-endpoint> -EnvironmentLabel blue-15
./scripts/capture-query-stats.ps1 -InstanceId <runner-id> -SecretArn <secret-arn> `
  -DbHost <green-endpoint> -EnvironmentLabel green-16
./scripts/compare-query-stats.ps1 -BlueStatsPath <blue.csv> -GreenStatsPath <green.csv>
```

After metadata triage, capture only the approved representative plans with
`capture-critical-plans.ps1` on each side and compare them with
`compare-plan-hashes.ps1`. Plan canonicalization recursively sorts JSON keys and
removes timing, costs, estimates, buffer/WAL counters, worker runtime details and
`Workers Launched`. It generates adjacent JSON and Markdown reports containing the
hashes, change status and review guidance. A changed hash is a review signal, not
proof of regression.

The comparison flags mean-time regressions of 15% and statements not observed on
Green. These are review candidates, not automatic failures; consider calls, reads,
cache warmth, plan shape and business criticality.

Run the same workload against Blue and Green with identical iteration count and
dataset. `scripts/run-workload.ps1` drives the read query from `sql/performance.sql`
in a loop inside a single PL/pgSQL block (one connection, so per-sample latency
reflects database execution time, not repeated psql process-spawn overhead) and
writes a `timestamp_utc,latency_ms,success` CSV:

```powershell
./scripts/run-workload.ps1 `
  -SecretArn <master-user-secret-arn-or-name> `
  -DbHost <blue-writer-endpoint> `
  -EngineLabel 15.10 `
  -Iterations 200

./scripts/run-workload.ps1 `
  -SecretArn <master-user-secret-arn-or-name> `
  -DbHost <green-writer-endpoint> `
  -EngineLabel 16.8 `
  -Iterations 200
```

Each run writes `docs/evidence/generated/<EngineLabel>-metrics.csv` by default. The
secret can be either the RDS-managed master secret or the self-managed secret created
by `scripts/convert-master-password.ps1` — the script parses either shape.

Run `sql/performance.sql` against both environments and record its row count and
checksums. Generate the comparison artifact:

```powershell
./scripts/compare-performance.ps1 `
  -BlueMetricsPath ./blue-metrics.csv `
  -GreenMetricsPath ./green-metrics.csv `
  -BlueRowCount 100000 `
  -GreenRowCount 100000 `
  -BlueChecksum REPLACE_ME `
  -GreenChecksum REPLACE_ME `
  -EnforceGates
```

The workload script calculates p50/p95/p99, error rates, p95 regression, row mismatch and
checksum equality. It writes JSON and Markdown under `docs/evidence/generated/` and
exits unsuccessfully when an enforced gate fails. Raw data and the generated report
must include the tested commit SHA in the run manifest.
