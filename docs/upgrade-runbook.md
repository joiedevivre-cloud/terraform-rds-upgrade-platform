# Aurora PostgreSQL 15 to 16 upgrade runbook

## Switchover gates

- Exact regional upgrade path is marked as a major upgrade by AWS.
- Latest snapshot is available and less than 24 hours old.
- Pending maintenance is empty and all replicated tables have a primary key or
  `REPLICA IDENTITY FULL`.
- Required extensions support PostgreSQL 16.
- Row-count mismatch is zero.
- Error rate is below 1%.
- `OldestReplicationSlotLag` is healthy and logical-slot LSN distance is zero bytes.
- Impact-ranked SQL metadata has been compared and every regression candidate has a
  documented disposition; approved critical SQL plans have been reviewed.
- Green p95 latency regression is below 15% as a secondary workload-level gate.
- DDL, DCL and partition creation are frozen from Blue/Green creation until
  switchover validation completes.
- Connection drain/retry readiness and all environment-specific resource checks are
  signed off before switchover.

All four numeric arguments to `switchover.ps1` are mandatory and range validated.
An omitted metric terminates parameter binding before any AWS request is made.

## Execution

1. Merge an approved PostgreSQL 15 baseline plan and apply it through CI.
2. Load `sql/baseline.sql`; capture Blue `precheck.sql`. Establish an identical
   measurement window with `run-ranked-workload.ps1` (warm-up, statistics reset,
   measured fixed workload), then run `capture-query-stats.ps1`. Deep-check
   only approved representative SQL with `performance.sql`/JSON EXPLAIN.
3. Run `scripts/precheck-aws.ps1` and preserve its JSON output.
4. Run `scripts/create-blue-green.ps1`; it polls until `AVAILABLE` or fails closed.
5. Inventory extensions with `sql/post-upgrade-inventory.sql`. The engine upgrade
   does not upgrade extension SQL objects: review the installed/default versions and,
   under the correct extension owner, run `ALTER EXTENSION <name> UPDATE` where the
   target version requires it. Preserve before/after version output.
6. Enumerate every connectable, non-template application database from `pg_database`.
   Connect to each database separately and run `ANALYZE VERBOSE;`; optimizer
   statistics are not transferred by a major upgrade. Confirm every partitioned
   parent reported by `sql/post-upgrade-inventory.sql` was analyzed as well. Do not
   treat analysis of one representative table as completion for a multi-database
   production cluster.
7. Replay **read-only SELECT traffic only**. Capture the same ranked
   statistics, run `compare-query-stats.ps1`, investigate candidates, and record
   workload percentiles/checksums.
   Never send INSERT/UPDATE/DELETE/DDL to Green; use an isolated snapshot clone for
   write-path testing.
8. Obtain GitHub `production` environment approval.
9. Drain or sharply reduce connection pools, stop scheduled writers/schema tools,
   verify `DatabaseConnections` and `DBLoad` are within the approved threshold, and
   start a canary that records disconnects, SQLSTATE/message, retry count and
   reconnect time. PostgreSQL connections can terminate with `AdminShutdown` during
   switchover; clients must use bounded exponential backoff and reconnect rather than
   reuse a dead session.
10. Run `scripts/switchover.ps1` with every measured gate value.
11. Repeat extension inventory, all-database `ANALYZE VERBOSE`, data, sequence,
    connection and performance validation after switchover. Prove sequence safety
    with normal application writes or a dedicated disposable test table; do not call
    `nextval` on production sequences merely for testing because sequence advances
    are not transactional.

## Change freeze during logical replication

From Blue/Green creation until post-switchover validation, freeze all schema and
privilege changes on Blue. This includes `CREATE`/`ALTER`/`DROP`, migrations that add
new partitions, and `GRANT`/`REVOKE`. Logical replication does not reproduce DDL or
DCL on Green. An emergency change requires aborting and recreating Green from the
new Blue state, not manually applying two independent copies.

## Sequence evidence

