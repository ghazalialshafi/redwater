# Benchmarks

Run: `STAGELANE=... OLDREDIS=... sh bench/run_all.sh` (builds `-d:danger`, ARC for redwater, ORC for the old client). Programs: `bench/rw_bench.nim`, `old_async_bench.nim`, `old_sync_bench.nim` (identical workloads, 32-byte values), `bench/alloc_*.nim` (malloc probes).

**Environment:** Nim 2.2.12, Redis 7.0.15, **a single shared CPU core** (client and server compete), loopback. Absolute numbers move with machine load (an earlier run gave ~100k sequential, a later one ~160k), so only same-session ratios are meaningful. The table is the median of two back-to-back runs of all three clients.

| workload (ops/s) | redwater | nim-lang/redis async | nim-lang/redis blocking |
|---|---|---|---|
| 1 task, SET/GET | 180,621 | 106,160 | 205,890 |
| 50 tasks, 1 shared connection | 662,126 | 109,331 | n/a |
| 50 tasks, pool of 4 | 471,848 | n/a | n/a |
| 50 tasks, 50 connections | n/a | 152,829 | n/a |
| batch of 100 SETs | 1,812,740 | 571,562 | 1,471,790 |
| batch of 1000 SETs | 1,973,890 | 597,380 | 1,572,689 |

Reading it: sequentially redwater is ~1.7x the async client and ~12% behind a blocking one (identical syscalls; the difference is scheduler overhead); under concurrency it is ~6x the async client (the old client serialises commands per connection; redwater pipelines across tasks); batches are ~1.2x the blocking client and ~3.2x the async one.

## Allocation (`ltrace`, `-d:useMalloc`)

| probe | commands | mallocs |
|---|---|---|
| redwater `GET` + `INCR` | 20,000 | ~10,250 (one per returned `GET` string) |
| redwater `SET` + `INCR` + `EXISTS` | 30,000 | 176 (all connection setup) |
| nim-lang/redis async, `GET` + `INCR` | 20,000 | ~1,600,000 |
| nim-lang/redis blocking, `GET` + `INCR` | 20,000 | ~180,000 |

## Caveats

One core is the worst case for a client that shares it with the server; on separate cores both server and client run in parallel and absolute throughput rises, but the per-command CPU saved by redwater is the same. TLS, Sentinel and Cluster were verified functionally, not benchmarked.

## Stagelane revision A/B

The same redwater code built against the previous Stagelane and the bundled one, interleaved, median of 3 (`bench/results/stagelane_ab.md`; the previous-Stagelane binary was built from the redwater revision just before the `+OK` fast path, which only affects `SET`):

| workload (ops/s) | previous Stagelane | new Stagelane | change | page faults prev/new | CPU s prev/new |
|---|---|---|---|---|---|
| seq SET/GET, 1 conn, 1 task | 175,577 | 180,621 | 1.03x | 195/195 | 0.29/0.27 |
| conc INCR, 50 tasks, 1 shared conn | 648,229 | 662,126 | 1.02x | 7/8 | 0.08/0.08 |
| conc INCR, 50 tasks, pool of 4 shared conns | 461,311 | 471,848 | 1.02x | 3/2 | 0.12/0.12 |
| batch SET, batch 100 | 1,686,240 | 1,812,740 | 1.08x | 15/11 | 0.02/0.02 |
| batch SET, batch 1000 | 1,788,893 | 1,973,890 | 1.10x | 0/0 | 0.10/0.08 |

The new runtime is never slower here; batches gain 8-10%. The sequential and concurrent differences (2-3%) are within this VM's noise. Stagelane's io_uring mode was not benchmarked because redwater issues its own `send`/`recv`.
