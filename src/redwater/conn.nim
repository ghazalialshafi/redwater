## redwater/conn - the connection layer, built directly on the Stagelane runtime.
##
## There is no `Future`, no `await`, no `asyncdispatch`. Every operation that can
## wait is a Stagelane `{.flow.}` proc and reads like ordinary synchronous code.
## Socket I/O is non-blocking: `recv`/`send` are tried first and the task parks
## on `waitReadable` / `waitWritable` only when the kernel says EAGAIN.
##
## **One connection, many tasks (automatic pipelining).** Any number of tasks on
## the same scheduler thread may use one `Redis` at once. A command is encoded
## into a shared write buffer and given a *ticket* in one uninterrupted step;
## replies come back in ticket order, and each task decodes its own reply when
## its turn comes. Requests therefore do not wait for each other's round trip,
## and there is no per-command lock.
##
## **Cancellation is safe.** A task cancelled (or timed out) while it waits for
## its reply gives its ticket up; whoever reads next discards that reply. The
## connection stays in sync. Only a cancellation in the middle of *writing* a
## command to a full socket can leave a half-sent request, and that marks the
## connection broken (`ConnectionError` from then on) rather than guessing.

import std/[options, sets, strutils, nativesockets, posix, uri, random]
import stagelane, stagelane/net
import ./resp, ./tls
export resp

type
  Config* = object
    ## Connection settings. Every field has a working zero value.
    username*: string
    password*: string
    db*: int                  ## `SELECT` this database after connecting
    clientName*: string       ## `CLIENT SETNAME`
    protocol*: int            ## 2 (default) or 3 (RESP3, via `HELLO 3`)
    connectTimeoutMs*: int    ## 0 = no limit
    readBufSize*: int         ## initial receive buffer, bytes
    tcpNoDelay*: bool         ## default true (via `defaultConfig`): no Nagle delay
    keepAlive*: bool          ## default true (via `defaultConfig`): TCP keep-alive
    # --- TLS
    tls*: bool                ## encrypt the connection
    tlsInsecure*: bool        ## DON'T verify the server certificate (testing only)
    tlsCaFile*: string        ## trusted CA bundle (PEM); "" = system trust store
    tlsCaDir*: string
    tlsCertFile*: string      ## client certificate chain, for mutual TLS
    tlsKeyFile*: string
    tlsServerName*: string    ## SNI / hostname to verify; "" = the host dialled
    # --- reconnection
    noReconnect*: bool        ## fail instead of reconnecting a broken connection
    maxAttempts*: int         ## dial attempts per reconnect (0 = 6)
    retryBaseMs*: int         ## first backoff delay (0 = 50 ms), doubled each try
    retryMaxMs*: int          ## backoff ceiling (0 = 2000 ms); +/-25% jitter
    # --- Sentinel
    sentinels*: seq[(string, int)]  ## sentinel addresses; with `masterName` the
                                    ## server address is discovered, not given
    masterName*: string       ## the monitored master's name
    useReplica*: bool         ## connect to a replica of `masterName` instead
    sentinelPassword*: string

  ConnStats* = object
    ## Cheap always-on counters. `commands / writes` is your pipelining depth.
    commands*, writes*, reads*: int64
    bytesOut*, bytesIn*: int64

  Conn* = ref object
    ## A connection to a Redis / Valkey server. Share it freely between tasks
    ## on one scheduler thread; see the module docs.
    fd: SocketHandle
    rb: RBuf
    wb*: string               ## write buffer (internal: commands are encoded here)
    wOff: int                 ## bytes of `wb` already sent
    nextTicket, readTurn: int
    turnQ: WaitQueue
    orphans: HashSet[int]
    loose: bool               ## a waiter woke out of order: wake all, not one
    writeParked, readParked: bool
    broken*: bool
    closed*: bool
    ssl: SslPtr
    tlsCtx: TlsContext
    gen: int                  ## bumped on every reconnect: stale waiters notice
    reviving: bool
    reviveQ: WaitQueue
    flushWaitsRead: bool
    lastIoError: string
    opts*: Config
    host*: string
    port*: int
    path*: string
    stats*: ConnStats
    reconnects*: int          ## how many times this connection was re-established
    pushes*: seq[Reply]  ## RESP3 push messages seen while idle-reading

proc defaultConfig*(): Config =
  Config(protocol: 2, readBufSize: 16 * 1024, tcpNoDelay: true, keepAlive: true)

proc initConfig*(username = "", password = "", db = 0, clientName = "",
                   protocol = 2, connectTimeoutMs = 0, readBufSize = 16 * 1024,
                   tcpNoDelay = true, keepAlive = true): Config =
  Config(username: username, password: password, db: db,
           clientName: clientName, protocol: protocol,
           connectTimeoutMs: connectTimeoutMs, readBufSize: readBufSize,
           tcpNoDelay: tcpNoDelay, keepAlive: keepAlive)

