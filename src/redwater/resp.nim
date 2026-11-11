## redwater/resp - the protocol engine.
##
## A *purely synchronous* RESP2 / RESP3 implementation that works on memory
## buffers only. It imports no socket code and no concurrency runtime, so it can
## be unit tested by feeding it arbitrary byte chunks, and reused with any
## transport.
##
## Three jobs:
##
## * **Encode** commands straight into one growing buffer (`addArrayHeader`,
##   `addArg`). No intermediate `seq[string]`, no per-argument allocation, and
##   integers are formatted in place.
## * **Frame** replies in a receive buffer (`RBuf.peek`): one allocation-free
##   scan says whether a complete reply is buffered and how long it is. A
##   partial reply costs only the scan, and a bulk string reports how many more
##   bytes it needs, so a big value is not re-scanned on every packet.
## * **Decode** a framed reply either into a `Reply` tree or, for the hot
##   scalar replies (`:` and `$`), straight into a native integer / string with
##   no tree.

import std/[strutils, options]

type
  RedwaterError* = object of IOError
    ## Base of every error redwater raises.
  ProtocolError* = object of RedwaterError
    ## The server sent invalid RESP, or a reply of a different type than the
    ## command promises.
  ServerError* = object of RedwaterError
    ## The server answered with an error reply (`-ERR ...`).
    code*: string          ## first word of the message: `WRONGTYPE`, `NOSCRIPT`, ...
  ConnectionError* = object of RedwaterError
    ## The connection is closed, broken, or could not be established.
  ConnectFailed* = object of ConnectionError
    ## A connection could not be (re)established. Nothing was sent, so retrying
    ## any command is safe.

  ReplyKind* = enum
    rkNil, rkStatus, rkError, rkInt, rkString, rkList, rkMap, rkSet,
    rkPush, rkDouble, rkBool, rkBigNum

  Reply* = object
    ## A fully decoded RESP value (all of RESP2 and RESP3).
    case kind*: ReplyKind
    of rkNil: discard
    of rkStatus, rkString, rkError, rkBigNum: str*: string
    of rkInt: num*: int64
    of rkDouble: dbl*: float
    of rkBool: flag*: bool
    of rkList, rkSet, rkPush: elems*: seq[Reply]
    of rkMap: entries*: seq[(Reply, Reply)]

const
  MaxDepth* = 64                  ## deepest reply nesting accepted
  MaxBulkLen* = 512 * 1024 * 1024 ## redis' own proto-max-bulk-len default
  MaxAggLen* = 64 * 1024 * 1024   ## largest array/map element count accepted

# ----------------------------------------------------------------------------
# errors
# ----------------------------------------------------------------------------

proc newServerError*(msg: string): ref ServerError =
  result = (ref ServerError)(msg: msg)
  var i = 0
  while i < msg.len and msg[i] notin {' ', '\r', '\n'}: inc i
  result.code = msg[0 ..< i]

proc replyErr(msg: string) {.noinline, noreturn.} =
  raise newException(ProtocolError, msg)

# ----------------------------------------------------------------------------
# encoder
# ----------------------------------------------------------------------------

proc addCrlf(b: var string) {.inline.} =
  let o = b.len
  b.setLen(o + 2)
  b[o] = '\r'; b[o + 1] = '\n'

proc addDigits(b: var string, v: int64) {.inline.} =
  ## appends the decimal form of `v` with no temporary string
  var tmp: array[24, char]
  var i = tmp.len
  var u = if v < 0: 0'u64 - cast[uint64](v) else: uint64(v)
  if u == 0:
    dec i; tmp[i] = '0'
  while u > 0:
    dec i; tmp[i] = char(ord('0') + int(u mod 10)); u = u div 10
  if v < 0:
    dec i; tmp[i] = '-'
  let n = tmp.len - i
  let o = b.len
  b.setLen(o + n)
  copyMem(addr b[o], addr tmp[i], n)

proc addArrayHeader*(b: var string, n: int) {.inline.} =
  ## starts a command of `n` arguments (`*n\r\n`)
  b.add '*'
  addDigits(b, n)
  addCrlf(b)

