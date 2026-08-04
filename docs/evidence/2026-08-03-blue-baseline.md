# Blue baseline deployment evidence

- Captured at: 2026-08-03 UTC
- Region: `ca-central-1`
- Source: AWS CLI `describe-db-clusters` and `describe-db-instances`
- Account identifiers and endpoints intentionally omitted from the public artifact.

```json
{
  "cluster": {
    "status": "available",
    "engine": "aurora-postgresql",
    "version": "15.10",
    "encrypted": true,
    "backup_retention_days": 1,
    "deletion_protection": true,
    "http_endpoint_enabled": false,
    "cluster_parameter_group": "rds-upgrade-portfolio-aurora-postgresql15-cluster",
    "created_at": "2026-08-03T16:58:02.179000+00:00"
  },
  "writer": {
    "status": "available",
    "class": "db.t4g.medium",
    "version": "15.10",
    "publicly_accessible": false,
    "parameter_apply_status": "in-sync",
    "availability_zone": "ca-central-1a"
  }
}
```

This proves only the encrypted private PostgreSQL 15 baseline. It does not prove
precheck, workload, Blue/Green, switchover, reconciliation or cleanup controls.