# ----------------------------------------------------------------------------
# errors
# ----------------------------------------------------------------------------

proc connErr(msg: string) {.noinline, noreturn.} =
  raise newException(ConnectionError, msg)

proc osMsg(prefix: string, e: cint): string =
  prefix & ": " & $strerror(e)

proc checkUsable*(c: Conn) {.inline.} =
  if c.closed: connErr("connection is closed")
  if c.broken: connErr("connection is broken")

proc isConnected*(c: Conn): bool = not c.closed and not c.broken

template begin*(c: Conn, nargs: int): untyped =
  ## starts encoding a command of `nargs` arguments into the connection's write
  ## buffer. Encode every argument with `c.wb.addArg`, then call `submit`, with
  ## no suspension in between.
  ensureLive(c)
  c.wb.addArrayHeader(nargs)

# ----------------------------------------------------------------------------
# socket plumbing (plain procs: they never wait)
# ----------------------------------------------------------------------------

proc setSockFlag(fd: SocketHandle, level, opt: cint) =
  var one: cint = 1
  discard setsockopt(fd, level, opt, addr one, SockLen(sizeof(one)))

proc closeFd(c: Conn) =
  if c.ssl != nil:
    tlsClose(c.ssl)
    c.ssl = nil
  if c.fd != osInvalidSocket:
    forgetFd(int(c.fd))                  # the scheduler tracks watched fds: drop it first
    discard posix.close(c.fd)
    c.fd = osInvalidSocket

proc wakeAll(c: Conn) =
  notifyAll(c.turnQ)

proc markBroken*(c: Conn) =
  ## Declares the connection dead (tasks waiting on it get `ConnectionError`).
  ## The next command reconnects it, unless `Config.noReconnect` is set.
  if not c.broken:
    c.broken = true
    if c.fd != osInvalidSocket: discard posix.shutdown(c.fd, SHUT_RDWR)
  wakeAll(c)

proc close*(c: Conn) =
  ## Closes the connection for good (it will not reconnect). Tasks waiting on
  ## it get a `ConnectionError`.
  if c.closed: return
  c.closed = true
  if c.fd != osInvalidSocket:
    discard posix.shutdown(c.fd, SHUT_RDWR)
    # a parked task still has the fd registered: the reconnect/exit path closes it
    if not c.readParked and not c.writeParked: closeFd(c)
  wakeAll(c)
  notifyAll(c.reviveQ)

# ----------------------------------------------------------------------------
# transport: plain TCP/unix or TLS behind one pair of calls
# ----------------------------------------------------------------------------

proc ioSend(c: Conn, p: pointer, n: int): int =
  ## bytes sent (> 0), or `ioWantWrite` / `ioWantRead` (wait, then retry) /
  ## `ioError` (`c.lastIoError` says why)
  if c.ssl != nil:
    result = tlsWrite(c.ssl, p, n)
    if result == ioError: c.lastIoError = "TLS write failed: " & tlsLastError()
    return
  while true:
    let r = posix.send(c.fd, p, n, MSG_NOSIGNAL)
    if r >= 0: return (if r == 0: ioWantWrite else: int(r))
    let e = errno
    if e == EINTR: continue
    if e == EAGAIN or e == EWOULDBLOCK: return ioWantWrite
    c.lastIoError = osMsg("send failed", e)
    return ioError

proc ioRecv(c: Conn, p: pointer, n: int): int =
  ## bytes read (> 0), `ioEof`, `ioWantRead` / `ioWantWrite`, or `ioError`
  if c.ssl != nil:
    result = tlsRead(c.ssl, p, n)
    if result == ioError: c.lastIoError = "TLS read failed: " & tlsLastError()
    return
  while true:
    let r = posix.recv(c.fd, p, n, 0)
    if r > 0: return int(r)
    if r == 0: return ioEof
    let e = errno
    if e == EINTR: continue
    if e == EAGAIN or e == EWOULDBLOCK: return ioWantRead
    c.lastIoError = osMsg("recv failed", e)
    return ioError

# ----------------------------------------------------------------------------
# write side
# ----------------------------------------------------------------------------

proc trySend(c: Conn): bool =
  ## Sends as much of the write buffer as the transport takes right now.
  ## Returns true when the buffer is empty. Never waits.
  while c.wOff < c.wb.len:
    let r = c.ioSend(unsafeAddr c.wb[c.wOff], c.wb.len - c.wOff)
    if r > 0:
      c.wOff += r
      c.stats.writes.inc
      c.stats.bytesOut += r
    elif r == ioWantWrite or r == ioWantRead:
      c.flushWaitsRead = (r == ioWantRead)
      return false
    else:
      c.markBroken()
      connErr(c.lastIoError)
  c.wb.setLen(0)
  c.wOff = 0
  true

