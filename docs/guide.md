# redwater guide

## 1. Basics

```nim
import redwater

proc main() {.flow.} =
  let c = openFlow("redis://:secret@127.0.0.1:6379/2")
  discard c.set("k", "v", ex = 30, nx = true)      # options are named arguments
  let v = c.get("k")                                # Option[string]
  if v.isSome: echo v.get
  for (field, value) in c.hgetAll("user:1"): echo field, "=", value
  c.close()
run main()
```

* `{.flow.}` procs are Stagelane's non-blocking procs. Call them from other flow procs like any function, or from `run`. There is no `await`.
* Missing keys are `none`, never `""`. Counts are `int`, yes/no answers `bool`, lists `seq`.
* Options (`ex`, `nx`, `limit`, ...) are default-valued parameters: sent only when you set them.
* Server errors raise `ServerError` (`e.code` is `WRONGTYPE`, `NOSCRIPT`, ...). Anything else the server says that you didn't expect raises `ProtocolError`.

### Opening connections

| call | use |
|---|---|
| `openFlow(url)` | `redis://[user:pass@]host[:port][/db]`, `rediss://` (TLS), `unix:///path`, or `host:port` |
| `openFlow(host, port, cfg)` | explicit |
| `openFlow(cfg)` | localhost, or Sentinel-discovered if `cfg.sentinels` is set |
| `openUnixFlow(path, cfg)` | unix socket |

`Config` (use `defaultConfig()` / `initConfig(...)`): `username`, `password`, `db`, `clientName`, `protocol` (2 or 3), `connectTimeoutMs`, `readBufSize`, TLS fields, reconnection fields, Sentinel fields.

## 2. Many tasks, one connection

```nim
proc worker(c: Conn, id: int) {.flow.} =
  for i in 1 .. 100: discard c.incr("hits")

proc main() {.flow.} =
  let c = openFlow("127.0.0.1:6379")
  scope s:
    for id in 1 .. 1000: discard s.go worker(c, id)   # 100,000 INCRs, one socket
```

A command is encoded into the shared write buffer and sent at once; the server answers in order, and each task decodes its own reply when its turn comes. No per-command lock, no waiting for a neighbour's round trip. `c.stats` shows `commands`, `writes`, `reads`: `commands / reads` is your pipelining depth.

**Cancellation and timeouts are safe.** `withTimeout(50, c.get("k"))` or cancelling a task mid-wait never desynchronises the connection: the abandoned reply is read and dropped by whoever reads next.

**One thing a shared connection can't do:** anything that *occupies* it. `BLPOP`, `XREAD BLOCK`, `WATCH`, `SUBSCRIBE` need a connection of their own: `pool.withConn(c): ...` or a separate `openFlow`.

## 3. Batches and transactions

```nim
let b = c.batch()                 # nothing is sent yet
b.set("a", "1")
let i = b.incr("a")               # each call returns its reply's index
let r = b.commit()                # ONE write, then all the replies
echo r[i].to(int)

let tx = c.atomic()               # MULTI ... EXEC
tx.incrBy("balance", -10); tx.incrBy("other", 10)
let results = tx.commit()         # results of the queued commands; tx.aborted if WATCH tripped
```

A batch's bytes are appended in one uninterrupted step, so other tasks can never interleave inside a `MULTI`/`EXEC`. Error replies come back as `rkError` values (`commit(raiseOnError = true)` raises the first one after reading all replies, so the connection stays in sync). Convert replies with `r[i].to(T)`: `string`, `int`, `bool`, `float`, `Option[T]`, `seq[T]`, `seq[(A,B)]`.

Optimistic locking (`WATCH`) needs an exclusive connection, see `examples/ex3_pipeline_tx.nim`.

## 4. Pool

`openPool(size, maxLeased, host, port, cfg)` (or `openPool(url)`):

* `pool.get(...)`, `pool.set(...)`: any command runs on the next shared connection (round-robin), retried when safe (section 6).
* `pool.withConn(c): ...`: lends one connection to you alone, for blocking commands, `WATCH`, subscriptions.

A dead shared connection is replaced automatically.

## 5. TLS

```nim
var cfg = defaultConfig()
cfg.tls = true
cfg.tlsCaFile = "ca.pem"                  # "" = system trust store
cfg.tlsCertFile = "client.crt"; cfg.tlsKeyFile = "client.key"   # mutual TLS
let c = openFlow("redis.example.com", 6380, cfg)   # or openFlow("rediss://redis.example.com:6380")
```

