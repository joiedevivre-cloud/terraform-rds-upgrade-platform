# Aurora PostgreSQL performance comparison

| Metric | Blue (15.10) | Green (16.8) | Gate |
|---|---:|---:|---|
| Samples | 200 | 200 | - |
| Error rate | 0% | 0% | Green < 1% |
| p50 latency | 43.922 ms | 42.469 ms | - |
| p95 latency | 48.255 ms | 47.725 ms | Regression < 15% |
| p99 latency | 63.111 ms | 56.889 ms | - |
| Row count | 100000 | 100000 | Exact match |
| Checksum | 100000|5000050000|49971454.26 | 100000|5000050000|49971454.26 | Exact match |

- p95 regression: -1.0983%
- row-count mismatch: 0
- all gates pass: True
