## redwater/cluster - Redis / Valkey Cluster.
##
## A `Cluster` keeps the slot map (which master owns each of the 16384 hash
## slots), one auto-pipelined `Conn` per node, and routes every command to the
## node that owns its key. Every typed command works on a `Cluster` exactly as
## on a `Conn` (`cl.get("k")`, `cl.set(...)`, ...), and:
##
## * `MOVED` and `ASK` redirections are followed transparently (an `ASK` is sent
##   as `ASKING` + the command in one contiguous write, so no other task can
##   slip in between them);
## * the topology is refreshed when a node moves, dies, or reports
##   `CLUSTERDOWN`, by whichever task notices first (the others wait for it);
## * failed commands are retried with backoff only where that is safe (nothing
##   was sent, or the command is idempotent) - see `Pool` for the rules.
##
## Multi-key commands must keep their keys in one slot (use hash tags:
## `{user:1}:name`, `{user:1}:email`), otherwise the server answers `CROSSSLOT`.
## `delAcross` / `mgetAcross` split such requests by slot for you.

import std/[options, strutils, tables, algorithm]
import stagelane
import ./resp, ./conn

const SlotCount* = 16384

type
  ClusterNode* = ref object
    host*: string
    port*: int
    conn: Conn
  Cluster* = ref object
    cfg: Config
    seeds: seq[(string, int)]
    slots: array[SlotCount, ClusterNode]
    nodes: Table[string, ClusterNode]
    refreshing: bool
    refreshQ: WaitQueue
    dirty: bool                 ## the slot map is known to be stale
    maxRedirects*: int          ## redirections / retries per command (default 8)
    lastAsk: ClusterNode
    refreshes*: int             ## how many times the topology was re-read
    redirects*: int             ## how many MOVED / ASK replies were followed
  Verdict* = enum
    vRaise, vRetry, vRetryAfterPause, vAsk

# ----------------------------------------------------------------------------
# slot hashing
# ----------------------------------------------------------------------------

