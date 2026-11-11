# Internals

## Layers

```
resp.nim      pure RESP2/RESP3: encode, frame (peek), decode. No sockets, no runtime.
tls.nim       non-blocking OpenSSL (lazy-loaded): read/write/handshake return want-read/want-write
conn.nim      Conn: transport, tickets, reconnect, Sentinel discovery, Batch
dsl.nim       {.cmd.} macro: one declaration -> Conn / Batch / Pool / Cluster procs
commands.nim  210 commands            pool.nim  shared ring + leases + retry policy
cluster.nim   slots, topology, redirects      pubsub / streams / scripting / extras
```

## Protocol engine

*Encoding* writes straight into the connection's write buffer: `*N\r\n`, then each argument as `$len\r\nbytes\r\n`. Integers are rendered into a 24-byte stack array; strings are `copyMem`'d. Nothing allocates except buffer growth.

*Framing:* `RBuf.peek` scans the receive buffer without allocating and returns the byte length of the next complete reply, or 0. An incomplete bulk string reports how many more bytes it needs, so a 3 MB value isn't rescanned per packet. Integers are validated during the scan so decoders can trust them.

*Decoding:* `:` and `$` replies decode straight into an `int64` / `string` (`takeInt`, `takeBulk`); `+OK` is recognised in place. Only aggregate replies build a `Reply` tree.

## The ticket protocol (shared connection)

1. A task encodes its command into the shared write buffer and takes the next *ticket* in one step with no suspension in between; the buffer order is the ticket order. It then `send`s whatever the kernel accepts (slow path: one task waits for writability and drains everything).
2. Replies come back in ticket order. The task whose ticket equals `readTurn` is the reader: it `recv`s (parking on `waitReadable` only on EAGAIN) until its reply is framed, decodes it, and passes the turn on (`notifyOne`).
3. **Cancelled waiters** add their ticket to an orphan set; whoever reads next reads and drops those replies first.
4. A woken task that isn't eligible (tickets parked out of order after a slow flush) switches the connection to wake-all mode until it drains. A lost wake-up here was a real bug found by the chaos test.
5. Fast paths are inlined into the generated command proc (`submitT`, `awaitReplyT`): in the common case a command is one flow frame, not five.

## Reconnection

A connection carries a *generation*. `dialAddr` retires the old socket (shutdown, wait for parked tasks to leave, close), installs the new one, bumps the generation, and sets `readTurn = nextTicket`. Every wait re-checks: a task parked on the old socket sees the generation change, a task parked for its turn sees `ticket < readTurn`; both raise `ConnectionError` instead of reading the new socket's bytes. `revive` is single-flight (others park on `reviveQ`), backs off exponentially with ±25% jitter, treats `ConnectFailed` as retryable and everything else (bad password, bad certificate) as fatal.

## Sentinel and Cluster

*Sentinel:* `dialOnce` asks each sentinel (`SENTINEL GET-MASTER-ADDR-BY-NAME` / `REPLICAS`), dials the answer, then checks `ROLE`; a stale answer raises `ConnectFailed` and the loop re-asks. A `READONLY` reply marks the connection broken so the next use re-resolves.

*Cluster:* CRC16/XMODEM with hash tags; `CLUSTER SLOTS` builds a 16384-entry table of node refs (live connections are kept across refreshes). `onFailure` maps an error to a verdict (retry now / retry after backoff / `ASK` / raise); the generated cluster proc loops on it. `ASK` sends `ASKING` and the command through a `Batch`, which appends both contiguously, so no other task can take the `ASKING` flag.

## The command DSL

`proc set*(key, value: string; ex: int = noArg; nx: bool = false): bool {.cmd: "SET".}` is parsed by the macro: positionals are sent in order, defaulted parameters are options (keyword = upper-cased name, sent only when changed), the return type selects an allocation-free decoder, and the idempotency table decides retry safety. Spec words: `@N` leading positionals, `+WORD` suffix, `#name` bare optional, `%name` count prefix, `$name` / `$-` cluster routing key.

## Measured design decisions

* **Write coalescing** (yield once so concurrent tasks share a `send`): implemented, measured **slower** under concurrency (~310k vs ~368k ops/s), removed.
* **Syscall floor:** `strace` of a sequential loop shows exactly one `sendto` + one `recvfrom` per command and almost no `epoll` calls, the same as a blocking client.
* **Inlining the await/submit fast paths:** about +5% sequential, higher pipelined; kept.

## Running on the bundled Stagelane

The new Stagelane keeps per-fd state (persistent, edge-triggered epoll registration). redwater follows its rules: every socket it creates itself is `watchFd`'d, every close is preceded by `forgetFd` (a reused fd number otherwise inherits stale state; this showed up as a hang opening a connection after another was closed), and a wait is entered only after `send`/`recv`/`SSL_*` reported "would block", which is what edge-triggering needs.