proc flushSlow(c: Conn) {.flow.} =
  ## The rare path: the socket buffer is full. One task waits for writability and
  ## drains everything, including bytes other tasks append meanwhile.
  if c.writeParked: return
  let g = c.gen
  c.writeParked = true
  try:
    while not c.trySend():
      if c.flushWaitsRead: waitReadable(int(c.fd))
      else: waitWritable(int(c.fd))
      if c.gen != g: connErr("connection was reset while writing")
      if c.closed or c.broken: connErr("connection closed while writing")
  except CatchableError, Defect:
    # cancelled or failed mid-write: a half-sent command may be on the wire
    c.writeParked = false
    if c.gen == g: c.markBroken()
    if c.closed: closeFd(c)
    raise
  c.writeParked = false

# ----------------------------------------------------------------------------
# tickets and replies
# ----------------------------------------------------------------------------

proc eligible(c: Conn, t: int): bool =
  ## true when every ticket before `t` is already consumed or orphaned
  if c.readTurn == t: return true
  if c.orphans.len == 0: return false
  for i in c.readTurn ..< t:
    if i notin c.orphans: return false
  true

proc framed(c: Conn): int {.inline.} =
  try:
    result = c.rb.peek()
  except ProtocolError:
    c.markBroken()
    raise

proc fill(c: Conn) {.flow.} =
  ## reads once from the transport, parking only when there is nothing to read
  let want = if c.rb.need > 0: c.rb.need - c.rb.buffered else: 0
  c.rb.ensureSpace(max(want, 4096))
  let g = c.gen
  while true:
    if c.closed or c.broken:
      if c.closed: closeFd(c)
      connErr(if c.closed: "connection is closed" else: "connection is broken")
    let r = c.ioRecv(c.rb.writePtr, c.rb.writeCap)
    if r > 0:
      c.rb.advanceW(r)
      c.stats.reads.inc
      c.stats.bytesIn += r
      return
    if r == ioEof:
      c.markBroken()
      connErr("connection closed by server")
    if r == ioError:
      c.markBroken()
      connErr(c.lastIoError)
    c.readParked = true
    try:
      if r == ioWantWrite: waitWritable(int(c.fd))
      else: waitReadable(int(c.fd))
    except CatchableError, Defect:
      c.readParked = false
      raise
    c.readParked = false
    if c.gen != g: connErr("connection was reset")

proc nextComplete(c: Conn, filterPush: bool): int {.flow.} =
  ## length of the next complete reply, reading from the socket as needed
  while true:
    let n = c.framed()
    if n > 0:
      if filterPush and c.rb.firstByte == '>':
        c.pushes.add c.rb.takeValue(n)           # RESP3 push: not our reply
        if c.pushes.len > 1024: c.pushes.delete(0)
        continue
      return n
    c.fill()

proc abandon(c: Conn, t: int) =
  ## the task owning ticket `t` will never read its reply
  c.orphans.incl t
  c.loose = true
  wakeAll(c)

proc finish(c: Conn, t: int) {.inline.} =
  ## reply `t` is consumed; let the next ticket-holder go
  c.readTurn = t + 1
  if c.readTurn == c.nextTicket:
    c.loose = false
  elif c.loose: notifyAll(c.turnQ)
  else: discard notifyOne(c.turnQ)

proc awaitReply(c: Conn, t: int, filterPush: bool): int {.flow.} =
  ## Waits for this ticket's turn and returns the byte length of its reply, which
  ## is then at the read position of the receive buffer.
  try:
    while not c.eligible(t):
      if t < c.readTurn: connErr("connection was reset")
      if c.closed or c.broken: checkUsable(c)
      park(c.turnQ)
      if not c.eligible(t) and not c.loose:
        # woken out of order (tickets parked in a different order than they were
        # taken): our wake-up may have been meant for someone else. From now on
        # wake everybody on each reply, and pass this one on right away.
        c.loose = true
        notifyAll(c.turnQ)
    while c.readTurn < t:
      # replies of tickets whose owners gave up: read and drop them
      let k = c.nextComplete(false)
      c.rb.skip(k)
      c.orphans.excl c.readTurn
      inc c.readTurn
    result = c.nextComplete(filterPush)
  except CancelledError:
    c.abandon(t)
    raise

proc stashPush(c: Conn, n: int) =
  c.pushes.add c.rb.takeValue(n)               # RESP3 push: not our reply
  if c.pushes.len > 1024: c.pushes.delete(0)

template awaitReplyT(c: Conn, t: int, filterPush: bool, n: untyped) =
  ## Same as `awaitReply`, but when it is already our turn (the usual case) the
  ## whole wait is inlined into the calling flow proc: no extra flow frames, and
  ## a task only enters the slow path (`awaitReply`) when it has to queue
  ## behind another ticket.
  var n = 0
  if c.readTurn == t:
    try:
      while true:
        n = c.framed()
        if n > 0:
          if filterPush and c.rb.firstByte == '>':
            c.stashPush(n)
            continue
          break
        c.fill()
    except CancelledError:
      c.abandon(t)
      raise
  else:
    n = c.awaitReply(t, filterPush)

