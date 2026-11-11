| workload (ops/s) | previous Stagelane | new Stagelane | change | page faults prev/new | CPU s prev/new |
|---|---|---|---|---|---|
| seq SET/GET, 1 conn, 1 task | 175,577 | 180,621 | 1.03x | 195/195 | 0.29/0.27 |
| conc INCR, 50 tasks, 1 shared conn | 648,229 | 662,126 | 1.02x | 7/8 | 0.08/0.08 |
| conc INCR, 50 tasks, pool of 4 shared conns | 461,311 | 471,848 | 1.02x | 3/2 | 0.12/0.12 |
| batch SET, batch 100 | 1,686,240 | 1,812,740 | 1.08x | 15/11 | 0.02/0.02 |
| batch SET, batch 1000 | 1,788,893 | 1,973,890 | 1.10x | 0/0 | 0.10/0.08 |