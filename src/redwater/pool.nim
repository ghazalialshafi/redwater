## redwater/pool - many connections behind one handle.
##
## A single `Redis` already carries any number of tasks (see `conn`), so most
## programs need exactly one. A pool is for two other situations:
##
## * **Spreading load** over several sockets (and with `-d:flowThreads`, over
##   several server-side event-loop turns): ordinary commands issued on the
##   pool go round-robin over a ring of shared, auto-pipelined connections.
## * **Exclusive use** of a connection, which is required by anything that
##   occupies it: blocking commands (`BLPOP`, `XREAD BLOCK`), `WATCH` /
##   optimistic transactions, `SUBSCRIBE`. `withConn` lends one connection to
##   one task and takes it back afterwards.

import stagelane
import std/strutils
import ./conn

type
  Pool* = ref object
    host*: string
    port*: int
    path*: string
    opts*: Config
    ring: seq[Conn]          ## shared connections, used round-robin
    reopening: seq[bool]
    cursor: int
    idle: seq[Conn]          ## exclusive connections not currently lent out
    gate: Semaphore           ## limits lent-out exclusive connections
    closed: bool
    maxRetries*: int          ## retries per command on the pool forms (default 3)

proc openPool*(size: int = 4, maxExclusive: int = 16, host: string = "127.0.0.1",
               port: int = 6379, opts: Config = defaultConfig()): Pool {.flow.} =
  ## Opens `size` shared connections now; exclusive ones are opened on demand,
  ## at most `maxExclusive` at a time.
  let p = Pool(host: host, port: port, opts: opts,
                    gate: newSemaphore(maxExclusive), maxRetries: 3)
  p.reopening = newSeq[bool](size)
  try:
    for i in 0 ..< size:
      p.ring.add (if opts.masterName.len > 0: openFlow(opts) else: openFlow(host, port, opts))
  except CatchableError:
    for c in p.ring: c.close()
    raise
  result = p

proc openPool*(url: string, size: int = 4, maxExclusive: int = 16): Pool {.flow.} =
  ## Pool from a `redis://` / `unix://` URL.
  let u = parseRedisUrl(url)
  result = openPool(size, maxExclusive, u.host, u.port, u.opts)
  result.path = u.path

proc dial(p: Pool): Conn {.flow.} =
  if p.opts.masterName.len > 0: result = openFlow(p.opts)     # ask the sentinels
  else: result = openFlow(p.host, p.port, p.opts)

proc pick*(p: Pool): Conn {.flow.} =
  ## The next shared connection (round-robin), replacing it first if it died.
  ## Use it for ordinary commands; never for blocking ones.
  if p.closed: raise newException(ConnectionError, "pool is closed")
  var tries = 0
  while tries < p.ring.len:
    let i = p.cursor
    p.cursor = (p.cursor + 1) mod p.ring.len
    inc tries
    if p.ring[i].isConnected: return p.ring[i]
    if not p.reopening[i]:
      p.reopening[i] = true
      try:
        p.ring[i] = p.dial()
      except CatchableError:
        p.reopening[i] = false
        raise
      p.reopening[i] = false
      return p.ring[i]
  raise newException(ConnectionError, "no usable connection in the pool")

proc acquire*(p: Pool): Conn {.flow.} =
  ## Takes a connection for exclusive use. Waits if `maxExclusive` are lent
  ## out. Give it back with `release`, or use `withConn`.
  if p.closed: raise newException(ConnectionError, "pool is closed")
  p.gate.acquire()
  var got: Conn = nil
  while p.idle.len > 0:
    let c = p.idle.pop()
    if c.isConnected:
      got = c
      break
  if got == nil:
    try:
      got = p.dial()
    except CatchableError:
      p.gate.release()
      raise
  result = got

proc release*(p: Pool, c: Conn) =
  ## Returns an exclusive connection. A broken or closed one is discarded.
  if c.isConnected and not p.closed: p.idle.add c
  else: c.close()
  p.gate.release()

template withConn*(p: Pool, c: untyped, body: untyped) =
  ## Runs `body` with `c` bound to a connection that nobody else uses:
  ##
  ## ```nim
  ## pool.withConn(c):
  ##   c.watch("balance")
  ##   let bal = c.get("balance")
  ##   ...
  ## ```
  let c = p.acquire()
  try:
    body
  finally:
    p.release(c)

proc close*(p: Pool) =
  ## Closes every connection. Connections still lent out are closed when
  ## released.
  p.closed = true
  for c in p.ring: c.close()
  for c in p.idle: c.close()
  p.idle.setLen(0)

proc stats*(p: Pool): ConnStats =
  ## counters summed over the shared connections
  for c in p.ring:
    result.commands += c.stats.commands
    result.writes += c.stats.writes
    result.reads += c.stats.reads
    result.bytesOut += c.stats.bytesOut
    result.bytesIn += c.stats.bytesIn

proc shouldRetry*(p: Pool, failure: ref CatchableError, idempotent: bool, attempt: int): bool =
  ## internal: may a failed command be sent again?
  if attempt >= p.maxRetries or p.closed: return false
  if failure of ConnectFailed: return true            # nothing was sent: always safe
  if failure of ConnectionError: return idempotent    # in flight: outcome unknown
  if failure of ServerError:
    let code = ServerError(failure[]).code
    # rejected before executing, so safe: a demoted master (Sentinel failover),
    # a server still loading its dataset, a busy / unavailable cluster
    return code in ["READONLY", "LOADING", "TRYAGAIN", "MASTERDOWN", "CLUSTERDOWN"]
  false

proc pause*(p: Pool, attempt: int) {.flow.} =
  ## internal: exponential backoff between retries
  var d = 25
  for _ in 1 ..< attempt: d = min(1000, d * 2)
  delay(d)
