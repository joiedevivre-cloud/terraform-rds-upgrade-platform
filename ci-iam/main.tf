data "aws_caller_identity" "current" {}

locals {
  state_bucket_arn                     = "arn:aws:s3:::${var.state_bucket_name}"
  state_object_arn                     = "${local.state_bucket_arn}/${var.state_key}"
  lock_object_arn                      = "${local.state_bucket_arn}/${var.state_key}.tflock"
  workload_runner_role_arn             = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/rds-upgrade-portfolio-workload-runner"
  workload_runner_instance_profile_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/rds-upgrade-portfolio-workload-runner"
  github_oidc_subject_repository       = var.github_oidc_subject_repository != "" ? var.github_oidc_subject_repository : var.github_repository
  oidc_provider_arn = var.create_github_oidc_provider ? (
    aws_iam_openid_connect_provider.github[0].arn
  ) : var.github_oidc_provider_arn
}

check "github_oidc_provider" {
  assert {
    condition     = var.create_github_oidc_provider || var.github_oidc_provider_arn != ""
    error_message = "Set github_oidc_provider_arn or create_github_oidc_provider=true."
  }
}

data "tls_certificate" "github" {
  count = var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_oidc_subject_repository}:pull_request",
        "repo:${local.github_oidc_subject_repository}:ref:refs/heads/main"
      ]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_oidc_subject_repository}:environment:production"]
    }
  }
}

resource "aws_iam_role" "terraform_plan" {
  name               = "TerraformPlanRole"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role" "terraform_apply" {
  name               = "TerraformApplyRole"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
}

resource "aws_iam_role" "terraform_state_admin" {
  name = "TerraformStateAdminRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.state_admin_principal_arns }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "state_bucket_read" {
  statement {
    actions   = ["s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.state_key, "${var.state_key}.tflock"]
    }
  }
}

data "aws_iam_policy_document" "plan_state_access" {
  source_policy_documents = [data.aws_iam_policy_document.state_bucket_read.json]

  statement {
    actions   = ["s3:GetObject"]
    resources = [local.state_object_arn, local.lock_object_arn]
  }
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_object_arn]
  }
}

data "aws_iam_policy_document" "apply_state_access" {
  source_policy_documents = [data.aws_iam_policy_document.state_bucket_read.json]

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_object_arn, local.lock_object_arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "TerraformStateLockAccess"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.plan_state_access.json
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "TerraformStateLockAccess"
  role   = aws_iam_role.terraform_apply.id
  policy = data.aws_iam_policy_document.apply_state_access.json
}

resource "aws_iam_role_policy" "state_admin" {
  name   = "TerraformStateRecoveryAccess"
  role   = aws_iam_role.terraform_state_admin.id
  policy = data.aws_iam_policy_document.apply_state_access.json
}

resource "aws_iam_role_policy" "plan_read" {
  name = "TerraformPortfolioRead"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*", "rds:Describe*", "rds:ListTagsForResource",
        "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
        "kms:DescribeKey", "kms:ListAliases", "secretsmanager:DescribeSecret",
        "sts:GetCallerIdentity"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "apply_resources" {
  name = "TerraformPortfolioApply"
  role = aws_iam_role.terraform_apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:CreateVpc", "ec2:ModifyVpcAttribute", "ec2:DeleteVpc",
        "ec2:CreateSubnet", "ec2:ModifySubnetAttribute", "ec2:DeleteSubnet",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:CreateTags",
        "ec2:DeleteTags", "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress", "ec2:Describe*",
        "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint", "ec2:DeleteVpcEndpoints",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StartInstances", "ec2:StopInstances",
        "ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile", "ec2:ReplaceIamInstanceProfileAssociation",
        "rds:CreateDBSubnetGroup", "rds:ModifyDBSubnetGroup", "rds:DeleteDBSubnetGroup",
        "rds:CreateDBCluster", "rds:ModifyDBCluster", "rds:DeleteDBCluster",
        "rds:CreateDBInstance", "rds:ModifyDBInstance", "rds:DeleteDBInstance",
        "rds:CreateDBClusterParameterGroup", "rds:ModifyDBClusterParameterGroup", "rds:DeleteDBClusterParameterGroup",
        "rds:CreateDBParameterGroup", "rds:ModifyDBParameterGroup", "rds:DeleteDBParameterGroup",
        "rds:CreateDBSnapshot", "rds:DeleteDBSnapshot", "rds:AddTagsToResource", "rds:RemoveTagsFromResource",
        "rds:Describe*", "rds:ListTagsForResource",
        "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms",
        "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource",
        "kms:DescribeKey", "kms:CreateGrant", "kms:GenerateDataKey*", "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "secretsmanager:CreateSecret", "secretsmanager:TagResource", "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue", "secretsmanager:PutResourcePolicy", "secretsmanager:UpdateSecret",
        "secretsmanager:DeleteSecret", "secretsmanager:RestoreSecret"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "apply_pass_role" {
  name = "TerraformPortfolioPassRole"
  role = aws_iam_role.terraform_apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PassWorkloadRunnerRoleOnly"
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = local.workload_runner_role_arn
      Condition = {
        StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
      }
    }]
  })
}

# This role/profile belongs to the security stack, not the application stack. The
# production ApplyRole can pass it to EC2 but cannot mutate its permissions.
resource "aws_iam_policy" "workload_runner_boundary" {
  name        = "RdsUpgradePortfolioWorkloadRunnerBoundary"
  description = "Maximum permissions available to the private SSM workload runner"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SsmManagedInstanceControlPlane"
        Effect = "Allow"
        Action = [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:PutInventory",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadPortfolioDatabaseSecretsOnly"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds-upgrade-portfolio/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "workload_runner" {
  name                 = "rds-upgrade-portfolio-workload-runner"
  permissions_boundary = aws_iam_policy.workload_runner_boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workload_runner_ssm" {
  role       = aws_iam_role.workload_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "workload_runner_secrets_read" {
  name = "WorkloadRunnerSecretsRead"
  role = aws_iam_role.workload_runner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
        "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds-upgrade-portfolio/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "workload_runner" {
  name = "rds-upgrade-portfolio-workload-runner"
  role = aws_iam_role.workload_runner.name
}

resource "aws_iam_policy" "deny_direct_production_changes" {
  name        = "DenyDirectAuroraProductionChanges"
  description = "Attach to human developer identities; CI ApplyRole remains the production mutation path."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDirectRdsMutation"
      Effect = "Deny"
      Action = [
        "rds:Create*", "rds:Modify*", "rds:Delete*", "rds:Reboot*",
        "rds:Start*", "rds:Stop*", "rds:Switchover*", "rds:Failover*",
        "rds:Promote*"
      ]
      Resource = "*"
      Condition = {
        StringEquals = { "aws:RequestedRegion" = var.aws_region }
      }
    }]
  })
}

resource "aws_iam_user_policy_attachment" "developer_production_deny" {
  for_each = var.developer_user_names

  user       = each.value
  policy_arn = aws_iam_policy.deny_direct_production_changes.arn
}
