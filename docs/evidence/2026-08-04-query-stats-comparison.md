# Impact-ranked SQL metadata comparison

> Matching uses normalized-SQL SHA-256 because PostgreSQL does not guarantee queryid stability across major versions.

| Fingerprint | Blue queryid | Green queryid | Mean change | Reads change | Status |
|---|---:|---:|---:|---:|---|
| 1e7651da17eb | 7255857124462035091 | -8236462150256947897 | 6.27% | % | PASS |
| 2067ad81da14 | -2469251489422095620 | 8623492495537592930 | 2.01% | % | PASS |
| 23f9b7031636 | 903935759207065050 | -3073253036024745849 | 1.6% | % | PASS |
| 49ebfdb87fc1 | -8485266316306030636 | -3166783180392950241 | -1.17% | % | PASS |
| 5044dd519d50 | 2870642618111528807 | 1552471841327731804 | -2.91% | % | PASS |
| 5953bb586f12 | -8685230058379122854 | -2769095511248916266 | -11.33% | % | PASS |
| 6a12a8f014e0 | -8918282986913656535 | -2903419861573758804 | -19.18% | % | PASS |
| aeb077845780 | -572032091231667055 | 2701434036760104561 | -1.17% | % | PASS |

Review candidates: 0

A warning is triage, not an automatic failure. Review plans, buffers, cache state, calls and business criticality.
