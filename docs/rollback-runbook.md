# Rollback runbook

Before switchover, rollback means deleting the Green environment and leaving Blue
unchanged. After switchover, do not assume Terraform can transactionally undo the
database change. Stop application writes, assess whether the old environment is a
safe target, and use the retained snapshot or a forward fix according to the incident
commander's decision. Never write independently to both environments.

Capture the deployment identifier, snapshot identifier, endpoints, timestamps,
CloudWatch metrics, validation output and approving identity in `docs/evidence/`.

After a successful switchover, set `upgrade_complete=true` before any normal apply.
Run `reconcile-state.ps1` without `-RepairImport` first. Import repair is an exceptional
state-admin action, requires a state backup, and must be recorded as incident evidence.
