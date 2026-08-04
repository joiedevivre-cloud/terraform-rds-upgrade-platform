# GitHub production governance

Repository settings are controls outside Terraform and must be configured before the
CI evidence run.

## Branch protection for `main`

- Require a pull request and at least one approval.
- Require CODEOWNERS review.
- Dismiss stale approvals when new commits are pushed.
- Require conversation resolution.
- Require the `plan` job to pass.
- Block force pushes, deletion and direct pushes.

## Production environment

Create a GitHub Environment named `production`, require a DBA or platform reviewer,
and prevent self-review. Configure these repository/environment variables:

- `AWS_TERRAFORM_PLAN_ROLE_ARN`
- `AWS_TERRAFORM_APPLY_ROLE_ARN`
- `TF_STATE_BUCKET`
- `ENABLE_DATABASE`
- `UPGRADE_COMPLETE`

No long-lived AWS access key is stored in GitHub. OIDC trust binds PlanRole to pull
requests plus the exact `main` branch, and binds ApplyRole to the protected production
environment. On `main`, the PlanRole job creates the saved plan and publishes its
summary, commit SHA and SHA-256 before approval. The protected apply job downloads
that same one-day artifact, verifies both hashes, and only then assumes ApplyRole.

Binary plan artifacts can contain sensitive values. Restrict Actions read access,
use the one-day retention configured in the workflow, never commit the binary, and
publish only redacted text and hashes as portfolio evidence.

The `ci-iam` stack can either consume an existing GitHub OIDC provider ARN or create
the provider when `create_github_oidc_provider=true`. Confirm the provider does not
already exist before enabling creation. Populate `developer_user_names` so the
explicit human production-mutation deny is actually attached; a policy ARN by itself
is not evidence of enforcement.