const crcTable = block:
  var t: array[256, uint16]
  for i in 0 ..< 256:
    var crc = uint16(i) shl 8
    for _ in 0 ..< 8:
      crc = if (crc and 0x8000'u16) != 0: (crc shl 1) xor 0x1021'u16 else: crc shl 1
    t[i] = crc
  t

proc crc16*(s: string): uint16 =
  ## CRC16-CCITT (XMODEM), the checksum Redis Cluster hashes keys with
  var crc = 0'u16
  for ch in s:
    crc = (crc shl 8) xor crcTable[int((crc shr 8) xor uint16(ord(ch))) and 0xFF]
  crc

proc keySlot*(key: string): int =
  ## The hash slot (0 .. 16383) of `key`. If the key contains `{tag}` with a
  ## non-empty tag, only the tag is hashed, so related keys share a slot.
  let a = key.find('{')
  if a >= 0:
    let b = key.find('}', a + 1)
    if b > a + 1:
      return int(crc16(key[a + 1 ..< b])) mod SlotCount
  int(crc16(key)) mod SlotCount

# ----------------------------------------------------------------------------
# nodes and topology
# ----------------------------------------------------------------------------

proc addrKey(host: string, port: int): string = host & ":" & $port

proc nodeFor(cl: Cluster, host: string, port: int): ClusterNode =
  let k = addrKey(host, port)
  result = cl.nodes.getOrDefault(k)
  if result == nil:
    result = ClusterNode(host: host, port: port)
    cl.nodes[k] = result

proc nodeConn*(cl: Cluster, n: ClusterNode): Conn {.flow.} =
  ## the (lazily opened, auto-reconnecting) connection to a node
  if n.conn == nil or n.conn.closed:
    var cfg = cl.cfg
    cfg.db = 0                                   # clusters have only database 0
    cfg.sentinels = @[]
    cfg.masterName = ""
    if cfg.maxAttempts == 0: cfg.maxAttempts = 2   # fail fast: a refresh may find a new owner
    n.conn = openFlow(n.host, n.port, cfg)
  result = n.conn

proc parseSlots(cl: Cluster, v: Reply, queried: string) =
  ## rebuild the slot table from a `CLUSTER SLOTS` reply
  if v.kind != rkList: raise newException(ProtocolError, "malformed CLUSTER SLOTS reply")
  var fresh: Table[string, ClusterNode]
  var table: array[SlotCount, ClusterNode]
  for entry in v.elems:
    if entry.kind != rkList or entry.elems.len < 3:
      raise newException(ProtocolError, "malformed CLUSTER SLOTS entry")
    let first = entry.elems[0].to(int)
    let last = entry.elems[1].to(int)
    let m = entry.elems[2]
    var host = if m.elems[0].kind == rkNil: "" else: m.elems[0].to(string)
    if host.len == 0 or host == "?": host = queried     # "" means: same host you asked
    let port = m.elems[1].to(int)
    let k = addrKey(host, port)
    var node = fresh.getOrDefault(k)
    if node == nil:
      node = cl.nodes.getOrDefault(k)                    # keep the live connection
      if node == nil: node = ClusterNode(host: host, port: port)
      fresh[k] = node
    for s in first .. min(last, SlotCount - 1): table[s] = node
  # close connections to nodes that left the cluster
  for k, n in cl.nodes:
    if k notin fresh and n.conn != nil: n.conn.close()
  cl.nodes = fresh
  cl.slots = table

proc refresh*(cl: Cluster) {.flow.} =
  ## Re-reads the topology (`CLUSTER SLOTS`) from the first node that answers.
  ## Concurrent callers share one refresh.
  if cl.refreshing:
    while cl.refreshing: park(cl.refreshQ)
    return
  cl.refreshing = true
  var lastErr = "no nodes known"
  var done = false
  var candidates: seq[(string, int)]
  for _, n in cl.nodes: candidates.add (n.host, n.port)
  for s in cl.seeds:
    if s notin candidates: candidates.add s
  for cand in candidates:
    if done: break
    try:
      let node = cl.nodeFor(cand[0], cand[1])
      let c = cl.nodeConn(node)
      let v = c.call("CLUSTER", "SLOTS")
      cl.parseSlots(v, cand[0])
      done = true
    except CancelledError:
      cl.refreshing = false
      notifyAll(cl.refreshQ)
      raise
    except CatchableError as e:
      lastErr = cand[0] & ":" & $cand[1] & ": " & e.msg
  cl.refreshing = false
  notifyAll(cl.refreshQ)
  if not done:
    raise newException(ConnectFailed, "cannot read the cluster topology: " & lastErr)
  cl.dirty = false
  cl.refreshes += 1

proc openCluster*(seeds: openArray[(string, int)], cfg: Config = defaultConfig()): Cluster {.flow.} =
  ## Connects to a cluster through any of the `seeds` (host, port) and reads
  ## the topology. Other nodes are discovered automatically.
  let cl = Cluster(cfg: cfg, refreshQ: newWaitQueue(), maxRedirects: 8)
  for s in seeds: cl.seeds.add s
  cl.refresh()
  result = cl

proc openCluster*(url: string, cfg: Config = defaultConfig()): Cluster {.flow.} =
  ## Like above from `host:port[,host:port...]` (a `redis://` prefix is ignored).
  var seeds: seq[(string, int)]
  for part in url.replace("redis://", "").replace("rediss://", "").split(','):
    let hp = part.strip().split(':')
    seeds.add (hp[0], (if hp.len > 1: parseInt(hp[1]) else: 6379))
  result = openCluster(seeds, cfg)

proc close*(cl: Cluster) =
  ## Closes every node connection.
  for _, n in cl.nodes:
    if n.conn != nil: n.conn.close()

proc needsRefresh*(cl: Cluster): bool {.inline.} = cl.dirty

proc connFor*(cl: Cluster, slot: int): Conn {.flow.} =
  ## the connection to the master that owns `slot`
  if cl.slots[slot] == nil or cl.dirty: cl.refresh()
  let n = cl.slots[slot]
  if n == nil: raise newException(ConnectFailed, "no cluster node owns slot " & $slot)
  result = cl.nodeConn(n)

proc connFor*(cl: Cluster, key: string): Conn {.flow.} =
  ## The connection to the master owning `key`. Use it for a pipeline or a
  ## transaction over keys that share a slot: `cl.connFor("{u1}:a").batch()`.
  result = cl.connFor(keySlot(key))

proc anyConn*(cl: Cluster): Conn {.flow.} =
  ## a connection to some master (for commands that have no key)
  if cl.nodes.len == 0: cl.refresh()
  var best: ClusterNode = nil
  for _, n in cl.nodes:
    if best == nil or (n.conn != nil and n.conn.isConnected): best = n
    if best.conn != nil and best.conn.isConnected: break
  if best == nil: raise newException(ConnectFailed, "no cluster nodes")
  result = cl.nodeConn(best)

proc masterConns*(cl: Cluster): seq[Conn] {.flow.} =
  ## one connection per master node
  if cl.nodes.len == 0: cl.refresh()
  var list: seq[ClusterNode]
  for _, n in cl.nodes: list.add n
  list.sort(proc (a, b: ClusterNode): int = cmp(addrKey(a.host, a.port), addrKey(b.host, b.port)))
  for n in list: result.add cl.nodeConn(n)

proc openDedicated*(cl: Cluster): Conn {.flow.} =
  ## a new connection to some node, for blocking commands / pub-sub (`SUBSCRIBE`
  ## messages reach every node, so any node will do)
  var n: ClusterNode = nil
  for _, x in cl.nodes:
    n = x
    break
  if n == nil: cl.refresh()
  for _, x in cl.nodes:
    n = x
    break
  var cfg = cl.cfg
  cfg.db = 0
  result = openFlow(n.host, n.port, cfg)

# ----------------------------------------------------------------------------
# failure handling
# ----------------------------------------------------------------------------

proc parseRedirect(msg: string, slot: var int, host: var string, port: var int): bool =
  ## "MOVED 3999 127.0.0.1:6381" / "ASK 3999 127.0.0.1:6381"
  let parts = msg.split(' ')
  if parts.len < 3: return false
  try:
    slot = parseInt(parts[1])
    let hp = parts[2]
    let i = hp.rfind(':')
    host = hp[0 ..< i]
    port = parseInt(hp[i + 1 .. ^1])
    result = true
  except ValueError:
    result = false

proc onFailure*(cl: Cluster, failure: ref CatchableError, idempotent: bool, attempt: int): Verdict =
  ## internal: what to do after a command failed
  if attempt >= cl.maxRedirects: return vRaise
  if failure of ServerError:
    let e = ServerError(failure[])
    var slot: int
    var host: string
    var port: int
    case e.code
    of "MOVED":
      if parseRedirect(e.msg, slot, host, port):
        cl.slots[slot] = cl.nodeFor(host, port)       # learn the new owner right away
        cl.dirty = true                                # and re-read the whole map soon
        cl.redirects += 1
        return vRetry
    of "ASK":
      if parseRedirect(e.msg, slot, host, port):
        cl.lastAsk = cl.nodeFor(host, port)
        cl.redirects += 1
        return vAsk
    of "CLUSTERDOWN":
      cl.dirty = true
      return vRetryAfterPause
    of "TRYAGAIN", "LOADING", "MASTERDOWN":
      return vRetryAfterPause
    else: discard
    return vRaise
  if failure of ConnectFailed:
    cl.dirty = true                                    # the owner may have changed
    return vRetryAfterPause                            # nothing was sent: always safe
  if failure of ConnectionError:
    cl.dirty = true
    return (if idempotent: vRetryAfterPause else: vRaise)
  vRaise

proc askTarget*(cl: Cluster): ClusterNode = cl.lastAsk

proc pause*(cl: Cluster, attempt: int) {.flow.} =
  ## internal: backoff between retries
  var d = 25
  for _ in 1 ..< attempt: d = min(500, d * 2)
  delay(d)

# ----------------------------------------------------------------------------
# helpers that span nodes
# ----------------------------------------------------------------------------

proc totalKeys*(cl: Cluster): int {.flow.} =
  ## sum of `DBSIZE` over every master
  for c in cl.masterConns():
    result += c.call("DBSIZE").to(int)

proc wipeAll*(cl: Cluster) {.flow.} =
  ## `FLUSHALL` on every master
  for c in cl.masterConns():
    discard c.call("FLUSHALL")

proc allKeys*(cl: Cluster, match: string = "*"): seq[string] {.flow.} =
  ## every key matching `match`, gathered with `SCAN` from every master
  for c in cl.masterConns():
    var cursor = "0"
    while true:
      let r = c.call("SCAN", cursor, "MATCH", match, "COUNT", "1000")
      cursor = r.elems[0].to(string)
      for k in r.elems[1].elems: result.add k.to(string)
      if cursor == "0": break

proc delAcross*(cl: Cluster, keys: openArray[string]): int {.flow.} =
  ## `DEL` for keys in different slots: one `DEL` per slot, results summed
  var bySlot: Table[int, seq[string]]
  for k in keys: bySlot.mgetOrPut(keySlot(k), @[]).add k
  for slot, group in bySlot:
    var args = @["DEL"]
    args.add group
    let c = cl.connFor(slot)
    result += c.call(args).to(int)

proc mgetAcross*(cl: Cluster, keys: openArray[string]): seq[Option[string]] {.flow.} =
  ## `MGET` for keys in different slots; results are in the order of `keys`
  result = newSeq[Option[string]](keys.len)
  var bySlot: Table[int, seq[int]]
  for i, k in keys: bySlot.mgetOrPut(keySlot(k), @[]).add i
  for slot, idxs in bySlot:
    var args = @["MGET"]
    for i in idxs: args.add keys[i]
    let c = cl.connFor(slot)
    let r = c.call(args)
    for j, i in idxs:
      result[i] = r.elems[j].to(Option[string])