# --- typed readers -----------------------------------------------------------

proc failReply(c: Conn, t: int, n: int, want: string) {.noinline.} =
  ## consumes the reply (the stream stays in sync) and raises
  let v = c.rb.takeValue(n)
  c.finish(t)
  if v.kind == rkError:
    if c.opts.masterName.len > 0 and v.str.startsWith("READONLY"): c.markBroken()
    raise newServerError(v.str)
  raise newException(ProtocolError, "expected " & want & ", got " & $v.kind)

proc replyValue*(c: Conn, t: int): Reply {.flow.} =
  ## the reply for ticket `t` as a `Reply` (error replies are *returned*
  ## as `rkError`, not raised)
  awaitReplyT(c, t, true, n)
  result = c.rb.takeValue(n)
  c.finish(t)

proc replyInt*(c: Conn, t: int): int64 {.flow.} =
  awaitReplyT(c, t, true, n)
  var v: int64
  if c.rb.takeInt(n, v):
    c.finish(t)
    return v
  if c.rb.firstByte == '$':                 # e.g. a numeric bulk
    var s: string
    discard c.rb.takeBulk(n, s)
    c.finish(t)
    return parseBiggestInt(s)
  c.failReply(t, n, "integer")

proc replyBool*(c: Conn, t: int): bool {.flow.} =
  ## `:1` / `:0` / `+OK` / RESP3 `#t`; a nil reply is `false`
  awaitReplyT(c, t, true, n)
  var v: int64
  if c.rb.takeInt(n, v):
    c.finish(t)
    return v != 0
  if c.rb.firstByte == '+':                   # "+OK" is by far the common case: no allocation
    let isOk = n == 5 and c.rb.data[c.rb.r + 1] == 'O' and c.rb.data[c.rb.r + 2] == 'K'
    c.rb.skip(n)
    c.finish(t)
    return isOk
  let v2 = c.rb.takeValue(n)
  c.finish(t)
  case v2.kind
  of rkStatus: return v2.str == "OK"
  of rkBool: return v2.flag
  of rkNil: return false
  of rkError: raise newServerError(v2.str)
  else: raise newException(ProtocolError, "expected boolean, got " & $v2.kind)

proc replyOk*(c: Conn, t: int) {.flow.} =
  ## a status reply; raises `ServerError` for an error reply
  awaitReplyT(c, t, true, n)
  if c.rb.firstByte == '+':
    c.rb.skip(n)
    c.finish(t)
    return
  c.failReply(t, n, "status")

proc replyStr*(c: Conn, t: int): Option[string] {.flow.} =
  ## a bulk string; `none` for a nil reply
  awaitReplyT(c, t, true, n)
  var s: string
  case c.rb.takeBulk(n, s)
  of bkString:
    c.finish(t)
    return some(move s)
  of bkNil:
    c.finish(t)
    return none(string)
  of bkOther:
    c.failReply(t, n, "bulk string")

proc replyText*(c: Conn, t: int): string {.flow.} =
  ## a bulk or status string; "" for nil
  awaitReplyT(c, t, true, n)
  var s: string
  case c.rb.takeBulk(n, s)
  of bkString:
    c.finish(t)
    return s
  of bkNil:
    c.finish(t)
    return ""
  of bkOther:
    if c.rb.firstByte == '+':
      let v = c.rb.takeValue(n)
      c.finish(t)
      return v.str
    c.failReply(t, n, "string")

proc replyChecked*(c: Conn, t: int): Reply {.flow.} =
  ## like `replyValue`, but a server error reply raises `ServerError`
  let v = c.replyValue(t)
  if v.kind == rkError: raise newServerError(v.str)
  result = v

proc replyTo*[T](c: Conn, t: int, _: typedesc[T]): T {.flow.} =
  ## the reply converted with `Reply.to(T)`
  let v = c.replyChecked(t)
  result = v.to(T)

# ----------------------------------------------------------------------------
# submitting commands
# ----------------------------------------------------------------------------

proc submit*(c: Conn): int {.flow.} =
  ## Hands the encoded command(s) to the kernel and returns the ticket. Only
  ## suspends when the socket buffer is full.
  let t = c.nextTicket
  c.nextTicket += 1
  c.stats.commands += 1
  if not c.trySend(): c.flushSlow()
  result = t

proc takeTicket*(c: Conn): int {.inline.} =
  ## internal: the next ticket (counts the command)
  result = c.nextTicket
  c.nextTicket += 1
  c.stats.commands += 1

proc sendNow*(c: Conn): bool {.inline.} =
  ## internal: non-blocking send of the write buffer; false if the kernel did
  ## not take it all
  c.trySend()

proc flushWait*(c: Conn) {.flow.} =
  ## internal: the slow path of a send (socket buffer full)
  c.flushSlow()

