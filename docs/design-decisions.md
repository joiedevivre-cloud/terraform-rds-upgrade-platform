# Design decisions

## One environment instead of artificial module reuse

This repository is a one-day production-upgrade lab with one controlled Aurora
environment. It does not claim dev/staging/prod module reuse, so empty environment
wrappers and premature modules are intentionally omitted. If a second independently
deployed environment is introduced, the stable network/Aurora resources should then
be extracted into modules with state moves recorded before refactoring.

## Data API is not part of this architecture

Aurora PostgreSQL 15.10 supports Data API in the Region, but the selected low-cost
`db.t4g.medium` provisioned instance class rejected HTTP endpoint activation. The
failed experiment made no database change. Data API configuration and IAM policy were
removed; SQL testing uses a short-lived private workload runner instead.

## Saved plans are ephemeral

Binary `.tfplan` files can contain sensitive state values and are never committed.
CI creates the plan with the weaker PlanRole before approval, retains it for one day
as a repository-scoped immutable artifact, and publishes its commit SHA and SHA-256.
After protected-environment approval, a separate job verifies those values before it
assumes ApplyRole and applies that exact binary. Portfolio evidence stores redacted
plan text, commit SHA and checksum rather than the binary plan.