proc addBulkRaw*(b: var string, p: pointer, n: int) {.inline.} =
  ## appends `n` bytes at `p` as one bulk-string argument
  b.add '$'
  addDigits(b, n)
  addCrlf(b)
  if n > 0:
    let o = b.len
    b.setLen(o + n)
    copyMem(addr b[o], p, n)
  addCrlf(b)

proc addArg*(b: var string, s: string) {.inline.} =
  ## appends one bulk-string argument
  addBulkRaw(b, (if s.len > 0: unsafeAddr s[0] else: nil), s.len)

proc addArg*(b: var string, s: openArray[byte]) {.inline.} =
  addBulkRaw(b, (if s.len > 0: unsafeAddr s[0] else: nil), s.len)

proc addArg*(b: var string, v: SomeInteger) {.inline.} =
  ## integers are rendered in place: no `$v` temporary
  var d: array[24, char]
  var i = d.len
  let vv = int64(v)
  var u = if vv < 0: 0'u64 - cast[uint64](vv) else: uint64(vv)
  if u == 0:
    dec i; d[i] = '0'
  while u > 0:
    dec i; d[i] = char(ord('0') + int(u mod 10)); u = u div 10
  if vv < 0:
    dec i; d[i] = '-'
  addBulkRaw(b, addr d[i], d.len - i)

proc addArg*(b: var string, v: float) =
  if v != v: addArg(b, "nan")
  elif v == Inf: addArg(b, "inf")
  elif v == -Inf: addArg(b, "-inf")
  else: addArg(b, $v)

proc addArg*(b: var string, v: bool) {.inline.} =
  addArg(b, if v: "1" else: "0")

proc addArg*(b: var string, v: tuple[a, b: int]) {.inline.} =
  addArg(b, v.a); addArg(b, v.b)

proc addArg*(b: var string, v: tuple[a, b: string]) {.inline.} =
  addArg(b, v.a); addArg(b, v.b)

proc addArg*(b: var string, v: tuple[a: float, b: string]) =
  addArg(b, v.a); addArg(b, v.b)

proc addArg*(b: var string, v: tuple[a, b: float]) {.inline.} =
  addArg(b, v.a); addArg(b, v.b)

proc addArg*(b: var string, v: tuple[a, b: float, c: string]) {.inline.} =
  addArg(b, v.a); addArg(b, v.b); addArg(b, v.c)

proc addArg*(b: var string, v: tuple[a: string, b: int]) {.inline.} =
  addArg(b, v.a); addArg(b, v.b)

proc addArg*[T: enum](b: var string, v: T) =
  addArg(b, $v)

proc addArg*[T](b: var string, v: openArray[T]) =
  for x in v: addArg(b, x)

proc argCount*(x: string): int {.inline.} = 1
proc argCount*[T: SomeInteger | float | bool | enum](x: T): int {.inline.} = 1
proc argCount*(x: tuple[a, b: int]): int {.inline.} = 2
proc argCount*(x: tuple[a, b: string]): int {.inline.} = 2
proc argCount*(x: tuple[a: float, b: string]): int {.inline.} = 2
proc argCount*(x: tuple[a, b: float]): int {.inline.} = 2
proc argCount*(x: tuple[a: string, b: int]): int {.inline.} = 2
proc argCount*(x: tuple[a, b: float, c: string]): int {.inline.} = 3
proc argCount*[T](x: openArray[T]): int =
  var n = 0
  for e in x: n += argCount(e)
  n

# ----------------------------------------------------------------------------
# receive buffer + framing
# ----------------------------------------------------------------------------

type
  RBuf* = object
    ## Receive buffer. Bytes in `data[r ..< w]` are unread. Replies are framed
    ## in place; nothing is copied until a reply is decoded.
    data*: string
    r*, w*: int
    need*: int   ## when `peek` reports "incomplete": total unread bytes (from
                 ## `r`) that the next reply is known to need, else 0.

proc initRBuf*(cap = 16 * 1024): RBuf =
  RBuf(data: newString(max(cap, 64)))

proc buffered*(b: RBuf): int {.inline.} = b.w - b.r