template submitT*(c: Conn, t: untyped) =
  ## `submit` inlined: the only call that can wait (`flushWait`) is made only
  ## when the kernel did not accept the whole command.
  let t = c.takeTicket()
  if not c.sendNow(): c.flushWait()

proc submitMany(c: Conn, k: int): int {.flow.} =
  let t = c.nextTicket
  c.nextTicket += k
  c.stats.commands += k
  if not c.trySend(): c.flushSlow()
  result = t

# ----------------------------------------------------------------------------
# establishing connections: dial, TLS, Sentinel, reconnect
# ----------------------------------------------------------------------------

proc newConn(opts: Config): Conn =
  result = Conn(opts: opts, rb: initRBuf(if opts.readBufSize > 0: opts.readBufSize else: 16384),
                turnQ: newWaitQueue(), reviveQ: newWaitQueue(), fd: osInvalidSocket,
                orphans: initHashSet[int]())

proc callRaw(c: Conn, args: varargs[string]): Reply {.flow.} =
  ## `call` without the liveness check: used while the connection is being made
  if c.closed or c.broken: connErr("connection is not usable")
  c.wb.addArrayHeader(args.len)
  for a in args: c.wb.addArg(a)
  c.submitT(t)
  let v = c.replyValue(t)
  if v.kind == rkError: raise newServerError(v.str)
  result = v

proc handshake(c: Conn) {.flow.} =
  ## protocol version, credentials, database, name
  let o = c.opts
  if o.protocol == 3:
    var args = @["HELLO", "3"]
    if o.password.len > 0:
      args.add "AUTH"
      args.add (if o.username.len > 0: o.username else: "default")
      args.add o.password
    if o.clientName.len > 0:
      args.add "SETNAME"; args.add o.clientName
    discard c.callRaw(args)
  else:
    if o.password.len > 0:
      if o.username.len > 0: discard c.callRaw("AUTH", o.username, o.password)
      else: discard c.callRaw("AUTH", o.password)
    if o.clientName.len > 0: discard c.callRaw("CLIENT", "SETNAME", o.clientName)
  if o.db != 0: discard c.callRaw("SELECT", $o.db)

proc connectUnixFd(path: string): SocketHandle =
  let fd = createNativeSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  if fd == osInvalidSocket: raise newException(ConnectFailed, "cannot create unix socket")
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(posix.AF_UNIX)
  if path.len >= sizeof(sa.sun_path):
    discard posix.close(fd)
    raise newException(ConnectFailed, "socket path too long")
  copyMem(addr sa.sun_path[0], unsafeAddr path[0], path.len)
  if posix.connect(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) < 0:
    let e = errno
    discard posix.close(fd)
    raise newException(ConnectFailed, osMsg("connect to " & path & " failed", e))
  fd.setBlocking(false)
  watchFd(int(fd))                        # long-lived socket: register with the scheduler once
  fd

proc tlsHandshakeLoop(fd: SocketHandle, ssl: SslPtr) {.flow.} =
  while true:
    let r = tlsHandshake(ssl)
    if r == 1: return
    if r == ioWantRead: waitReadable(int(fd))
    elif r == ioWantWrite: waitWritable(int(fd))
    else:
      let why = tlsVerifyError(ssl)
      raise newException(ConnectionError, "TLS handshake failed: " & tlsLastError() &
                         (if why.len > 0: " (" & why & ")" else: ""))

