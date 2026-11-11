## redwater/dsl - the `{.cmd.}` pragma that defines a Redis command once and
## generates every way to call it.
##
## ```nim
## proc set*(key, value: string; ex, px: int = noArg; nx, xx = false): bool {.cmd: "SET".} =
##   ## Sets `key`.
## ```
##
## becomes three procs from that single declaration:
##
## * `set(c: Conn, ...)` - a `{.flow.}` proc: encode, send, wait for the reply,
##   decode it into the declared return type.
## * `set(p: Batch, ...)` - queues the command, returns its reply index.
## * `set(pool: Pool, ...)` - runs it on the pool's next shared connection.
##
## Rules, so that the declaration *is* the documentation:
##
## * Parameters without a default are positional arguments, sent in order.
## * A parameter **with a default** is an option. It is sent only when it
##   differs from its default, preceded by its upper-cased name as the keyword
##   (`ex = 10` sends `EX 10`; a `bool` option sends just the keyword).
## * Options are sent after the leading positionals and before a trailing
##   `varargs` / `openArray` parameter (`ZADD key [NX] score member ...`).
##   `@N` in the spec fixes the number of leading positionals instead.
## * Words in the spec that start with `+` are sent last (`"ZRANGE +WITHSCORES"`).
## * `%name` in the spec sends the element count of that parameter just before
##   it (`"EVAL @2 %keys"` sends `EVAL script numkeys key.. arg..`).
## * `#name` in the spec marks an option that is sent as a bare value, without
##   its keyword (`"INFO #section"` sends `INFO` or `INFO server`).
## * The return type picks the decoder. `bool`, `int`, `int64`, `string`,
##   `Option[string]` and no result use allocation-free fast paths; anything
##   else goes through `Reply.to(T)`.

import std/[macros, strutils]

const idempotent = [
  # reads
  "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TTL", "PTTL", "TYPE", "KEYS", "RANDOMKEY",
  "HGET", "HGETALL", "HMGET", "HEXISTS", "HKEYS", "HVALS", "HLEN", "HSTRLEN", "HRANDFIELD",
  "LRANGE", "LLEN", "LINDEX", "LPOS", "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD",
  "SRANDMEMBER", "SDIFF", "SINTER", "SUNION", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT",
  "ZLEXCOUNT", "ZRANK", "ZREVRANK", "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE",
  "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZRANDMEMBER", "PFCOUNT", "GEODIST", "GEOHASH",
  "GEOPOS", "GEOSEARCH", "PING", "INFO", "DBSIZE", "TIME", "SCAN", "SSCAN", "HSCAN", "ZSCAN",
  "XLEN", "XRANGE", "XREVRANGE", "XPENDING", "XINFO", "DUMP", "OBJECT", "MEMORY",
  "EXPIRETIME", "PEXPIRETIME", "GETBIT", "BITCOUNT", "BITPOS", "CONFIG", "ECHO", "SCRIPT",
  # writes whose effect is the same when applied twice
  "SET", "DEL", "UNLINK", "HSET", "HDEL", "SADD", "SREM", "ZADD", "ZREM", "EXPIRE", "PEXPIRE",
  "EXPIREAT", "PEXPIREAT", "PERSIST", "SETEX", "PSETEX", "MSET", "LSET", "PFADD", "SETBIT",
  "HSETNX", "SETNX", "RENAME"]
  ## commands the pool may re-send after a connection loss whose outcome is unknown

const
  keylessCmds = ["PING", "INFO", "TIME", "LASTSAVE", "SAVE", "BGSAVE", "BGREWRITEAOF", "CONFIG",
                 "CLIENT", "RESET", "QUIT", "WAIT", "REPLICAOF", "HELLO", "AUTH", "SCRIPT", "PUBSUB", "ECHO"]
    ## commands with no key: a cluster sends them to any node
  clusterSkip = ["DBSIZE", "FLUSHDB", "FLUSHALL", "KEYS", "SCAN", "RANDOMKEY", "SELECT", "ASKING", "WATCH", "UNWATCH"]
    ## commands that only make sense per node (see the `cluster` module for the cluster-wide versions)

const noArg* = low(int)
  ## default of an optional integer parameter meaning "not given"

type
  ParamInfo = object
    name, typ, def: string
    variadic: bool

proc bareName(s: string): string =
  s.replace("`", "").strip(chars = {'_'}).toUpperAscii

proc tick(s: string): string = "`" & s.replace("`", "") & "`"

proc resultStmt(ret: string, who: string): string =
  ## Nim source reading the reply with ticket `t` from connection `c`
  case ret
  of "", "void": who & ".replyOk(t)"
  of "bool": "result = " & who & ".replyBool(t)"
  of "int": "result = int(" & who & ".replyInt(t))"
  of "int64": "result = " & who & ".replyInt(t)"
  of "string": "result = " & who & ".replyText(t)"
  of "Option[string]": "result = " & who & ".replyStr(t)"
  of "Reply": "result = " & who & ".replyChecked(t)"
  else: "result = " & who & ".replyTo(t, " & ret & ")"