Capture `sql/precheck.sql` and `sql/post-upgrade-inventory.sql` in Blue, Green and
post-switchover production. Record total count, ownership dependency and `last_value`.
Normal Blue/Green synchronization does not continuously copy `NEXTVAL`; Aurora aligns
sequence values during switchover. Very large sequence inventories can lengthen or
time out switchover, so choose the timeout from measured inventory size. After
switchover, confirm ordinary inserts generate unique keys without collision.

## Environment-specific resource checklist

Mark each item `NOT USED`, `RECREATED/VERIFIED`, or block the switchover:

- RDS Auto Scaling policies: they are not copied; recreate and test them.
- Attached IAM roles, including roles used by the `aws_s3` extension: verify/re-attach.
- RDS Proxy: Blue must be registered before Blue/Green creation; validate target
  health and reconnect behavior after switchover.
- Zero-ETL integrations: remove before switchover and recreate afterward as required.
- IAM database-authentication policies: include both Blue and Green resource IDs.
- Global write forwarding/global-database restrictions and DMS checkpoint handling.
- Custom/static endpoints and application DNS: prefer cluster, reader or supported
  custom endpoints; do not bind applications to an individual instance endpoint.

Store the before/after AWS inventory and disposition in `docs/evidence/`.

## State reconciliation after switchover

AWS assigns the original production identifiers to Green and renames the former Blue
resources. Terraform must now expect PostgreSQL 16:

1. Set `upgrade_complete=true` in the protected production configuration.
2. Run `scripts/reconcile-state.ps1 -BlueGreenDeploymentIdentifier <id>`.
3. The script requires `SWITCHOVER_COMPLETED`, verifies that the production cluster
   and writer identifiers resolve to PostgreSQL 16, backs up remote state, and runs a
   refresh-only plan.
4. Run a normal plan. It must not propose a PostgreSQL downgrade or replacement.
5. Use `-RepairImport` only if state no longer contains/resolves the two Aurora
   addresses. The script backs up state before `state rm` and `import`.
6. Store both plans and the backup checksum in `docs/evidence/`.

## Cleanup

First retain the former Blue environment for the approved rollback window. Then run
`cleanup-former-blue.ps1` in dry-run mode with the exact AWS-renamed identifiers;
re-run it with `-Execute` only after reviewing the printed candidates. It refuses the
known current-production identifiers and requires `SWITCHOVER_COMPLETED`. Then run:

```powershell
./scripts/cleanup-lab.ps1 -ConfirmationToken DELETE-ONE-DAY-LAB
./scripts/cleanup-lab.ps1 -ConfirmationToken DELETE-ONE-DAY-LAB -Execute
terraform apply cleanup-destroy.tfplan
```

The first invocation is a dry run. The second disables deletion protection and emits
a saved destroy plan but deliberately does not execute the final destruction. After
applying it, verify no project DB cluster/instance or retained snapshot remains.

After switchover, replication to former Blue is stopped. It continues to incur normal
Aurora cost and immediately diverges from new production as writes continue. Record
the rollback deadline, owner, expected cost, snapshot decision and accepted data-loss
point. Never describe former Blue as a synchronized rollback target. Delete it only
after the incident owner accepts the divergence and the retained recovery artifact
has been verified.

## Abort conditions

Do not switch when any gate fails, replication is degraded, an extension is
unsupported, or the approved commit differs from the executing commit. Before
switchover, rollback means deleting Green. After switchover, follow the separate
rollback runbook; Terraform is not a transactional database rollback mechanism.

## AWS references

- [Performing an Aurora PostgreSQL major version upgrade](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.MajorVersion.html)
- [Upgrading PostgreSQL extensions](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.Upgrading.ExtensionUpgrades.html)
- [Aurora Blue/Green limitations and considerations](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/blue-green-deployments-considerations.html)
- [Switching an Aurora Blue/Green deployment](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/blue-green-deployments-switching.html)
- [Aurora Blue/Green best practices](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/blue-green-deployments-best-practices.html)