proc dialAddr(c: Conn, host: string, port: int) {.flow.} =
  ## Replaces the socket with a fresh connection to `host:port` (or `c.path`),
  ## does the TLS handshake and the protocol handshake. Everything that was in
  ## flight on the old socket is abandoned.
  # 1. retire the old socket; tasks still parked on it wake and see `gen` change
  if c.fd != osInvalidSocket:
    discard posix.shutdown(c.fd, SHUT_RDWR)
    var spins = 0
    while (c.readParked or c.writeParked) and spins < 100:
      yieldNow()
      inc spins
    closeFd(c)
  # 2. new socket
  var fd = osInvalidSocket
  let where = if c.path.len > 0: c.path else: host & ":" & $port
  try:
    if c.path.len > 0:
      fd = connectUnixFd(c.path)
    else:
      var stream: TcpStream
      if c.opts.connectTimeoutMs > 0:
        stream = withTimeout(c.opts.connectTimeoutMs, connectTcp(host, port))
      else:
        stream = connectTcp(host, port)
      fd = stream.fd
      if c.opts.tcpNoDelay: setSockFlag(fd, cint(IPPROTO_TCP), TCP_NODELAY)
      if c.opts.keepAlive: setSockFlag(fd, SOL_SOCKET, SO_KEEPALIVE)
  except CancelledError:
    raise
  except ConnectFailed:
    raise
  except CatchableError as e:
    raise newException(ConnectFailed, "connect to " & where & " failed: " & e.msg)
  # 3. TLS
  var ssl: SslPtr = nil
  if c.opts.tls:
    try:
      if c.tlsCtx == nil:
        c.tlsCtx = newTlsContext(TlsSettings(
          verify: not c.opts.tlsInsecure, caFile: c.opts.tlsCaFile, caDir: c.opts.tlsCaDir,
          certFile: c.opts.tlsCertFile, keyFile: c.opts.tlsKeyFile))
      let sni = if c.opts.tlsServerName.len > 0: c.opts.tlsServerName else: host
      ssl = tlsNew(c.tlsCtx, fd, sni, not c.opts.tlsInsecure)
      if c.opts.connectTimeoutMs > 0:
        withTimeout(c.opts.connectTimeoutMs, tlsHandshakeLoop(fd, ssl))
      else:
        tlsHandshakeLoop(fd, ssl)
    except CancelledError:
      tlsClose(ssl); forgetFd(int(fd)); discard posix.close(fd)
      raise
    except CatchableError as e:
      tlsClose(ssl); forgetFd(int(fd)); discard posix.close(fd)
      if e of TimeoutError:
        raise newException(ConnectFailed, "TLS handshake with " & where & " timed out")
      raise newException(ConnectionError, e.msg)     # bad certificate / config: not retried
  # 4. install: a clean slate; tickets from before the reset are stale
  c.fd = fd
  c.ssl = ssl
  c.gen += 1
  c.readTurn = c.nextTicket
  c.orphans.clear()
  c.loose = false
  c.rb.reset()
  c.wb.setLen(0)
  c.wOff = 0
  c.pushes.setLen(0)
  c.writeParked = false
  c.readParked = false
  c.broken = false
  # 5. login, select, name; verify the role when Sentinel sent us here
  try:
    c.handshake()
    if c.opts.masterName.len > 0:
      let role = c.callRaw("ROLE")
      let want = if c.opts.useReplica: "slave" else: "master"
      if role.kind == rkList and role.elems.len > 0 and role.elems[0].to(string) != want:
        raise newException(ConnectFailed, where & " is not a " & want & " (failover in progress?)")
  except ConnectFailed:
    c.markBroken()
    raise
  except ConnectionError as e:
    c.markBroken()
    raise newException(ConnectFailed, "handshake with " & where & " failed: " & e.msg)
  except CancelledError:
    c.markBroken()
    raise

proc sentinelLookup(cfg: Config): tuple[host: string, port: int] {.flow.} =
  ## Asks the sentinels, in order, where the monitored master (or a healthy
  ## replica) is. The first sentinel that answers wins.
  var lastErr = "no sentinels configured"
  var host = ""
  var port = 0
  for sentinel in cfg.sentinels:
    let probeCfg = Config(protocol: 2, readBufSize: 4096, tcpNoDelay: true,
      noReconnect: true, connectTimeoutMs: (if cfg.connectTimeoutMs > 0: cfg.connectTimeoutMs else: 1000),
      password: cfg.sentinelPassword, tls: cfg.tls, tlsInsecure: cfg.tlsInsecure,
      tlsCaFile: cfg.tlsCaFile, tlsCaDir: cfg.tlsCaDir)
    let probe = newConn(probeCfg)
    var answered = false
    try:
      probe.dialAddr(sentinel[0], sentinel[1])
      if cfg.useReplica:
        let r = probe.callRaw("SENTINEL", "REPLICAS", cfg.masterName)
        for rep in r.elems:
          let kv = rep.toPairs(string, string)
          var ip, prt, flags: string
          for (k, v) in kv:
            if k == "ip": ip = v
            elif k == "port": prt = v
            elif k == "flags": flags = v
          if ip.len > 0 and prt.len > 0 and "s_down" notin flags and
             "o_down" notin flags and "disconnected" notin flags:
            host = ip; port = parseInt(prt); answered = true
            break
        if not answered: lastErr = "sentinel " & sentinel[0] & " knows no healthy replica"
      else:
        let r = probe.callRaw("SENTINEL", "GET-MASTER-ADDR-BY-NAME", cfg.masterName)
        if r.kind == rkList and r.elems.len == 2:
          host = r.elems[0].to(string)
          port = r.elems[1].to(int)
          answered = true
        else:
          lastErr = "sentinel " & sentinel[0] & ":" & $sentinel[1] & " does not know master '" & cfg.masterName & "'"
    except CancelledError:
      probe.close()
      raise
    except CatchableError as e:
      lastErr = "sentinel " & sentinel[0] & ":" & $sentinel[1] & ": " & e.msg
    probe.close()
    if answered: break
  if host.len == 0: raise newException(ConnectFailed, "sentinel lookup failed: " & lastErr)
  result = (host, port)

proc dialOnce(c: Conn) {.flow.} =
  if c.opts.masterName.len > 0:
    let a = sentinelLookup(c.opts)
    c.host = a.host
    c.port = a.port
  c.dialAddr(c.host, c.port)

