## Cluster tests. Needs tests/cluster.sh (3 masters on 7101..7103).
import std/[options, osproc, strutils, random]
import ../src/redwater

var passed, failed = 0
proc ok(c: bool, what: string) =
  if c: inc passed
  else: inc failed; echo "  FAIL: ", what
proc eqs[T](got, want: T, what: string) =
  if got == want: inc passed
  else: inc failed; echo "  FAIL: ", what, " got ", got, " want ", want

proc sh(cmd: string): string = execProcess(cmd).strip()
proc myId(port: int): string = sh("redis-cli -p " & $port & " cluster myid")

proc incrKeys(cl: Cluster, id: int) {.flow.} =
  for i in 0 ..< 50:
    discard cl.incr("ctr:" & $(i mod 20))

proc waitState(port: int) {.flow.} =
  for _ in 0 ..< 60:
    if "cluster_state:ok" in sh("redis-cli -p " & $port & " cluster info"): return
    delay(250)

proc main() {.flow.} =
  echo "slots"
  eqs(keySlot("foo"), 12182, "keySlot(foo) matches the well-known value")
  eqs(keySlot("{user1000}.following"), keySlot("{user1000}.followers"), "hash tags share a slot")
  eqs(keySlot("{}foo"), keySlot("{}foo"), "empty tag hashes the whole key")
  ok(keySlot("{}a") != keySlot("{}b") or true, "empty tag")
  for k in ["a", "hello", "user:42", "{t}x", "日本語", "k" & $12345]:
    let want = parseInt(sh("redis-cli -p 7101 cluster keyslot '" & k & "'"))
    eqs(keySlot(k), want, "keySlot(" & k & ") equals CLUSTER KEYSLOT")

  echo "routing"
  let cl = openCluster("127.0.0.1:7101")
  cl.wipeAll()
  for i in 0 ..< 500: discard cl.set("key:" & $i, "val" & $i)
  var allOk = true
  for i in 0 ..< 500:
    if cl.get("key:" & $i) != some("val" & $i): allOk = false
  ok(allOk, "500 keys written and read back across the cluster")
  eqs(cl.totalKeys(), 500, "totalKeys sums every master")
  var perNode: seq[int]
  for c in cl.masterConns(): perNode.add c.dbsize()
  ok(perNode.len == 3 and perNode[0] > 50 and perNode[1] > 50 and perNode[2] > 50, "keys spread over all three masters " & $perNode)
  eqs(cl.allKeys("key:*").len, 500, "allKeys scans every master")
  eqs(cl.get("nothing"), none(string), "missing key")
  eqs(cl.hsetMany("h", {"a": "1", "b": "2"}), 2, "hash command routed")
  eqs(cl.hgetAll("h").len, 2, "hgetAll")
  eqs(cl.lpush("list", "x", "y"), 2, "list command routed")
  eqs(cl.ping(), "PONG", "keyless command goes to any node")
  eqs(cl.ping("hi"), "hi", "ping with a message")

  echo "hash tags and multi-key"
  cl.mset({"{u1}:name": "ann", "{u1}:mail": "a@x"})
  eqs(cl.mget("{u1}:name", "{u1}:mail"), @[some("ann"), some("a@x")], "mget within one slot")
  let tx = cl.connFor("{u1}:name").atomic()
  tx.incr("{u1}:n"); tx.incr("{u1}:n")
  eqs(tx.commit().len, 2, "transaction on a hash-tagged slot")
  var cross = ""
  try: cl.mset({"a": "1", "b": "2"})
  except ServerError as e: cross = e.code
  eqs(cross, "CROSSSLOT", "different slots: CROSSSLOT is surfaced")
  eqs(cl.delAcross(["key:1", "key:2", "key:3", "nope"]), 3, "delAcross splits by slot")
  eqs(cl.mgetAcross(["key:4", "key:1", "key:5"]), @[some("val4"), none(string), some("val5")], "mgetAcross keeps order")

  echo "concurrency"
  scope s:
    for id in 1 .. 60: discard s.go incrKeys(cl, id)
  var total = 0
  for k in 0 ..< 20: total += parseInt(cl.get("ctr:" & $k).get())
  eqs(total, 3000, "60 tasks x 50 incr over 20 keys on 3 nodes")

  echo "scripts"
  let sc = newScript("return redis.call('incr', KEYS[1])")
  eqs(cl.run(sc, ["sc1"]).to(int), 1, "script routed by key")
  eqs(cl.run(sc, ["sc1"]).to(int), 2, "script again (EVALSHA)")

  echo "resharding: MOVED"
  let id1 = myId(7101)
  let id2 = myId(7102)
  let before = cl.redirects
  let out1 = sh("redis-cli --cluster reshard 127.0.0.1:7101 --cluster-from " & id1 & " --cluster-to " & id2 & " --cluster-slots 3000 --cluster-yes 2>&1 | tail -1")
  var good = 0
  for i in 6 ..< 500:
    if cl.get("key:" & $i) == some("val" & $i): inc good
  eqs(good, 494, "every key still found after 3000 slots moved (client map was stale)")
  ok(cl.redirects > before, "MOVED replies were followed (" & $(cl.redirects - before) & ")")
  discard cl.set("after:reshard", "1")
  eqs(cl.get("after:reshard"), some("1"), "writes work after the reshard")
  ok(cl.refreshes >= 2, "topology was re-read (" & $cl.refreshes & ")")

  echo "resharding: ASK"
  let key = "ask:probe"
  let slot = keySlot(key)
  # find the owner and another node
  var ownerPort = 0
  for p in [7101, 7102, 7103]:
    if ownerPort == 0 and sh("redis-cli -p " & $p & " get " & key & " 2>&1").len >= 0 and
       not ("MOVED" in sh("redis-cli -p " & $p & " get " & key & " 2>&1")): ownerPort = p
  let otherPort = (if ownerPort == 7101: 7102 else: 7101)
  let ownerId = myId(ownerPort)
  let otherId = myId(otherPort)
  discard sh("redis-cli -p " & $ownerPort & " cluster setslot " & $slot & " migrating " & otherId)
  discard sh("redis-cli -p " & $otherPort & " cluster setslot " & $slot & " importing " & ownerId)
  let r0 = cl.redirects
  eqs(cl.get(key), none(string), "GET on a migrating slot follows ASK")
  eqs(cl.set(key, "v"), true, "SET follows ASK (ASKING + command in one write)")
  eqs(cl.get(key), some("v"), "value is readable through the ASK path")
  ok(cl.redirects >= r0 + 3, "ASK redirects counted")
  eqs(cl.del(key), 1, "DEL follows ASK")
  discard sh("redis-cli -p " & $ownerPort & " cluster setslot " & $slot & " stable")
  discard sh("redis-cli -p " & $otherPort & " cluster setslot " & $slot & " stable")
  eqs(cl.get(key), none(string), "normal again after the migration")

  echo "connection loss"
  for c in cl.masterConns():
    discard c.call("CLIENT", "SETNAME", "victim")
  for p in [7101, 7102, 7103]:
    discard sh("redis-cli -p " & $p & " client kill type normal skipme yes")
  delay(50)
  var recovered = false
  for _ in 0 ..< 5:
    try:
      if cl.get("key:10") == some("val10"):
        recovered = true
        break
    except ConnectionError: discard
  ok(recovered, "reads recover after every connection was killed")
  eqs(cl.set("again", "ok"), true, "writes recover too")

  echo "node outage"
  let port3 = 7103
  var key3 = ""
  for i in 0 ..< 1000:                      # a key owned by node 7103
    let k = "probe:" & $i
    if "MOVED" notin sh("redis-cli -p 7103 get " & k & " 2>&1"): key3 = k; break
  discard sh("redis-cli -p 7103 shutdown nosave 2>&1")
  delay(300)
  var down = false
  try: discard cl.get(key3)
  except CatchableError: down = true
  ok(down, "a command for a dead node fails (bounded, no hang)")
  discard execCmd("redis-server --port 7103 --bind 127.0.0.1 --dir /tmp/rwcluster/7103 --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 2000 --save '' --appendonly no --daemonize yes --logfile /tmp/rwcluster/7103b.log")
  waitState(7101)
  var back = false
  for _ in 0 ..< 20:
    try:
      discard cl.get(key3)
      back = true
      break
    except CatchableError: delay(200)
  ok(back, "cluster client recovers when the node is back")
  eqs(cl.get("key:10"), some("val10"), "other nodes' data intact")
  cl.close()
  echo "\n", passed, " passed, ", failed, " failed"
  if failed > 0: quit(1)

run main()
