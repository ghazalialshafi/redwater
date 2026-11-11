| workload | redwater | old async | old blocking |
|---|---|---|---|
| seq SET/GET | 160,268 | 95,398 | 163,463 |
| 50 tasks: 1 shared conn | 627,268 | 101,303 | - |
| 50 tasks: pool of 4 shared conns | 448,627 | - | - |
| batch SET, batch 100 | 1,772,123 | 520,734 | 1,211,304 |
| batch SET, batch 1000 | 1,848,256 | 570,321 | 1,363,676 |
| 50 tasks: 50 conns (1 per task) | - | 124,394 | - |