proc backoffMs(o: Config, attempt: int): int =
  let base = if o.retryBaseMs > 0: o.retryBaseMs else: 50
  let cap = if o.retryMaxMs > 0: o.retryMaxMs else: 2000
  var d = base
  for _ in 1 ..< attempt:
    d = min(cap, d * 2)
  let jitter = d div 4
  result = d - jitter + (if jitter > 0: rand(2 * jitter) else: 0)

proc revive*(c: Conn) {.flow.} =
  ## Re-establishes a broken connection with exponential backoff and jitter
  ## (`Config.maxAttempts`, `retryBaseMs`, `retryMaxMs`). Concurrent callers
  ## share one attempt. Raises `ConnectFailed` when the attempts run out.
  ## Normally you never call this: every command does it when needed.
  if c.closed: connErr("connection is closed")
  if c.reviving:
    while c.reviving and not c.closed: park(c.reviveQ)
    if c.closed: connErr("connection is closed")
    if c.broken: raise newException(ConnectFailed, "reconnect failed")
    return
  if c.opts.noReconnect: raise newException(ConnectFailed, "connection is broken")
  c.reviving = true
  let maxAttempts = if c.opts.maxAttempts > 0: c.opts.maxAttempts else: 6
  var attempt = 0
  var lastMsg = ""
  var done = false
  var fatal: ref CatchableError = nil
  while not done:
    inc attempt
    try:
      c.dialOnce()
      done = true
    except CancelledError:
      c.reviving = false
      notifyAll(c.reviveQ)
      raise
    except ConnectFailed as e:
      lastMsg = e.msg
    except CatchableError as e:
      fatal = e                    # bad password, bad certificate, ...: retrying won't help
      done = true
    if not done:
      if attempt >= maxAttempts: break
      delay(backoffMs(c.opts, attempt))
  c.reviving = false
  notifyAll(c.reviveQ)
  if fatal != nil:
    c.broken = true
    raise fatal
  if not done:
    c.broken = true
    raise newException(ConnectFailed, "gave up reconnecting after " & $attempt & " attempts: " & lastMsg)
  c.reconnects += 1

proc livenessSlow*(c: Conn) {.flow.} =
  ## internal: slow path of `ensureLive`
  if c.closed: connErr("connection is closed")
  c.revive()

proc needsRevive*(c: Conn): bool {.inline.} = c.broken or c.closed or c.reviving

template ensureLive*(c: Conn) =
  ## Before encoding a command: reconnect first if the connection is broken.
  ## Nothing has been sent yet, so this is always safe.
  if c.needsRevive(): c.livenessSlow()

proc readFrame*(c: Conn): Reply {.flow.} =
  ## Reads the next frame the server sends, without matching it to a command.
  ## For connections in subscriber mode (see `pubsub`); never mix with commands
  ## in flight. Cancel-safe: nothing is consumed until a whole frame is there.
  let n = c.nextComplete(false)
  result = c.rb.takeValue(n)

proc sendRaw*(c: Conn, args: varargs[string]) {.flow.} =
  ## Sends a command without waiting for (or tracking) its reply.
  ensureLive(c)
  c.wb.addArrayHeader(args.len)
  for a in args: c.wb.addArg(a)
  discard c.submit()

# ----------------------------------------------------------------------------
# pipelines and transactions
# ----------------------------------------------------------------------------

type
  Batch* = ref object
    ## A batch of commands sent in one write. Queue commands with the ordinary
    ## command names (`p.set(..)`, `p.incr(..)`: plain procs, nothing waits),
    ## then `commit` once. Each queue call returns the index of its reply.
    c*: Conn
    buf*: string              ## encoded commands (internal)
    count*: int
    tx*: bool                 ## wrap in MULTI / EXEC (atomic)
    aborted*: bool            ## set by `commit` when a WATCHed key changed

proc batch*(c: Conn): Batch =
  ## A new batch on `c`.
  Batch(c: c)

proc atomic*(c: Conn): Batch =
  ## A new transaction: the queued commands run atomically (`MULTI` ... `EXEC`).
  ## `commit` returns the results of the queued commands.
  Batch(c: c, tx: true)

proc len*(p: Batch): int = p.count
proc clear*(p: Batch) =
  p.buf.setLen(0); p.count = 0; p.aborted = false

proc queue*(p: Batch, args: varargs[string]): int {.discardable.} =
  ## queues any command
  p.buf.addArrayHeader(args.len)
  for a in args: p.buf.addArg(a)
  result = p.count
  inc p.count

