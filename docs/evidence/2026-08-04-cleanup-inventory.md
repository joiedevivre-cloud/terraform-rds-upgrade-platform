# Post-upgrade cleanup inventory

Captured 2026-08-04, after former-Blue deletion and workload-runner teardown.
Cost Explorer evidence is explicitly out of scope for this project (the
account's operator role has no billing read access, and enabling it was a
deliberate choice not to make for a lab account) — this artifact covers
resource-inventory verification only.

## RDS clusters

```
Id                   Status      Version
aurora-production    available   16.8
```

Exactly one cluster remains: the production cluster, now on the target
engine version. No former-Blue (`-old1`) cluster, no leftover Blue/Green
deployment record.

## RDS instances

```
Id                          Status
aurora-production-writer    available
```

Exactly one instance remains, matching the one cluster above.

## Manual DB cluster snapshots

```
Id       preupgrade-snapshot-REDACTED
Status   available
```

The manual precheck snapshot created for `precheck-aws.ps1`
(`precheck-snapshot-REDACTED`) was deleted. One
snapshot remains: an AWS-created snapshot taken automatically at Blue/Green
deployment creation (not managed by any script in this repo). It was
deliberately left in place — deleting a snapshot is irreversible, it is a
legitimate rollback artifact, and it is inexpensive to retain. Delete it
manually once it is no longer needed.

## EC2 instances

```
(none)
```

`describe-instances` (all non-terminated states) returns zero results — the
workload runner instance was destroyed by `terraform destroy` via
`enable_workload_runner = false`.

## VPC interface endpoints

```
(none)
```

`describe-vpc-endpoints` returns zero results — the four workload-runner
VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`, `secretsmanager`) and
their security groups were destroyed along with the runner instance.

## Terraform state

`terraform apply` for the workload-runner teardown reported
`Apply complete! Resources: 0 added, 0 changed, 13 destroyed.` — all 13
destroyed resources belonged to `workload_runner.tf`; no Aurora resource was
touched by this apply.

## Summary

| Item | Result |
|---|---|
| Manual precheck snapshot | Deleted |
| Former Blue cluster/instance/BG deployment | Deleted (previous evidence entry) |
| Workload runner instance | Destroyed |
| Workload runner VPC endpoints + security groups | Destroyed |
| Production cluster | Untouched, `16.8`, `available` |
| AWS auto pre-upgrade snapshot | Retained intentionally (rollback artifact, low cost) |
| Cost Explorer numbers | NOT MEASURED — operator role had no billing read access |
