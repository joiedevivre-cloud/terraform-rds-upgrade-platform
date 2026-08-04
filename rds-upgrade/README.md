# Aurora baseline stack

This stack reuses the remote S3 backend and existing private network resources. It
creates both PostgreSQL 15 and 16 parameter groups, while the billable PostgreSQL 15
cluster and writer are guarded by `enable_database`.

Copy `backend.hcl.example` to ignored `backend.hcl` and insert the bootstrap bucket.
Copy `portfolio.auto.tfvars.example` to ignored `portfolio.auto.tfvars`, verify the
exact regional versions, and enable the database only for an approved test window.

```powershell
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=aurora-baseline.tfplan
terraform apply aurora-baseline.tfplan
```

After a successful Blue/Green switchover, set `upgrade_complete=true` before the
next normal plan and follow `docs/upgrade-runbook.md` for state reconciliation.

`allowed_client_cidrs` is empty by default; do not expose PostgreSQL to the internet
for convenience. Set `enable_workload_runner=true` instead to create a private,
SSM-managed EC2 instance (`workload_runner.tf`) for SQL/precheck/workload work. It
has no key pair, no public IP and no inbound rules — only SSM Session Manager reaches
it, through interface VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`,
`secretsmanager`) plus a free S3 gateway endpoint for package installs, since this VPC
has no NAT/internet gateway. Its security group is referenced directly by the
database security group, not by CIDR.

```powershell
terraform output workload_runner_instance_id
aws ssm start-session --target <instance-id> --profile portfolio-bootstrap --region ca-central-1
# inside the session:
psql "host=<blue-writer-endpoint> dbname=upgrade_lab user=portfolio_admin sslmode=require" -c "SELECT 1"
```

Set `enable_workload_runner=false` and re-apply to tear it down, along with the VPC
endpoints, at the end of the test window.
