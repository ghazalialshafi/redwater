## redwater/scripting - Lua scripts, with `EVALSHA` caching handled for you.

import stagelane
import ./resp, ./conn, ./pool, ./cluster, ./dsl, ./commands

type
  Script* = ref object
    ## A Lua script. Run it with `c.run(script, keys, args)`: the first call per
    ## server may send the source; afterwards only its SHA1 goes over the wire.
    source*: string
    sha*: string

proc sha1Hex*(data: string): string =
  ## SHA-1 of `data` as 40 lowercase hex digits (what `EVALSHA` addresses scripts by).
  var h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32, 0x10325476'u32, 0xC3D2E1F0'u32]
  var msg = data
  let bitLen = uint64(data.len) * 8
  msg.add '\x80'
  while msg.len mod 64 != 56: msg.add '\0'
  for i in countdown(7, 0): msg.add char((bitLen shr (i * 8)) and 0xFF)
  template rol(x: uint32, n: int): uint32 = (x shl n) or (x shr (32 - n))
  var w: array[80, uint32]
  var off = 0
  while off < msg.len:
    for i in 0 ..< 16:
      w[i] = (uint32(msg[off + i*4].ord) shl 24) or (uint32(msg[off + i*4 + 1].ord) shl 16) or
             (uint32(msg[off + i*4 + 2].ord) shl 8) or uint32(msg[off + i*4 + 3].ord)
    for i in 16 ..< 80: w[i] = rol(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]; var e = h[4]
    for i in 0 ..< 80:
      var f, k: uint32
      if i < 20: f = (b and c) or ((not b) and d); k = 0x5A827999'u32
      elif i < 40: f = b xor c xor d; k = 0x6ED9EBA1'u32
      elif i < 60: f = (b and c) or (b and d) or (c and d); k = 0x8F1BBCDC'u32
      else: f = b xor c xor d; k = 0xCA62C1D6'u32
      let tmp = rol(a, 5) + f + e + k + w[i]
      e = d; d = c; c = rol(b, 30); b = a; a = tmp
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e
    off += 64
  const hex = "0123456789abcdef"
  for x in h:
    for i in countdown(7, 0): result.add hex[int((x shr (i * 4)) and 0xF)]

proc newScript*(source: string): Script =
  ## Wraps Lua source; the SHA1 is computed locally (no round trip).
  Script(source: source, sha: sha1Hex(source))

proc eval*(script: string, keys: openArray[string], args: openArray[string]): Reply {.cmd: "EVAL @2 %keys $keys".} =
  ## Runs Lua source. Prefer `Script` + `run` for scripts you call repeatedly.

proc evalSha*(sha: string, keys: openArray[string], args: openArray[string]): Reply {.cmd: "EVALSHA @2 %keys $keys".} =
  ## Runs a script that is already cached on the server.

proc scriptLoad*(script: string): string {.cmd: "SCRIPT LOAD".} =
  ## Caches a script on the server; returns its SHA1.

proc scriptExists*(shas: varargs[string]): seq[bool] {.cmd: "SCRIPT EXISTS".} =
  ## Which of the SHA1s are cached.

proc scriptFlush*() {.cmd: "SCRIPT FLUSH".} =
  ## Empties the script cache.

proc scriptKill*() {.cmd: "SCRIPT KILL".} =
  ## Stops the running script (if it has not written yet).

proc run*(c: Conn, s: Script, keys: openArray[string] = [],
          args: openArray[string] = []): Reply {.flow.} =
  ## Runs `s` with `EVALSHA`, falling back to `EVAL` once if the server has not
  ## seen it (after a restart or `SCRIPT FLUSH`).
  var needSource = false
  try:
    result = c.evalSha(s.sha, keys, args)
  except ServerError as e:
    if e.code != "NOSCRIPT": raise
    needSource = true
  if needSource:
    result = c.eval(s.source, keys, args)

proc run*(pool: Pool, s: Script, keys: openArray[string] = [],
          args: openArray[string] = []): Reply {.flow.} =
  let c = pool.pick()
  result = c.run(s, keys, args)

proc run*(cl: Cluster, s: Script, keys: openArray[string] = [],
          args: openArray[string] = []): Reply {.flow.} =
  ## Cluster form of `run`: routed by the first key, `EVALSHA` first, `EVAL` if
  ## that node has not seen the script.
  var needSource = false
  try:
    result = cl.evalSha(s.sha, keys, args)
  except ServerError as e:
    if e.code != "NOSCRIPT": raise
    needSource = true
  if needSource:
    result = cl.eval(s.source, keys, args)