proc reset*(b: var RBuf) {.inline.} =
  b.r = 0; b.w = 0; b.need = 0

proc ensureSpace*(b: var RBuf, minFree: int) =
  ## guarantees at least `minFree` writable bytes after `w`
  if b.r == b.w:
    b.r = 0; b.w = 0
  if b.data.len - b.w >= minFree: return
  let live = b.w - b.r
  if b.r > 0:                       # slide unread bytes to the front first
    if live > 0: moveMem(addr b.data[0], addr b.data[b.r], live)
    b.r = 0; b.w = live
  if b.data.len - b.w < minFree:
    var n = b.data.len
    while n - b.w < minFree: n = n * 2
    b.data.setLen(n)

proc writePtr*(b: var RBuf): pointer {.inline.} = addr b.data[b.w]
proc writeCap*(b: RBuf): int {.inline.} = b.data.len - b.w
proc advanceW*(b: var RBuf, n: int) {.inline.} = b.w += n

proc feed*(b: var RBuf, s: string) =
  ## copies `s` into the buffer (tests, and transports that own their reads)
  if s.len == 0: return
  b.ensureSpace(s.len)
  copyMem(addr b.data[b.w], unsafeAddr s[0], s.len)
  b.w += s.len

proc c_memchr(s: pointer, c: cint, n: csize_t): pointer
  {.importc: "memchr", header: "<string.h>".}

type Mem = ptr UncheckedArray[char]

template mem(b: RBuf): Mem = cast[Mem](unsafeAddr b.data[0])

proc crAt(p: Mem, pos, lim: int): int {.inline.} =
  ## index of the '\r' ending the line at `pos`; -1 if the line is incomplete.
  if pos >= lim: return -1
  let q = c_memchr(addr p[pos], 13, csize_t(lim - pos))
  if q == nil: return -1
  let i = cast[int](q) - cast[int](p)
  if i + 1 >= lim: return -1
  if p[i + 1] != '\n': replyErr("protocol error: CR without LF")
  i

