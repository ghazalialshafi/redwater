# redwater

A Redis / Valkey client for Nim, built on the [Stagelane](https://github.com/ghazalialshafi/stagelane) runtime (bundled in `vendor/stagelane`, nothing else to install).

**No futures, no `await`, no `asyncdispatch`.** Every operation that can wait is a Stagelane `{.flow.}` proc that reads like ordinary synchronous code, while the thread keeps running other tasks. The hot paths are built to allocate almost nothing: a `GET` allocates exactly one string (the value you get back), and `INCR`, `SET` and friends allocate none.

```nim
import redwater

proc main() {.flow.} =
  let c = openFlow("redis://127.0.0.1:6379")     # parks, never blocks the thread
  discard c.set("greeting", "hello", ex = 60)
  echo c.get("greeting")                           # some("hello")
  echo c.incr("visits")                            # 1
  c.close()

run main()
```

## What you get

| | |
|---|---|
| **One connection, many tasks** | Any number of tasks share one `Conn`. Commands are pipelined automatically and each task gets exactly its own reply. |
| **Cancel-safe** | A task cancelled or timed out while waiting for a reply leaves the connection in sync. |
| **Batches and transactions** | `c.batch()` sends N commands in one write; `c.atomic()` wraps them in `MULTI`/`EXEC`. |
| **TLS** | Verified by default (CA, hostname, SNI), mutual TLS, `rediss://` URLs. OpenSSL is loaded lazily, only when you use TLS. |
| **Robust reconnection** | A broken connection is re-established on the next command with exponential backoff and jitter, restoring protocol, credentials, database and name. Tasks stranded by a reset fail cleanly, they never read the new socket's bytes. |
| **Safe retries** | `Pool` and `Cluster` retry a failed command only when that cannot cause a double effect: nothing was sent, or the command is idempotent. |
| **Sentinel** | Give sentinel addresses and a master name. The master (or a healthy replica) is discovered, its role is verified, and after a failover the next command finds the new one. |
| **Cluster** | Slot-aware routing, `MOVED`/`ASK` followed (an `ASK` is `ASKING` + command in one contiguous write), topology refresh shared between tasks, hash tags, cross-slot helpers. |
| **Everything else** | RESP2 and RESP3, 210 typed commands (strings, hashes, lists, sets, sorted sets, streams and consumer groups, geo, HyperLogLog, bitmaps, scripting with `EVALSHA` caching), pub/sub with a cancel-safe reader, unix sockets, connection pool with exclusive leases. |

Every typed command exists on a `Conn`, in a `Batch`, on a `Pool` and on a `Cluster`, generated from one declaration each ([command reference](docs/commands.md)).

## Install

Stagelane is bundled in `vendor/stagelane` and wired in by `nim.cfg`, so:

```
cd redwater/examples
nim c -d:danger --mm:arc -r ex1_basic.nim        # no --path flags needed
```

To use redwater from your own project, add `redwater/src` and `redwater/vendor/stagelane/src` to your `--path` (or copy `nim.cfg`). Requires Nim 2.2+. POSIX only (Linux, macOS). Compile with `-d:danger --mm:arc` (or `--mm:orc`) for best performance.

## Performance

One shared CPU core (client and server compete, so only the *ratios* matter), medians of three runs, ops/s, bundled Stagelane:

| workload | redwater | nim-lang/redis async | nim-lang/redis blocking |
|---|---|---|---|
| 1 task, SET/GET round trips | 180,621 | 106,160 | 205,890 |
| 50 tasks, 1 shared connection | **662,126** | 109,331 | n/a |
| batch of 100 SETs | **1,812,740** | 571,562 | 1,471,790 |
| batch of 1000 SETs | **1,973,890** | 597,380 | 1,572,689 |

Strictly sequential round trips are the one place a plain blocking client is ahead (about 12% here): it has no scheduler to go through. Everywhere concurrency or batching matters redwater is well ahead.

Allocation (`malloc` calls): 30,000 `SET`/`INCR`/`EXISTS` calls make **176** (connection setup only); 20,000 `GET`/`INCR` make ~10,250 (one per returned `GET` string). The old async client makes ~1,600,000 for the same 20,000, the blocking one ~180,000. Details in [docs/benchmarks.md](docs/benchmarks.md).

## Documentation

* [Guide](docs/guide.md): concurrency model, batches, pool, TLS, reconnection, Sentinel, Cluster, pub/sub, streams, scripts
* [Command reference](docs/commands.md) (generated)
* [Internals](docs/internals.md): protocol engine, the ticket protocol, how reconnection stays safe
* [Benchmarks](docs/benchmarks.md)
* [Coming from nim-lang/redis](docs/migration.md): name mapping and behaviour differences
* [examples/](examples/): nine runnable programs

## Tests

`sh tests/run_all.sh` runs: protocol tests (every split point of every reply, malformed input), 292 integration checks (in three build configurations), a randomized cancellation chaos test, TLS / mutual TLS / reconnection / server-restart tests, a real Sentinel failover, and a real 3-node Cluster (reshard, `ASK` migration, node outage). It needs `redis-server`, `redis-cli` and `openssl`.

## Limits, honestly

* POSIX only; one scheduler thread per connection (Stagelane's thread pool was not exercised). Stagelane's io_uring mode is not used: redwater does its own `send`/`recv` on the epoll path.
* Blocking commands (`BLPOP`, `XREAD BLOCK`), `WATCH` and subscriptions occupy their connection: use `pool.withConn` or a dedicated `openFlow`.
* Cluster: reads go to masters only (no replica reads yet); `DBSIZE`/`KEYS`/`SCAN`/`FLUSHALL` are per node, so use `cl.totalKeys()`, `cl.allKeys()`, `cl.wipeAll()`.
* No client-side caching, no `CLUSTER SHARDS`, no TLS to Sentinels with separate credentials beyond the shared `Config`.
* A lost connection mid-command has an *unknown outcome* for non-idempotent commands; redwater reports `ConnectionError` and never silently re-sends them.

License: MIT.
