# Switchover, replication lag, data validation and state reconciliation

Deployment: `bgd-REDACTED` (`aurora-postgresql-15-to-16`).
Approved gate inputs: `P95RegressionPercent=-1.0983`, `ErrorRatePercent=0`,
`ReplicationLsnDistanceBytes=0`, `RowCountMismatch=0` (see
`2026-08-04-performance-comparison.{json,md}` for how these were measured).

`ErrorRatePercent=0` is the **pre-switchover Blue-versus-Green workload gate**. It is
not a measurement of client errors during the 54-second switchover. No continuous
application canary was running during this lab switchover, so switchover-window error
count and reconnect duration remain `NOT MEASURED` and must not be represented as 0%.

## Replication lag before switchover

Queried live (not a stored/cached value) immediately before requesting
switchover, against Blue's `pg_replication_slots`:

```
slot_name                                          active  confirmed_flush_lsn  current_wal_lsn  lsn_distance_bytes
rds_ca_central_1_..._16384                         t       0/532B730            0/532B730        0
rds_ca_central_1_..._5                             t       0/532B730            0/532B730        0
rds_ca_central_1_..._16401                         t       0/532B730            0/532B730        0
```

All three logical replication slots (Aurora's internal Blue/Green sync
machinery) were fully caught up: `pg_wal_lsn_diff(current_wal_lsn,
confirmed_flush_lsn) = 0` for all three, independently cross-checked twice
(once directly, once by a separate verification pass) before the switchover
gate was invoked.

## Switchover execution

```
Request accepted: 2026-08-04T03:47:08Z
Status:  SWITCHOVER_IN_PROGRESS → SWITCHOVER_COMPLETED
Duration: 54 seconds (polled every 5s)
Switchover-window application errors: NOT MEASURED
Client reconnect duration: NOT MEASURED
```

AWS performed the documented identifier swap — no application connection
string needed to change:

| Identifier (unchanged) | Before | After |
|---|---|---|
| `rds-upgrade-portfolio-blue` (same endpoint hostname) | PostgreSQL 15.10 | **PostgreSQL 16.8** |
| `aurora-blue-oldN` (redacted former Blue) | — | PostgreSQL 15.10, retained for rollback |

## Data validation (before vs. after switchover)

The same checksum query (`sql/baseline.sql`'s final `SELECT`) run at three
points — Blue before switchover, Green before switchover, and production
after switchover — returned **identical values every time**:

```
row_count = 100000
id_checksum = 5000050000
amount_checksum = 49971454.26
```

Post-switchover postcheck re-ran `ANALYZE VERBOSE portfolio_orders`
(852/852 pages, 100,000 live rows, 0 dead rows) and confirmed the extension
set matches the pre-upgrade allowlist (`pg_stat_statements 1.10`, `plpgsql
1.0`). This is valid evidence for the single application database/table in this lab;
it is not evidence that every database in a multi-database production cluster was
analyzed. The three logical replication slots used for the Blue/Green sync are
gone post-switchover (`pg_replication_slots` returns 0 rows) — AWS cleaned up
the sync machinery automatically once it was no longer needed.

## State reconciliation

1. `scripts/reconcile-state.ps1 -BlueGreenDeploymentIdentifier bgd-REDACTED`
   confirmed `SWITCHOVER_COMPLETED`, confirmed the production cluster and
   writer both resolve to `16.8`, and backed up remote state to
   `rds-upgrade/state-before-reconcile-20260803-235048.json` before touching
   anything.
2. `terraform plan -refresh-only` detected exactly the expected drift:
   `engine_version` `15.10→16.8`, both parameter groups `...postgresql15-*` →
   `...postgresql16-*`, and new `cluster_resource_id`/`dbi_resource_id`
   values (the identifier now points at a different underlying resource).
   Applied with `terraform apply -refresh-only -auto-approve`
   (0 added/changed/destroyed — pure state catch-up, no remote mutation).
3. A normal `terraform plan` afterward proposed **`0 to add, 1 to change, 0
   to destroy`** — the only diff was the `UpgradePhase` tag catching up from
   `"baseline-postgresql-15"` to `"production-postgresql-16"` (an intentional
   computed value once `upgrade_complete=true`). No `engine_version` change
   (no downgrade attempt), no replacement (`-/+`) anywhere, `0 to destroy`,
   and the former Blue (`aurora-blue-oldN`) does not appear in
   the plan at all — Terraform has no knowledge of it and never attempted to
   manage or delete it. `-RepairImport` was not needed: the existing resource
   addresses already resolved correctly without any `state rm`/`import`.
4. Applied the tag update (`terraform apply -auto-approve`): `1 changed`,
   clean.

Raw administrative transcripts remain private. This reviewed artifact retains
the measured results while redacting account-specific resource identifiers.
