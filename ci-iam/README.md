# GitHub OIDC and IAM control plane

This stack uses its own encrypted S3 backend at `ci-iam/terraform.tfstate`; the IAM
control plane is not left in local state. Copy `backend.hcl.example` to ignored
`backend.hcl` and initialize it after the bootstrap stack exists.

The administrator performing this first initialization must already have
`GetObject/PutObject/DeleteObject` permission for `ci-iam/terraform.tfstate` and its
`.tflock` object. This one-time bootstrap permission cannot come from roles that the
stack has not created yet.

## GitHub OIDC provider

If `token.actions.githubusercontent.com` already exists in the AWS account, pass its
ARN through `github_oidc_provider_arn`. Otherwise set
`create_github_oidc_provider=true` and leave the ARN empty. Do not create a duplicate
provider in an account that already has one.

## Roles and state permissions

- `TerraformPlanRole` trusts only this repository's pull-request subject and exact
  `main` branch subject. It can read the exact state object and can write/delete only
  the exact `.tflock` object. The `main` subject is required to create the immutable
  production plan before environment approval.
- `TerraformApplyRole` trusts only this repository's protected `production`
  environment and can update both state and lock objects.
- `TerraformStateAdminRole` trusts only `state_admin_principal_arns`; account root is
  not used as a wildcard trust principal.

`developer_user_names` attaches `DenyDirectAuroraProductionChanges` to the specified
human IAM users. Leaving the set empty creates the policy but does not prove the human
denial control. Record the attachment and a real AccessDenied event as evidence.

```powershell
terraform init -backend-config=backend.hcl
terraform plan -out=ci-iam.tfplan
terraform apply ci-iam.tfplan
```

Review this stack with a cloud administrator. IAM permissions are isolated from the
database stack to avoid self-escalation by the normal production pipeline.
