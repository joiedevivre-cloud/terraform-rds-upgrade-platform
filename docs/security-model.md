# Security model

## IAM roles (`ci-iam/main.tf`)

| Role | Who can assume it | Intended scope |
|---|---|---|
| `TerraformPlanRole` | This repository's pull-request runs and the exact `main` branch subject (`sts:AssumeRoleWithWebIdentity`) | Read-only infrastructure discovery; exact state-object read; exact `.tflock` create/delete. It creates the pre-approval production plan but cannot write state or mutate infrastructure. |
| `TerraformApplyRole` | Only a run whose job declares `environment: production` (`sub = repo:<owner>/<repo>:environment:production`) | Create/Modify/Delete on the VPC, subnet, security group, RDS cluster/instance/parameter-group, CloudWatch alarm and Secrets Manager resources this stack manages |
| `TerraformStateAdminRole` | Only the explicit IAM ARNs supplied through `state_admin_principal_arns` | Break-glass access to read/write/delete the state object directly, for `reconcile-state.ps1 -RepairImport` |

Both `TerraformPlanRole` and `TerraformApplyRole` trust only GitHub's OIDC provider
(`token.actions.githubusercontent.com`) with `aud = sts.amazonaws.com` — no long-lived
AWS access key exists for either path. `TerraformApplyRole` can only ever be assumed by
a workflow run tied to the `production` GitHub Environment, which is the mechanism
that ties an AWS-side permission boundary to a GitHub-side required-reviewer gate.

## Human developers vs. CI

`aws_iam_policy.deny_direct_production_changes` denies
`rds:Create*/Modify*/Delete*/Reboot*/Start*/Stop*/Switchover*/Failover*/Promote*` in
this project's region, scoped by `aws:RequestedRegion`. Terraform attaches it to every
IAM user explicitly listed in `developer_user_names`. Leaving that set empty creates
the policy but attaches it to nobody, so the public evidence must show both a non-empty
configuration and a real `AccessDenied` result before this control is marked complete.

## State access boundary

State and lock permissions are separate. `TerraformPlanRole` receives `GetObject` on
the exact state key and `GetObject`/`PutObject`/`DeleteObject` only on the exact
`.tflock` key. `TerraformApplyRole` can additionally write the exact state key.
Neither role receives a wildcard object suffix. This preserves native S3 locking
without allowing a pull-request or pre-approval plan job to replace production state.

## Network

`rds-upgrade/network.tf` creates a dedicated VPC (`10.20.0.0/16`) with two private
database subnets and no internet gateway. The security group denies all inbound
traffic by default; `allowed_client_cidrs` (empty by default) is the only way to open
TCP/5432, via a `for_each` over `aws_vpc_security_group_ingress_rule`. There is no
public endpoint and `publicly_accessible = false` on the writer instance.

## Secrets

> Superseding design: the RDS-managed secret described below is baseline-only.
> Aurora Blue/Green does not support that credential mode. Before Green creation,
> `scripts/convert-master-password.ps1` creates an independently managed secret and
> changes the live cluster without passing plaintext to Terraform. After conversion,
> set `manage_master_user_password = false` and record only
> `external_master_secret_arn`. Temporary CLI input files are deleted in `finally`;
> run the one-time transition only on the trusted administrator laptop.
> A successful control-plane transition is not treated as proof of database access.
> The independent secret is validated through `scripts/run-workload.ps1` from the
> private SSM runner before Blue/Green creation.

`manage_master_user_password = true` on `aws_rds_cluster.blue` means AWS generates and
owns the master password in Secrets Manager (`rds!...` prefix) — Terraform never
receives, stores, or logs the plaintext password. `docs/iam/terraform-rds-secrets-policy.json`
scopes Secrets Manager actions to that `rds!*` prefix in this account/region, and
`docs/iam/terraform-rds-kms-policy.json` scopes KMS actions to grants requested
`kms:ViaService` from `rds` or `secretsmanager` only. `master_user_secret_arn` is the
only cluster output marked `sensitive = true`.

## State-admin role

`TerraformStateAdminRole` trusts only the explicit role/user ARNs supplied through
`state_admin_principal_arns`; account root is not used as a wildcard principal. In a
production organization, supply a dedicated break-glass role and add MFA/session
controls in the surrounding identity system.

## Approved-plan integrity

The main-branch workflow creates a binary plan with `TerraformPlanRole`, records the
commit SHA and plan SHA-256, and uploads one immutable artifact with one-day retention.
The `production` environment approval gates a separate apply job. That job downloads
the named artifact, verifies both hashes, and only then assumes `TerraformApplyRole`
to apply the exact saved plan. Terraform binary plans can contain sensitive values;
they are never committed or published as evidence, and repository artifact access
must remain restricted.

## Time-bounded security exceptions

Two Checkov controls are intentionally suppressed at the exact affected resources;
neither suppression disables a scanner globally.

- `CKV_AWS_327`: The existing lab cluster is encrypted, but its storage key was not
  declared as a customer-managed key at creation. Aurora cannot change an existing
  cluster storage key in place. Remediation is a controlled replacement: take a
  snapshot, restore a new cluster with a dedicated CMK, validate data and connectivity,
  cut over, and retain the former cluster for the approved rollback window. Adding
  `kms_key_id` directly to the existing resource is prohibited because it can propose
  replacement of the production cluster.
- `CKV_AWS_226`: Exact Aurora 15.10 and 16.8 patch levels are pinned so performance,
  query-plan, and compatibility evidence remains reproducible. Minor upgrades are not
  ignored; they require their own PR, AWS upgrade-path precheck, saved plan, maintenance
  approval, and post-change validation instead of an unreviewed automatic change.

The database security group has no explicit egress rules. Security groups are stateful,
so response traffic for an approved inbound PostgreSQL connection remains allowed. Add
an explicit destination-scoped egress rule only if a documented database feature later
requires the cluster to initiate outbound traffic.
