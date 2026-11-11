# Coming from nim-lang/redis

redwater is an independent implementation with its own vocabulary and a different execution model (Stagelane flow procs instead of `asyncdispatch`). Command names are Redis's own (`get`, `hset`, `zrange`...); what changed is everything around them.

| concept | nim-lang/redis | redwater |
|---|---|---|
| connect (non-blocking) | `await openAsync()` | `openFlow()` |
| connection type | `Redis`, `AsyncRedis` | `Conn` (one type) |
| waiting | `await`, `Future[T]` | none: `{.flow.}` procs |
| nil reply | sentinel `redisNil` | `Option[string]` / `none` |
| reply value | `RedisValue` (`vkString`, `.strVal`) | `Reply` (`rkString`, `.str`, `.num`, `.elems`) |
| server error | `RedisError` | `ServerError` (`.code`) |
| bad reply | `ReplyError` | `ProtocolError` |
| lost connection | generic `IOError` | `ConnectionError` / `ConnectFailed` |
| pipelining | `startPipelining` / `flushPipeline` | `let b = c.batch(); ...; b.commit()` |
| transaction | `multi` / `exec` | `c.atomic()` ... `.commit()` |
| arbitrary command | `rawCommand` | `c.call("OBJECT", "HELP")` |
| set + ignore | `setk` | `discard c.set(k, v)` |
| `select` | `select` | `useDb` |
| echo | `echoServ` | `c.ping(message)` |
| exists (n keys) | `exists` | `exists(key): bool`, `countExisting(keys)` |
| options | positional / string flags | named: `set(k, v, ex = 60, nx = true)` |
| settings | arguments to `open` | `Config` (`initConfig(...)`) |
| TLS, Sentinel, Cluster, reconnect | not available | built in |

Behaviour differences worth knowing:

* One `Conn` is shared by any number of tasks; you don't need a connection per task.
* `Batch` queues plain procs (nothing awaits); the reply index is the return value.
* `hgetAll` returns `seq[(string, string)]`; sorted-set range commands with scores return `seq[(string, float)]`.
* A lost connection reconnects on the next command; in-flight commands raise instead of being silently re-sent.
