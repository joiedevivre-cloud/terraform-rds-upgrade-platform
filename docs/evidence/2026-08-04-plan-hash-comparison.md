# PostgreSQL plan hash comparison

- Generated (UTC): 2026-08-04T01:45:49.9469619Z
- Blue raw plans: `blue-15-critical-plans-20260804T000707Z.txt`
- Green raw plans: `green-16-critical-plans-20260804T004925Z.txt`
- Plans compared: 8
- Plans requiring review: 0

| SQL label | Blue plan hash | Green plan hash | Changed | Review status |
|---|---|---|:---:|---|
| `customer_range` | `d95f773a93f76084` | `d95f773a93f76084` | False | **UNCHANGED** |
| `customer_recent` | `37f73b544fea88a0` | `37f73b544fea88a0` | False | **UNCHANGED** |
| `customer_window` | `6cb6ac04b9a0e557` | `6cb6ac04b9a0e557` | False | **UNCHANGED** |
| `daily_counts` | `e1536ffce4cd1ab2` | `e1536ffce4cd1ab2` | False | **UNCHANGED** |
| `date_aggregate` | `886b139267925e59` | `886b139267925e59` | False | **UNCHANGED** |
| `pk_lookup` | `1d799afa93919bd1` | `1d799afa93919bd1` | False | **UNCHANGED** |
| `status_aggregate` | `bc95a000476f90c0` | `bc95a000476f90c0` | False | **UNCHANGED** |
| `top_amounts` | `0e3b5a3e63fb5899` | `0e3b5a3e63fb5899` | False | **UNCHANGED** |

## Interpretation

- `UNCHANGED`: the canonical plan structure is identical after volatile fields were removed.
- `REVIEW_PLAN_CHANGE`: inspect node, join and index changes together with execution time and buffer statistics.
- `MISSING_BLUE` / `MISSING_GREEN`: the approved SQL was not captured on one side and the evidence is incomplete.
- A changed hash is a review signal, not automatic proof of performance regression.

Full SHA-256 values are retained in the adjacent JSON report.