macro cmd*(spec: static string, p: untyped): untyped =
  ## Defines a command. See the module documentation.
  expectKind(p, nnkProcDef)
  var words, suffix, bare, counted: seq[string]
  var routeName = ""
  var head = -1
  for w in spec.splitWhitespace:
    if w.startsWith("+"): suffix.add w[1 .. ^1]
    elif w.startsWith("@"): head = parseInt(w[1 .. ^1])
    elif w.startsWith("#"): bare.add w[1 .. ^1]
    elif w.startsWith("%"): counted.add w[1 .. ^1]
    elif w.startsWith("$"): routeName = w[1 .. ^1]
    else: words.add w

  let nameNode = if p[0].kind == nnkPostfix: p[0][1] else: p[0]
  let procName = nameNode.repr
  let ret = if p[3][0].kind == nnkEmpty: "" else: p[3][0].repr

  var params: seq[ParamInfo]
  for i in 1 ..< p[3].len:
    let d = p[3][i]
    let t = d[^2]
    let df = d[^1]
    for j in 0 ..< d.len - 2:
      params.add ParamInfo(
        name: d[j].repr.replace("`", ""),
        typ: t.repr,
        def: (if df.kind == nnkEmpty: "" else: df.repr),
        variadic: t.kind == nnkBracketExpr and
                  $t[0] in ["varargs", "openArray", "seq"])

  var pos, opts: seq[ParamInfo]
  for q in params:
    if q.def.len == 0: pos.add q else: opts.add q
  if head < 0:
    head = pos.len - (if pos.len > 0 and pos[^1].variadic: 1 else: 0)

  var doc = ""
  for n in p[6]:
    if n.kind == nnkCommentStmt: doc = n.strVal
  if p[6].kind == nnkCommentStmt: doc = p[6].strVal
  var docLines = ""
  for line in doc.splitLines:
    docLines.add "  ## " & line & "\n"

  # --- parameter list text ---------------------------------------------------
  var sig = ""
  for q in params:
    sig.add ", " & tick(q.name) & ": " & q.typ
    if q.def.len > 0: sig.add " = " & q.def

  # --- argument count + encoding, shared by the three targets -----------------
  var countCode = "  var n = " & $words.len & " + " & $suffix.len & "\n"
  for q in pos:
    countCode.add "  n += argCount(" & tick(q.name) & ")\n"
    if q.name in counted: countCode.add "  n += 1\n"
  for q in opts:
    let isBare = q.name in bare
    if q.typ == "bool":
      countCode.add "  if " & tick(q.name) & ": n += 1\n"
    else:
      let extra = if isBare: "" else: "1 + "
      countCode.add "  if " & tick(q.name) & " != " & q.def & ": n += " & extra &
                    "argCount(" & tick(q.name) & ")\n"

  proc encode(buf: string): string =
    result = ""
    for w in words: result.add "  " & buf & ".addArg(\"" & w & "\")\n"
    proc positional(q: ParamInfo): string =
      result = ""
      if q.name in counted:
        result.add "  " & buf & ".addArg(argCount(" & tick(q.name) & "))\n"
      result.add "  " & buf & ".addArg(" & tick(q.name) & ")\n"
    for i in 0 ..< head: result.add positional(pos[i])
    for q in opts:
      let tok = bareName(q.name)
      if q.typ == "bool":
        result.add "  if " & tick(q.name) & ": " & buf & ".addArg(\"" & tok & "\")\n"
      else:
        result.add "  if " & tick(q.name) & " != " & q.def & ":\n"
        if q.name notin bare:
          result.add "    " & buf & ".addArg(\"" & tok & "\")\n"
        result.add "    " & buf & ".addArg(" & tick(q.name) & ")\n"
    for i in head ..< pos.len: result.add positional(pos[i])
    for w in suffix: result.add "  " & buf & ".addArg(\"" & w & "\")\n"

  var fwd = ""
  for q in pos: fwd.add (if fwd.len > 0: ", " else: "") & tick(q.name)
  for q in opts: fwd.add (if fwd.len > 0: ", " else: "") & tick(q.name) & " = " & tick(q.name)

  let rt = if ret.len > 0: ": " & ret else: ""
  var src = ""

  # 1. connection variant: a flow proc
  src.add "proc " & procName & "*(c: Conn" & sig & ")" & rt & " {.flow.} =\n"
  src.add docLines
  src.add countCode
  src.add "  ensureLive(c)\n  c.wb.addArrayHeader(n)\n"
  src.add encode("c.wb")
  src.add "  c.submitT(t)\n"
  src.add "  " & resultStmt(ret, "c") & "\n\n"

  # 2. batch variant: queue only, plain proc
  src.add "proc " & procName & "*(p: Batch" & sig & "): int {.discardable.} =\n"
  src.add "  ## Batch form: queues the command and returns the index of its reply.\n"
  src.add countCode
  src.add "  p.buf.addArrayHeader(n)\n"
  src.add encode("p.buf")
  src.add "  result = p.count\n  inc p.count\n\n"

  # 3. pool variant: next shared connection, with retry for safe cases
  let safe = words[0].toUpperAscii in idempotent
  src.add "proc " & procName & "*(pool: Pool" & sig & ")" & rt & " {.flow.} =\n"
  src.add "  ## Pool form: runs on the pool's next shared connection. Retried (with\n"
  src.add "  ## backoff) when that is safe: always if nothing was sent yet, and after a\n"
  src.add "  ## lost connection only for " & (if safe: "this command, which is idempotent" else: "idempotent commands (this one is not)") & ".\n"
  src.add "  var attempt = 0\n  while true:\n    var failure: ref CatchableError = nil\n    try:\n"
  src.add "      let c = pool.pick()\n"
  if ret.len == 0 or ret == "void":
    src.add "      c." & procName & "(" & fwd & ")\n"
  else:
    src.add "      result = c." & procName & "(" & fwd & ")\n"
  src.add "    except CancelledError:\n      raise\n"
  src.add "    except ConnectionError as e:\n      failure = e\n"
  src.add "    except ServerError as e:\n      failure = e\n"
  src.add "    if failure == nil: break\n"
  src.add "    if not pool.shouldRetry(failure, " & (if safe: "true" else: "false") & ", attempt): raise failure\n"
  src.add "    inc attempt\n    pool.pause(attempt)\n\n"


  # 4. cluster variant: route by key slot, follow MOVED / ASK, retry where safe
  if words[0].toUpperAscii notin clusterSkip:
    var keyExpr = ""
    if routeName != "-" and words[0].toUpperAscii notin keylessCmds:
      var kp: ParamInfo
      var found = false
      for q in pos:
        if (routeName.len == 0 and not found) or q.name == routeName:
          kp = q; found = true
          if routeName.len > 0: break
      if found:
        let n = tick(kp.name)
        if kp.typ == "string": keyExpr = n
        elif kp.typ.startsWith("varargs[string") or kp.typ.startsWith("openArray[string"):
          keyExpr = "(if " & n & ".len > 0: " & n & "[0] else: \"\")"
        elif kp.typ == "openArray[(string, string)]":
          keyExpr = "(if " & n & ".len > 0: " & n & "[0][0] else: \"\")"
    let routed = keyExpr.len > 0
    src.add "proc " & procName & "*(cl: Cluster" & sig & ")" & rt & " {.flow.} =\n"
    src.add "  ## Cluster form: " & (if routed: "routed to the master that owns the key's slot" else: "sent to any node") & ";\n"
    src.add "  ## MOVED / ASK redirections are followed, and the command is retried when safe.\n"
    if routed: src.add "  let slot = keySlot(" & keyExpr & ")\n"
    src.add "  var attempt = 0\n  var useAsk = false\n  while true:\n    var failure: ref CatchableError = nil\n    try:\n"
    src.add "      if useAsk:\n        useAsk = false\n        let ac = cl.nodeConn(cl.askTarget())\n"
    src.add "        let b = ac.batch()\n        b.asking()\n        b." & procName & "(" & fwd & ")\n"
    src.add "        let rs = b.commit()\n"
    if ret.len == 0 or ret == "void":
      src.add "        if rs[1].kind == rkError: raise newServerError(rs[1].str)\n"
    else:
      src.add "        result = rs[1].to(" & ret & ")\n"
    src.add "      else:\n        let c = " & (if routed: "cl.connFor(slot)" else: "cl.anyConn()") & "\n"
    if ret.len == 0 or ret == "void":
      src.add "        c." & procName & "(" & fwd & ")\n"
    else:
      src.add "        result = c." & procName & "(" & fwd & ")\n"
    src.add "    except CancelledError:\n      raise\n    except ConnectionError as e:\n      failure = e\n    except ServerError as e:\n      failure = e\n"
    src.add "    if failure == nil: break\n"
    src.add "    let verdict = cl.onFailure(failure, " & (if safe: "true" else: "false") & ", attempt)\n"
    src.add "    if verdict == vRaise: raise failure\n    inc attempt\n"
    src.add "    if verdict == vAsk: useAsk = true\n    elif verdict == vRetryAfterPause: cl.pause(attempt)\n\n"

  result = parseStmt(src)
