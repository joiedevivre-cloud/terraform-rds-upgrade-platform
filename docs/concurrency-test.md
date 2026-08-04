# Demonstrating concurrent-run protection

This is the procedure for the "native S3 lock contention" evidence item in
[`docs/evidence/README.md`](evidence/README.md). It exercises the same S3
native lockfile (`use_lockfile = true` in `rds-upgrade/versions.tf`) that both CI roles
and any local operator share.

## Two different mechanisms — do not conflate them

- **S3 native state lock**: enforced by Terraform itself against the backend, using a
  conditional write (`If-None-Match`) on the `.tflock` object. This is what proves
  "two Terraform processes cannot hold the same state at once," and it applies
  regardless of whether the two runs are local, CI, or a mix of both.
- **GitHub Actions `concurrency` group**: `terraform-plan.yml` sets
  `group: terraform-plan-${{ github.event.pull_request.number }}` with
  `cancel-in-progress: true`, and `terraform-apply.yml` sets
  `group: terraform-production` with `cancel-in-progress: false`. This only prevents
  two *workflow runs* from overlapping inside GitHub's own scheduler — it is a
  convenience that avoids ever hitting the S3 lock in normal operation. It is not the
  control being demonstrated; the demo needs an actual lock rejection from Terraform,
  not a workflow that GitHub silently queued.

To produce real evidence you must get a genuine `.tflock` conflict, not just a queued
workflow run.

## Local reproduction (fastest, and the recommended evidence capture)

Two terminals, both pointed at the same backend key:

```powershell
# Terminal A
cd rds-upgrade
terraform plan -out=runner-a.tfplan
```

While Terminal A is mid-refresh (has already acquired the lock but not yet exited),
start Terminal B against the same state:

```powershell
# Terminal B, started while A is still running
cd rds-upgrade
terraform plan -out=runner-b.tfplan
```

Terminal B should fail with an error resembling:

```text
Error: Error acquiring the state lock

Error message: ... 412 PreconditionFailed ...
Lock Info:
  ID:        <lock-id>
  Path:      rds-upgrade/prod.tfstate
  Operation: OperationTypePlan
  Who:       <runner-a-identity>
  Created:   <timestamp>
```

Capture Terminal B's full error output (including the `Lock Info` block, which names
the holder and timestamp) and store it as the `docs/evidence/` artifact for this
control. If Terminal A finishes before Terminal B starts, there is nothing to
capture — reliably reproducing the race requires a plan/apply against a stack large
enough to still be running (or an artificial delay) when the second run starts.

## CI reproduction (harder to time, useful as a secondary artifact)

Trigger `terraform-apply.yml` via `workflow_dispatch` and, before it finishes,
push a second commit to `main` that also touches `rds-upgrade/**`. Because
`cancel-in-progress: false` on the `terraform-production` group, GitHub queues the
second run rather than canceling it — so this path demonstrates *serialization*, not
a lock rejection. If you need the actual `412`/lock-rejection error from CI, run a
local `terraform plan` against the same backend while an apply workflow is holding
the lock; the local run (using `TerraformPlanRole` or your own credentials with state
read access) will surface the same `Error acquiring the state lock` output as above.

## What "passing" looks like

- One runner completes normally.
- The other runner's process exits non-zero with an explicit lock-acquisition error
  naming the current holder.
- No partial or corrupted state results — `terraform state list` after both runs
  finish shows a state consistent with only the runner that actually held the lock.