TLS 1.2+; the server certificate **and hostname** are verified (`cfg.tlsServerName` overrides the name for SNI and the check); `cfg.tlsInsecure = true` disables verification and exists for tests only. A bad certificate raises `ConnectionError` immediately (it is not retried). OpenSSL (`libssl`) is loaded when the first TLS connection is made, so non-TLS programs need no OpenSSL.

## 6. Failure handling

**Reconnection.** When a connection breaks, the next command reconnects it first, with exponential backoff and jitter (`maxAttempts` default 6, `retryBaseMs` 50, `retryMaxMs` 2000), then repeats the handshake (`HELLO`/`AUTH`/`SELECT`/`CLIENT SETNAME`). Many tasks hitting a dead connection share one reconnect. `Config.noReconnect = true` turns it off. `c.reconnect()` forces a fresh connection; `c.reconnects` counts them.

**What you see:**

| situation | exception | outcome of your command |
|---|---|---|
| couldn't (re)connect | `ConnectFailed` | **not sent**, always safe to retry |
| connection lost while waiting for the reply | `ConnectionError` | **unknown**: it may have been applied |
| the server refused it | `ServerError` | not applied |

**Retries.** `Pool` and `Cluster` retry for you, but only where that cannot double-apply: always after `ConnectFailed`; after a lost connection only for idempotent commands (reads, `SET`, `DEL`, `HSET`, `EXPIRE`, ...); never for `INCR`, `LPUSH`, `APPEND`, ... Also retried: `READONLY` (a demoted master after failover), `LOADING`, `TRYAGAIN`, `MASTERDOWN`, `CLUSTERDOWN`. `pool.maxRetries` (default 3) and `cluster.maxRedirects` (default 8) bound it.

**Subscribers** re-subscribe nothing on their own; see section 9.

## 7. Sentinel

```nim
var cfg = defaultConfig()
cfg.sentinels = @[("s1", 26379), ("s2", 26379), ("s3", 26379)]
cfg.masterName = "mymaster"
let c = openFlow(cfg)             # or openPool(4, 8, opts = cfg)
```

The sentinels are asked in order (dead ones skipped, 1 s connect limit unless `connectTimeoutMs` is set); the address is then verified with `ROLE`. After a failover: a command on the old master fails (`ConnectionError`, or `READONLY` if it was demoted and the connection drops), the connection re-asks the sentinels on its next use, and `Pool` retries transparently. `cfg.useReplica = true` connects to a healthy replica; `cfg.sentinelPassword` authenticates to the sentinels.

## 8. Cluster

```nim
let cl = openCluster("10.0.0.1:7000,10.0.0.2:7000")   # any seeds
discard cl.set("user:1", "x")                          # routed by CRC16 slot
cl.mset({"{cart}:a": "1", "{cart}:b": "2"})            # hash tags: same slot
let tx = cl.connFor("{cart}:a").atomic()               # transaction on one slot
```

`MOVED`/`ASK` are followed, the topology is re-read when needed (one task does it, the rest wait), and a dead node produces a bounded `ConnectFailed`/`CLUSTERDOWN` error, not a hang. Multi-key commands need keys in one slot (`CROSSSLOT` otherwise); `cl.delAcross(keys)` and `cl.mgetAcross(keys)` split by slot. Per-node commands have cluster-wide forms: `cl.totalKeys()`, `cl.allKeys(match)`, `cl.wipeAll()`, `cl.masterConns()`. For blocking commands and pub/sub use `cl.openDedicated()`.

## 9. Pub/sub, streams, scripts

```nim
let sub = newSubscriber(openFlow("127.0.0.1:6379"))
sub.subscribe("news"); sub.psubscribe("log.*")
let m = sub.nextMessage()                 # cancel-safe: withTimeout(100, sub.nextMessage())
echo m.kind, m.channel, m.data
```

After a reconnect a subscriber must subscribe again (`nextMessage` raises `ConnectionError` when the link drops).

Streams: `xadd`, `xrange`, `xread(c, {"s": "$"}, blockMs = 1000)`, `xreadGroup`, `xack`, ... return `StreamEntry` (`e.id`, `e["field"]`). `maxlen = approx(1000)` caps a stream.

Scripts: `let s = newScript("return redis.call('incr', KEYS[1])")`, `c.run(s, ["k"], [])`: sends `EVALSHA` (hash computed locally) and falls back to `EVAL` once if the server hasn't seen it.

## 10. Timeouts

`withTimeout(ms, c.get("k"))` bounds any call; the connection stays in sync. `connectTimeoutMs` bounds connecting (including the TLS handshake). There is deliberately no hidden per-command timer on the hot path.
