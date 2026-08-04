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