proc commit*(p: Batch, raiseOnError: bool = false): seq[Reply] {.flow.} =
  ## Sends every queued command in a single write and reads all the replies.
  ## For a `atomic` transaction the result holds the queued commands' results
  ## (empty and `p.aborted` if a WATCHed key changed). Server error replies are
  ## returned as `rkError` values; with `raiseOnError` the first one is raised
  ## after all replies have been read, so the connection stays in sync.
  let c = p.c
  ensureLive(c)
  let k = p.count
  p.aborted = false
  if k == 0: return
  let total = if p.tx: k + 2 else: k
  if p.tx:
    c.wb.addArrayHeader(1); c.wb.addArg "MULTI"
  c.wb.add p.buf
  if p.tx:
    c.wb.addArrayHeader(1); c.wb.addArg "EXEC"
  p.buf.setLen(0)
  p.count = 0
  let t0 = c.submitMany(total)
  var replies = newSeqOfCap[Reply](total)
  var i = 0
  try:
    while i < total:
      let v = c.replyValue(t0 + i)
      replies.add v
      inc i
  except CancelledError:
    for j in i + 1 ..< total: c.abandon(t0 + j)
    raise
  if p.tx:
    let r = replies[total - 1]
    case r.kind
    of rkList: result = r.elems
    of rkNil: p.aborted = true
    of rkError: raise newServerError(r.str)
    else: raise newException(ProtocolError, "unexpected EXEC reply: " & $r.kind)
  else:
    result = move replies
  if raiseOnError:
    for v in result:
      if v.kind == rkError: raise newServerError(v.str)

# ----------------------------------------------------------------------------
# opening a connection
# ----------------------------------------------------------------------------

proc call*(c: Conn, args: varargs[string]): Reply {.flow.} =
  ## Sends any command and returns the reply, e.g. `c.call("OBJECT", "HELP")`.
  ## A server error reply raises `ServerError`.
  ensureLive(c)
  c.wb.addArrayHeader(args.len)
  for a in args: c.wb.addArg(a)
  c.submitT(t)
  let v = c.replyValue(t)
  if v.kind == rkError: raise newServerError(v.str)
  result = v

proc parseRedisUrl*(url: string): tuple[host: string, port: int, path: string, opts: Config] =
  ## `redis://[user:pass@]host[:port][/db]`, `unix:///path/to.sock[?db=N]`
  ## (`rediss://` is rejected: there is no TLS transport yet)
  let u = parseUri(if "://" in url: url else: "redis://" & url)
  result.opts = defaultConfig()
  case u.scheme
  of "redis": discard
  of "unix":
    result.path = u.path
  of "rediss": result.opts.tls = true
  else: raise newException(ValueError, "unsupported scheme in url: " & url)
  result.host = if u.hostname.len > 0: u.hostname else: "127.0.0.1"
  result.port = if u.port.len > 0: parseInt(u.port) else: 6379
  result.opts.username = decodeUrl(u.username)
  result.opts.password = decodeUrl(u.password)
  if u.scheme == "redis":
    let p = u.path.strip(chars = {'/'})
    if p.len > 0: result.opts.db = parseInt(p)
  for k, v in decodeQuery(u.query):
    if k == "db": result.opts.db = parseInt(v)
    elif k == "protocol": result.opts.protocol = parseInt(v)

proc openFlow*(host: string, port: int, opts: Config = defaultConfig()): Conn {.flow.} =
  ## Opens a TCP connection (TLS when `opts.tls`). Non-blocking: the calling
  ## task parks while the connection is made, the thread keeps running others.
  let c = newConn(opts)
  c.host = host
  c.port = port
  try:
    c.dialAddr(host, port)
    if opts.masterName.len > 0: discard
  except CatchableError:
    c.close()
    raise
  result = c

proc openFlow*(opts: Config = defaultConfig()): Conn {.flow.} =
  ## Opens a connection to `127.0.0.1:6379`, or - if `opts.sentinels` and
  ## `opts.masterName` are set - to whatever the sentinels say is the master.
  let c = newConn(opts)
  c.host = "127.0.0.1"
  c.port = 6379
  try:
    c.dialOnce()
  except CatchableError:
    c.close()
    raise
  result = c

proc openUnixFlow*(path: string = "/var/run/redis/redis.sock", opts: Config = defaultConfig()): Conn {.flow.} =
  ## Opens a unix-domain-socket connection (lowest latency on one machine).
  let c = newConn(opts)
  c.path = path
  try:
    c.dialAddr("", 0)
  except CatchableError:
    c.close()
    raise
  result = c

proc openFlow*(url: string): Conn {.flow.} =
  ## Opens a connection from a URL such as `redis://:secret@localhost:6379/2`,
  ## `rediss://host` (TLS) or `unix:///tmp/redis.sock` (or just `localhost:6379`).
  let p = parseRedisUrl(url)
  if p.path.len > 0: result = openUnixFlow(p.path, p.opts)
  else: result = openFlow(p.host, p.port, p.opts)

proc reconnect*(c: Conn) {.flow.} =
  ## Forces a fresh connection now (drops the current one, if any). Tasks
  ## waiting on the old connection get `ConnectionError`.
  c.markBroken()
  c.revive()