proc parseInt64(p: Mem, a, b: int): int64 =
  ## parses p[a ..< b] as a signed decimal
  if a >= b: replyErr("protocol error: empty integer")
  var i = a
  var neg = false
  if p[i] == '-': neg = true; inc i
  elif p[i] == '+': inc i
  if i >= b: replyErr("protocol error: bad integer")
  var u = 0'u64
  while i < b:
    let d = ord(p[i]) - ord('0')
    if d < 0 or d > 9: replyErr("protocol error: bad integer")
    if u > 1844674407370955160'u64: replyErr("protocol error: integer overflow")
    u = u * 10 + uint64(d)
    inc i
  if neg:
    if u > 9223372036854775808'u64: replyErr("protocol error: integer overflow")
    result = cast[int64](0'u64 - u)
  else:
    if u > 9223372036854775807'u64: replyErr("protocol error: integer overflow")
    result = int64(u)

proc scan(p: Mem, pos, lim: int, depth: int, need: var int): int =
  ## Offset just past the reply that starts at `pos`, or -1 if it is not fully
  ## buffered. Raises `ProtocolError` on malformed input.
  if depth > MaxDepth: replyErr("protocol error: reply nested too deeply")
  if pos >= lim: return -1
  let t = p[pos]
  case t
  of '+', '-', ',', '#', '_', '(':
    let e = crAt(p, pos, lim)
    if e < 0: return -1
    result = e + 2
  of ':':
    let e = crAt(p, pos, lim)
    if e < 0: return -1
    discard parseInt64(p, pos + 1, e)     # validate once; decoders may trust it
    result = e + 2
  of '$', '=', '!':
    let e = crAt(p, pos, lim)
    if e < 0: return -1
    let n = parseInt64(p, pos + 1, e)
    if n < 0:
      if n == -1 and t == '$': return e + 2
      replyErr("protocol error: negative bulk length")
    if n > MaxBulkLen: replyErr("protocol error: bulk string too large")
    let endp = e + 2 + int(n) + 2
    if endp > lim:
      need = endp
      return -1
    if p[endp - 2] != '\r' or p[endp - 1] != '\n':
      replyErr("protocol error: bulk string not terminated")
    result = endp
  of '*', '~', '>', '%', '|':
    let e = crAt(p, pos, lim)
    if e < 0: return -1
    var n = parseInt64(p, pos + 1, e)
    if n == -1 and t == '*': return e + 2
    if n < 0 or n > MaxAggLen: replyErr("protocol error: bad aggregate length")
    if t == '%' or t == '|': n = n * 2
    var cur = e + 2
    for _ in 1 .. int(n):
      cur = scan(p, cur, lim, depth + 1, need)
      if cur < 0: return -1
    if t == '|':                      # an attribute precedes the real reply
      return scan(p, cur, lim, depth, need)
    result = cur
  else:
    replyErr("protocol error: unknown reply type byte " & $ord(t))

proc peek*(b: var RBuf): int =
  ## Length in bytes of the next complete reply, or 0 if it is not fully
  ## buffered yet (`b.need` may then say how much is needed in total).
  ## Allocation-free. Raises `ProtocolError` on malformed input.
  b.need = 0
  if b.r >= b.w: return 0
  var need = 0
  let e = scan(mem(b), b.r, b.w, 0, need)
  if e < 0:
    if need > 0: b.need = need - b.r
    return 0
  e - b.r

# ----------------------------------------------------------------------------
# decoding a framed reply (the caller has already checked `peek`)
# ----------------------------------------------------------------------------

proc lineStr(p: Mem, a, b: int): string {.inline.} =
  result = newString(b - a)
  if b > a: copyMem(addr result[0], addr p[a], b - a)

proc lineEnd(p: Mem, pos: int): int {.inline.} =
  var i = pos
  while p[i] != '\r': inc i
  i

proc decode(p: Mem, pos: var int, depth: int): Reply =
  let t = p[pos]
  let e = lineEnd(p, pos)
  case t
  of '+':
    result = Reply(kind: rkStatus, str: lineStr(p, pos + 1, e))
    pos = e + 2
  of '-':
    result = Reply(kind: rkError, str: lineStr(p, pos + 1, e))
    pos = e + 2
  of ':':
    result = Reply(kind: rkInt, num: parseInt64(p, pos + 1, e))
    pos = e + 2
  of '_':
    result = Reply(kind: rkNil)
    pos = e + 2
  of '#':
    result = Reply(kind: rkBool, flag: p[pos + 1] == 't')
    pos = e + 2
  of ',':
    let s = lineStr(p, pos + 1, e)
    let f = case s.toLowerAscii
      of "inf", "+inf": Inf
      of "-inf": -Inf
      of "nan", "-nan": NaN
      else: parseFloat(s)
    result = Reply(kind: rkDouble, dbl: f)
    pos = e + 2
  of '(':
    result = Reply(kind: rkBigNum, str: lineStr(p, pos + 1, e))
    pos = e + 2
  of '$', '=', '!':
    let n = int(parseInt64(p, pos + 1, e))
    if n < 0:
      result = Reply(kind: rkNil)
      pos = e + 2
    else:
      var a = e + 2
      var len = n
      if t == '=' and len >= 4: a += 4; len -= 4     # skip the "txt:" format tag
      if t == '!': result = Reply(kind: rkError, str: lineStr(p, a, a + len))
      else: result = Reply(kind: rkString, str: lineStr(p, a, a + len))
      pos = e + 2 + n + 2
  of '*', '~', '>', '%', '|':
    let n = parseInt64(p, pos + 1, e)
    pos = e + 2
    if n < 0:
      return Reply(kind: rkNil)
    if t == '%':
      result = Reply(kind: rkMap, entries: newSeq[(Reply, Reply)](int(n)))
      for i in 0 ..< int(n):
        let k = decode(p, pos, depth + 1)
        let v = decode(p, pos, depth + 1)
        result.entries[i] = (k, v)
    elif t == '|':
      for _ in 1 .. int(n) * 2: discard decode(p, pos, depth + 1)   # drop attribute
      result = decode(p, pos, depth)
    else:
      var items = newSeq[Reply](int(n))
      for i in 0 ..< int(n):
        items[i] = decode(p, pos, depth + 1)
      if t == '~': result = Reply(kind: rkSet, elems: move items)
      elif t == '>': result = Reply(kind: rkPush, elems: move items)
      else: result = Reply(kind: rkList, elems: move items)
  else:
    replyErr("protocol error: unknown reply type")

proc takeValue*(b: var RBuf, n: int): Reply =
  ## decodes the `n`-byte reply at the read position and consumes it
  var pos = b.r
  result = decode(mem(b), pos, 0)
  b.r += n

proc skip*(b: var RBuf, n: int) {.inline.} = b.r += n

proc firstByte*(b: RBuf): char {.inline.} = b.data[b.r]

# --- hot-path scalar decoders: no Reply tree, no extra allocation ------

proc takeInt*(b: var RBuf, n: int, got: var int64): bool =
  ## `:` reply -> `got`. Returns false, consuming nothing, for any other type.
  if b.data[b.r] != ':': return false
  got = parseInt64(mem(b), b.r + 1, b.r + n - 2)
  b.r += n
  true

type BulkKind* = enum bkOther, bkString, bkNil

proc takeBulk*(b: var RBuf, n: int, dst: var string): BulkKind =
  ## `$` (or RESP3 `_`) reply -> `dst`. One allocation: the result itself.
  ## Returns `bkOther`, consuming nothing, for any other type.
  let t = b.data[b.r]
  if t == '$':
    let p = mem(b)
    let e = lineEnd(p, b.r)
    let len = parseInt64(p, b.r + 1, e)
    if len < 0:
      b.r += n
      return bkNil
    dst.setLen(int(len))
    if len > 0: copyMem(addr dst[0], addr p[e + 2], int(len))
    b.r += n
    result = bkString
  elif t == '_':
    b.r += n
    result = bkNil
  else:
    result = bkOther

# ----------------------------------------------------------------------------
# Reply helpers
# ----------------------------------------------------------------------------

proc `$`*(v: Reply): string =
  case v.kind
  of rkNil: result = "nil"
  of rkStatus, rkString, rkError, rkBigNum: result = v.str
  of rkInt: result = $v.num
  of rkDouble: result = $v.dbl
  of rkBool: result = $v.flag
  of rkList, rkSet, rkPush:
    result = "["
    for i, e in v.elems:
      if i > 0: result.add ", "
      result.add $e
    result.add "]"
  of rkMap:
    result = "{"
    for i, kv in v.entries:
      if i > 0: result.add ", "
      result.add $kv[0]; result.add ": "; result.add $kv[1]
    result.add "}"

proc isNil*(v: Reply): bool {.inline.} = v.kind == rkNil
proc isError*(v: Reply): bool {.inline.} = v.kind == rkError

proc len*(v: Reply): int =
  case v.kind
  of rkList, rkSet, rkPush: v.elems.len
  of rkMap: v.entries.len
  of rkNil: 0
  else: 1

template `[]`*(v: Reply, i: int): untyped =
  ## element `i` of a list / set / push value (no copy)
  v.elems[i]

iterator items*(v: Reply): Reply =
  if v.kind in {rkList, rkSet, rkPush}:
    for x in v.elems: yield x

proc `==`*(a, b: Reply): bool =
  if a.kind != b.kind: return false
  case a.kind
  of rkNil: result = true
  of rkStatus, rkString, rkError, rkBigNum: result = a.str == b.str
  of rkInt: result = a.num == b.num
  of rkDouble: result = a.dbl == b.dbl
  of rkBool: result = a.flag == b.flag
  of rkList, rkSet, rkPush:
    if a.elems.len != b.elems.len: return false
    for i in 0 ..< a.elems.len:
      if not (a.elems[i] == b.elems[i]): return false
    result = true
  of rkMap:
    if a.entries.len != b.entries.len: return false
    for i in 0 ..< a.entries.len:
      if not (a.entries[i][0] == b.entries[i][0] and a.entries[i][1] == b.entries[i][1]):
        return false
    result = true

proc `==`*(a: Reply, b: string): bool =
  a.kind in {rkStatus, rkString} and a.str == b
proc `==`*(a: Reply, b: int): bool =
  a.kind == rkInt and a.num == int64(b)

# --- conversion: `v.to(T)` ---------------------------------------------------

proc badType(v: Reply, want: string) {.noinline, noreturn.} =
  raise newException(ProtocolError, "expected " & want & ", got " & $v.kind)

proc to*(v: Reply, _: typedesc[string]): string =
  case v.kind
  of rkStatus, rkString, rkBigNum: v.str
  of rkInt: $v.num
  of rkDouble: $v.dbl
  of rkBool: $v.flag
  of rkNil: ""
  of rkError: raise newServerError(v.str)
  else: badType(v, "string")

proc to*(v: Reply, _: typedesc[int64]): int64 =
  case v.kind
  of rkInt: v.num
  of rkString, rkStatus, rkBigNum: parseBiggestInt(v.str)
  of rkBool: (if v.flag: 1 else: 0)
  of rkNil: 0
  of rkError: raise newServerError(v.str)
  else: badType(v, "integer")

proc to*(v: Reply, _: typedesc[int]): int = int(v.to(int64))

proc to*(v: Reply, _: typedesc[bool]): bool =
  case v.kind
  of rkInt: v.num != 0
  of rkBool: v.flag
  of rkStatus: v.str == "OK"
  of rkString: v.str.len > 0 and v.str != "0"
  of rkNil: false
  of rkError: raise newServerError(v.str)
  else: badType(v, "bool")

proc to*(v: Reply, _: typedesc[float]): float =
  case v.kind
  of rkDouble: v.dbl
  of rkInt: float(v.num)
  of rkString, rkStatus:
    case v.str
    of "inf", "+inf": Inf
    of "-inf": -Inf
    of "nan": NaN
    else: parseFloat(v.str)
  of rkNil: 0.0
  of rkError: raise newServerError(v.str)
  else: badType(v, "float")

proc to*(v: Reply, _: typedesc[Reply]): Reply = v

proc to*[T](v: Reply, _: typedesc[Option[T]]): Option[T] =
  if v.kind == rkNil: none(T) else: some(v.to(T))

proc to*[T](v: Reply, _: typedesc[seq[T]]): seq[T] =
  case v.kind
  of rkList, rkSet, rkPush:
    result = newSeqOfCap[T](v.elems.len)
    for e in v.elems: result.add e.to(T)
  of rkNil: discard
  of rkError: raise newServerError(v.str)
  else: badType(v, "list")

proc to*[A, B](v: Reply, _: typedesc[(A, B)]): (A, B) =
  ## a two-element list
  case v.kind
  of rkList, rkSet:
    if v.elems.len != 2: badType(v, "pair")
    (v.elems[0].to(A), v.elems[1].to(B))
  of rkError: raise newServerError(v.str)
  else: badType(v, "pair")

proc toPairs*[A, B](v: Reply, ta: typedesc[A], tb: typedesc[B]): seq[(A, B)] =
  ## A RESP3 map, a RESP2 flat `[k, v, k, v, ...]` list, or a RESP3 list of
  ## two-element lists, as pairs.
  case v.kind
  of rkMap:
    for kv in v.entries: result.add (kv[0].to(A), kv[1].to(B))
  of rkList, rkSet:
    if v.elems.len > 0 and v.elems[0].kind == rkList:
      for e in v.elems:
        if e.elems.len != 2: badType(e, "pair")
        result.add (e.elems[0].to(A), e.elems[1].to(B))
    else:
      if v.elems.len mod 2 != 0: badType(v, "even-length list")
      var i = 0
      while i < v.elems.len:
        result.add (v.elems[i].to(A), v.elems[i + 1].to(B))
        i += 2
  of rkNil: discard
  of rkError: raise newServerError(v.str)
  else: badType(v, "map")

proc to*[A, B](v: Reply, _: typedesc[seq[(A, B)]]): seq[(A, B)] =
  ## any "map-like" reply as a sequence of pairs, RESP2 or RESP3
  v.toPairs(A, B)
