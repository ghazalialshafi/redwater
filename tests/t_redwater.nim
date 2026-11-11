## Integration tests: needs a Redis/Valkey on 127.0.0.1:6379 (uses database 15,
## which it flushes). Run: nim c -r --path:<stagelane>/src tests/t_redwater.nim
import std/[options, strutils]
import ../src/redwater

var passed, failed = 0

proc ok(cond: bool, what: string) =
  if cond: inc passed
  else:
    inc failed
    echo "  FAIL: ", what

proc eqs[T](got, want: T, what: string) =
  if got == want: inc passed
  else:
    inc failed
    echo "  FAIL: ", what, "\n    got:  ", got, "\n    want: ", want

template raises(E: typedesc, what: string, body: untyped) =
  var thrown = false
  try:
    body
  except E:
    thrown = true
  ok(thrown, what & " raises " & $E)

const db15 = Config(protocol: 2, readBufSize: 16384, tcpNoDelay: true, keepAlive: true, db: 15)

proc bump(c: Conn, n: int) {.flow.} =
  for _ in 1 .. n: discard c.incr("ctr")

proc echoer(c: Conn, id: int): bool {.flow.} =
  for i in 0 ..< 20:
    let want = "t" & $id & ":" & $i
    if c.ping(want) != want: return false
  true

proc slowCmd(c: Conn) {.flow.} =
  discard c.blpop(["nolist2"], 0.3)       # server answers after 300 ms

proc victimLoop(c: Conn) {.flow.} =
  while true: discard c.incr("churn")

proc worker(pool: Pool, n: int) {.flow.} =
  for _ in 1 .. n: discard pool.incr("pc")

proc pusher(pool: Pool) {.flow.} =
  delay(30)
  discard pool.rpush("jobs", "job1")

proc publisher(pool: Pool) {.flow.} =
  delay(20)
  discard pool.publish("news", "hello")
  discard pool.publish("log.error", "disk")
  discard pool.publish("alerts", "fire")

proc testStrings(c: Conn) {.flow.} =
  echo "strings"
  c.flushdb()
  eqs(c.set("a", "1"), true, "set")
  eqs(c.get("a"), some("1"), "get")
  eqs(c.get("missing"), none(string), "get missing")
  eqs(c.set("a", "2", nx = true), false, "set nx on existing")
  eqs(c.set("b", "x", nx = true), true, "set nx")
  eqs(c.set("a", "3", xx = true), true, "set xx")
  eqs(c.setGet("a", "4"), some("3"), "setGet")
  eqs(c.set("t", "v", ex = 100), true, "set ex")
  ok(c.ttl("t") in 98 .. 100, "ttl after set ex")
  ok(c.pttl("t") > 90_000, "pttl")
  eqs(c.persist("t"), true, "persist")
  eqs(c.ttl("t"), -1, "ttl -1")
  eqs(c.ttl("nokey"), -2, "ttl -2")
  eqs(c.incr("n"), 1'i64, "incr")
  eqs(c.incrBy("n", 10), 11'i64, "incrBy")
  eqs(c.decr("n"), 10'i64, "decr")
  eqs(c.decrBy("n", 4), 6'i64, "decrBy")
  ok(abs(c.incrByFloat("f", 1.5) - 1.5) < 1e-9, "incrByFloat")
  eqs(c.append("s", "hello"), 5, "append")
  eqs(c.append("s", " world"), 11, "append 2")
  eqs(c.strlen("s"), 11, "strlen")
  eqs(c.getRange("s", 0, 4), "hello", "getRange")
  eqs(c.setRange("s", 6, "WORLD"), 11, "setRange")
  eqs(c.get("s"), some("hello WORLD"), "after setRange")
  c.mset({"m1": "a", "m2": "b"})
  eqs(c.mget("m1", "nope", "m2"), @[some("a"), none(string), some("b")], "mget")
  eqs(c.msetNX({"m1": "z", "m3": "c"}), false, "msetNX blocked")
  eqs(c.setNX("m3", "c"), true, "setNX")
  eqs(c.getDel("m3"), some("c"), "getDel")
  eqs(c.exists("m3"), false, "exists after getDel")
  c.setEx("e", 100, "v")
  c.psetEx("pe", 100000, "v")
  eqs(c.countExisting("e", "pe", "e"), 3, "countExisting")
  eqs(c.getEx("e", persist = true), some("v"), "getEx persist")
  eqs(c.ttl("e"), -1, "persisted")
  eqs(c.setBit("bits", 7, 1), 0, "setBit")
  eqs(c.getBit("bits", 7), 1, "getBit")
  eqs(c.bitCount("bits"), 1, "bitCount")
  eqs(c.bitPos("bits", 1), 7, "bitPos")
  eqs(c.del("a", "b", "nokey"), 2, "del atomic")
  eqs(c.keyType("s"), "string", "keyType")
  eqs(c.keyType("zzz"), "none", "keyType none")
  # binary safety
  let bin = "a\0b\r\nc\xff"
  discard c.set("bin", bin)
  eqs(c.get("bin"), some(bin), "binary-safe round trip")
  discard c.set("empty", "")
  eqs(c.get("empty"), some(""), "empty string")
  var big = newString(3_000_000)
  for i in 0 ..< big.len: big[i] = char(i mod 251)
  discard c.set("big", big)
  eqs(c.get("big") == some(big), true, "3MB value across many reads")

proc testKeys(c: Conn) {.flow.} =
  echo "keys"
  c.flushdb()
  discard c.set("k1", "v"); discard c.set("k2", "v"); discard c.set("other", "v")
  eqs(c.keys("k*").len, 2, "keys glob")
  eqs(c.dbsize(), 3, "dbsize")
  c.rename("k1", "k3")
  eqs(c.renameNX("k2", "k3"), false, "renameNX blocked")
  eqs(c.copy("k3", "k4"), true, "copy")
  eqs(c.expire("k4", 100), true, "expire")
  eqs(c.expire("k4", 50, gt = true), false, "expire gt blocked")
  eqs(c.expire("k4", 200, gt = true), true, "expire gt")
  eqs(c.pexpire("k4", 90_000), true, "pexpire")
  ok(c.expireTime("k4") > 0, "expireTime")
  ok(c.randomKey().isSome, "randomKey")
  ok(c.dump("k3").isSome, "dump")
  eqs(c.objectEncoding("k3").isSome, true, "objectEncoding")
  ok(c.touch("k3", "k4") == 2, "touch")
  eqs(c.unlink("k3", "k4"), 2, "unlink")
  # scan
  for i in 0 ..< 250: discard c.set("scan:" & $i, "v")
  let all = c.scanAll("scan:*", 50)
  eqs(all.len, 250, "scanAll finds every key")
  var n = 0
  c.scanEach("scan:*", key):
    inc n
    discard key
  eqs(n, 250, "scanEach visits every key")

proc testHashes(c: Conn) {.flow.} =
  echo "hashes"
  c.flushdb()
  eqs(c.hset("h", "f1", "v1"), 1, "hset")
  eqs(c.hsetMany("h", {"f2": "v2", "f3": "v3"}), 2, "hsetMany")
  eqs(c.hget("h", "f2"), some("v2"), "hget")
  eqs(c.hget("h", "zz"), none(string), "hget missing")
  eqs(c.hlen("h"), 3, "hlen")
  eqs(c.hexists("h", "f1"), true, "hexists")
  eqs(c.hsetNX("h", "f1", "x"), false, "hsetNX blocked")
  eqs(c.hgetAll("h").len, 3, "hgetAll")
  eqs(c.hgetAll("h")[0], ("f1", "v1"), "hgetAll order")
  eqs(c.hmget("h", "f1", "no", "f3"), @[some("v1"), none(string), some("v3")], "hmget")
  eqs(c.hincrBy("h", "cnt", 5), 5'i64, "hincrBy")
  ok(abs(c.hincrByFloat("h", "fl", 2.5) - 2.5) < 1e-9, "hincrByFloat")
  eqs(c.hstrlen("h", "f1"), 2, "hstrlen")
  eqs(c.hkeys("h").len, 5, "hkeys")
  eqs(c.hvals("h").len, 5, "hvals")
  eqs(c.hdel("h", "f1", "f2", "nope"), 2, "hdel")
  let page = c.hscan("h", "0")
  ok(page.items.len > 0, "hscan")
  eqs(c.hgetAll("nokey").len, 0, "hgetAll missing is empty")

proc testLists(c: Conn) {.flow.} =
  echo "lists"
  c.flushdb()
  eqs(c.rpush("l", "a", "b", "c"), 3, "rpush")
  eqs(c.lpush("l", "z"), 4, "lpush")
  eqs(c.lrange("l", 0, -1), @["z", "a", "b", "c"], "lrange")
  eqs(c.llen("l"), 4, "llen")
  eqs(c.lindex("l", 1), some("a"), "lindex")
  eqs(c.lindex("l", 99), none(string), "lindex missing")
  c.lset("l", 0, "Z")
  eqs(c.linsert("l", ipBefore, "b", "ab"), 5, "linsert")
  eqs(c.lrem("l", 0, "ab"), 1, "lrem")
  eqs(c.lpos("l", "c"), some(3), "lpos")
  eqs(c.lpop("l"), some("Z"), "lpop")
  eqs(c.rpop("l"), some("c"), "rpop")
  eqs(c.rpopCount("l", 5), @["b", "a"], "rpopCount")
  eqs(c.lpop("l"), none(string), "lpop empty")
  discard c.rpush("src", "1", "2", "3")
  eqs(c.lmove("src", "dst", lsLeft, lsRight), some("1"), "lmove")
  eqs(c.rpopLPush("src", "dst"), some("3"), "rpopLPush")
  c.ltrim("dst", 0, 0)
  eqs(c.llen("dst"), 1, "ltrim")
  eqs(c.lpushX("nolist", "x"), 0, "lpushX")

proc testSets(c: Conn) {.flow.} =
  echo "sets"
  c.flushdb()
  eqs(c.sadd("s1", "a", "b", "c"), 3, "sadd")
  eqs(c.sadd("s2", "b", "c", "d"), 3, "sadd 2")
  eqs(c.scard("s1"), 3, "scard")
  eqs(c.sismember("s1", "a"), true, "sismember")
  eqs(c.smismember("s1", "a", "z"), @[true, false], "smismember")
  eqs(c.sinter("s1", "s2").len, 2, "sinter")
  eqs(c.sunion("s1", "s2").len, 4, "sunion")
  eqs(c.sdiff("s1", "s2"), @["a"], "sdiff")
  eqs(c.sinterStore("si", "s1", "s2"), 2, "sinterStore")
  eqs(c.sunionStore("su", "s1", "s2"), 4, "sunionStore")
  eqs(c.sdiffStore("sd", "s1", "s2"), 1, "sdiffStore")
  eqs(c.smove("s1", "s2", "a"), true, "smove")
  eqs(c.srem("s2", "a", "zz"), 1, "srem")
  ok(c.spop("su").isSome, "spop")
  ok(c.srandMember("su").isSome, "srandMember")
  eqs(c.srandMemberCount("su", 2).len, 2, "srandMemberCount")
  eqs(c.spopCount("su", 10).len, 3, "spopCount")
  eqs(c.smembers("nokey").len, 0, "smembers missing")

proc testZsets(c: Conn) {.flow.} =
  echo "sorted sets"
  c.flushdb()
  eqs(c.zadd("z", {1.0: "a", 2.0: "b", 3.5: "c"}), 3, "zadd")
  eqs(c.zadd("z", {9.0: "a"}, nx = true), 0, "zadd nx")
  eqs(c.zcard("z"), 3, "zcard")
  eqs(c.zscore("z", "c"), some(3.5), "zscore")
  eqs(c.zscore("z", "nope"), none(float), "zscore missing")
  eqs(c.zrank("z", "b"), some(1), "zrank")
  eqs(c.zrevRank("z", "b"), some(1), "zrevRank")
  eqs(c.zrange("z", 0, -1), @["a", "b", "c"], "zrange")
  eqs(c.zrevRange("z", 0, 0), @["c"], "zrevRange")
  eqs(c.zrangeWithScores("z", 0, 1), @[("a", 1.0), ("b", 2.0)], "zrangeWithScores")
  eqs(c.zrangeByScore("z", "1.5", "+inf"), @["b", "c"], "zrangeByScore")
  eqs(c.zrangeByScore("z", "-inf", "+inf", limit = (1, 1)), @["b"], "zrangeByScore limit")
  eqs(c.zrangeByScoreWithScores("z", "2", "3.5"), @[("b", 2.0), ("c", 3.5)], "byScoreWithScores")
  eqs(c.zrevRangeByScore("z", "+inf", "-inf"), @["c", "b", "a"], "zrevRangeByScore")
  eqs(c.zcount("z", "1", "2"), 2, "zcount")
  ok(abs(c.zincrBy("z", 10, "a") - 11.0) < 1e-9, "zincrBy")
  eqs(c.zmscore("z", "a", "no"), @[some(11.0), none(float)], "zmscore")
  eqs(c.zpopMin("z"), @[("b", 2.0)], "zpopMin")
  eqs(c.zpopMaxCount("z", 1), @[("a", 11.0)], "zpopMaxCount")
  discard c.zadd("z1", {1.0: "x", 2.0: "y"}); discard c.zadd("z2", {10.0: "y", 20.0: "w"})
  eqs(c.zunionStore("zu", ["z1", "z2"]), 3, "zunionStore")
  eqs(c.zinterStore("zi", ["z1", "z2"], weights = @[1.0, 2.0], aggregate = agMax), 1, "zinterStore")
  eqs(c.zscore("zi", "y"), some(20.0), "zinterStore weights+aggregate")
  eqs(c.zunionWithScores(["z1", "z2"]).len, 3, "zunionWithScores")
  eqs(c.zremRangeByScore("zu", "-inf", "5"), 1, "zremRangeByScore")
  eqs(c.zrem("zu", "y", "nope"), 1, "zrem")
  let zp = c.zscan("zu", "0")
  ok(zp.items.len >= 0, "zscan")

proc testMisc(c: Conn) {.flow.} =
  echo "misc"
  c.flushdb()
  eqs(c.ping(), "PONG", "ping")
  eqs(c.ping("héllo"), "héllo", "echo")
  eqs(c.pfadd("hll", "a", "b", "c"), true, "pfadd")
  eqs(c.pfcount("hll"), 3, "pfcount")
  eqs(c.geoadd("geo", [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]), 2, "geoadd")
  ok(c.geodist("geo", "Palermo", "Catania", "km").get() > 160.0, "geodist")
  eqs(c.geohash("geo", "Palermo").len, 1, "geohash")
  eqs(c.geosearch("geo", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ASC").len, 2, "geosearch")
  ok(c.info("server").contains("redis_version") or c.info("server").contains("valkey"), "info")
  ok(c.time().len == 2, "time")
  ok(c.configGet("maxmemory").len > 0, "configGet")
  ok(c.clientId() > 0, "clientId")
  c.clientSetName("rw-test")
  eqs(c.clientGetName(), some("rw-test"), "clientName")
  eqs(c.publish("nobody", "x"), 0, "publish no subscribers")
  eqs(c.command("PING", "x").to(string), "x", "raw command")
  eqs(c.call("EXISTS", "nope").to(int), 0, "call")

proc testErrors(c: Conn) {.flow.} =
  echo "errors"
  c.flushdb()
  discard c.set("str", "x")
  raises(ServerError, "WRONGTYPE"):
    discard c.lpush("str", "a")
  try:
    discard c.incr("str")
  except ServerError as e:
    ok(e.code == "ERR", "error code ERR")
    ok("not an integer" in e.msg, "error message")
  # the connection must still be perfectly in sync after errors
  eqs(c.get("str"), some("x"), "in sync after error")
  raises(ServerError, "unknown command"):
    discard c.command("NOSUCHCOMMAND")
  eqs(c.ping(), "PONG", "in sync after unknown command")

proc testPipeline(c: Conn) {.flow.} =
  echo "pipelines and transactions"
  c.flushdb()
  let p = c.batch()
  let i1 = p.set("a", "1")
  let i2 = p.incr("a")
  let i3 = p.get("a")
  let i4 = p.hgetAll("nohash")
  let i5 = p.mget("a", "nope")
  eqs(p.len, 5, "queued")
  let r = p.commit()
  eqs(r.len, 5, "replies")
  eqs(r[i1].to(bool), true, "set reply")
  eqs(r[i2].to(int), 2, "incr reply")
  eqs(r[i3].to(string), "2", "get reply")
  eqs(r[i4].to(seq[(string, string)]).len, 0, "hgetAll reply")
  eqs(r[i5].to(seq[Option[string]]), @[some("2"), none(string)], "mget reply")
  eqs(p.len, 0, "cleared after exec")
  # errors inside a batch do not raise unless asked, and do not desync
  let q = c.batch()
  q.set("s", "x"); q.lpush("s", "boom"); q.get("s")
  let r2 = q.commit()
  ok(r2[1].kind == rkError, "error reply captured")
  eqs(r2[2].to(string), "x", "later replies intact")
  let q2 = c.batch()
  q2.set("s", "x"); q2.lpush("s", "boom")
  raises(ServerError, "raiseOnError"):
    discard q2.commit(raiseOnError = true)
  eqs(c.ping(), "PONG", "in sync after batch errors")
  # big batch: forces partial writes and many reads
  let big = c.batch()
  for i in 0 ..< 20_000: big.set("bulk:" & $i, "value-" & $i)
  for i in 0 ..< 20_000: big.get("bulk:" & $i)
  let br = big.commit()
  eqs(br.len, 40_000, "20k+20k batch")
  eqs(br[39_999].to(string), "value-19999", "last reply of big batch")
  # transactions
  let tx = c.atomic()
  tx.incr("tx"); tx.incr("tx"); tx.get("tx")
  let tr = tx.commit()
  eqs(tr.len, 3, "tx results")
  eqs(tr[2].to(string), "2", "tx get")
  eqs(tx.aborted, false, "tx not aborted")
  eqs(c.get("tx"), some("2"), "tx applied")

proc testConcurrency(c: Conn) {.flow.} =
  echo "concurrency on one connection"
  c.flushdb()
  scope s:
    for i in 1 .. 200: discard s.go bump(c, 50)
  eqs(c.get("ctr"), some("10000"), "200 tasks x 50 incr on ONE connection")
  # each task must get its OWN reply back, never a neighbour's
  var tasks: seq[Task[bool]]
  for id in 0 ..< 300: tasks.add go echoer(c, id)
  var allOk = true
  for t in tasks:
    if not await(t): allOk = false
  ok(allOk, "300 tasks never see each other's replies")
  ok(c.stats.reads * 3 < c.stats.commands, "replies are batched: " & $c.stats.reads & " reads for " & $c.stats.commands & " commands")

proc testCancellation(c: Conn, pool: Pool) {.flow.} =
  echo "cancellation and timeouts"
  c.flushdb()
  # a blocking command on a shared connection that is cancelled by a timeout
  # must not poison the connection for anyone else
  pool.withConn(blk):
    var timedOut = false
    try:
      discard withTimeout(80, blk.blpop(["nolist"], 5.0))
    except TimeoutError:
      timedOut = true
    ok(timedOut, "blocking command times out")
  # reply of the abandoned command arrives later; the connection stays in sync
  let victim = go slowCmd(c)
  yieldNow()
  yieldNow()
  cancel(victim)
  var wasCancelled = false
  try: await(victim)
  except CancelledError: wasCancelled = true
  ok(wasCancelled, "task cancelled while waiting for its reply")
  # a command issued right behind the orphan must still get ITS reply
  discard c.set("after", "ok")
  eqs(c.get("after"), some("ok"), "reply after an orphaned ticket is correct")
  delay(400)                                  # the orphan's late reply arrives
  eqs(c.ping(), "PONG", "late orphan reply is discarded")
  eqs(c.get("after"), some("ok"), "still in sync")
  # many cancellations interleaved with live traffic
  var vs: seq[Task[void]]
  for i in 0 ..< 20: vs.add go victimLoop(c)
  for _ in 0 ..< 5: yieldNow()
  for v in vs: cancel(v)
  for v in vs:
    try: await(v)
    except CancelledError: discard
  for i in 1 .. 50: eqs(c.ping($i), $i, "echo after mass cancel " & $i)
  # timeout wrapper
  var tm = false
  try: discard withTimeout(50, c.blpop(["x"], 2.0))
  except TimeoutError: tm = true
  ok(tm, "withTimeout on a shared connection")
  delay(100)
  eqs(c.ping(), "PONG", "in sync after withTimeout")

proc testPool(pool: Pool) {.flow.} =
  echo "pool"
  pool.flushdb()
  eqs(pool.set("p", "1"), true, "pool set")
  eqs(pool.get("p"), some("1"), "pool get")
  scope s:
    for i in 1 .. 40: discard s.go worker(pool, 25)
  eqs(pool.get("pc"), some("1000"), "pool: 40 tasks x 25 incr")
  # optimistic locking with WATCH needs a connection of its own
  discard pool.set("balance", "100")
  pool.withConn(c):
    c.watch("balance")
    let bal = parseInt(c.get("balance").get())
    pool.withConn(other):
      discard other.set("balance", "999")       # somebody else changes it
    let tx = c.atomic()
    tx.set("balance", $(bal - 10))
    discard tx.commit()
    ok(tx.aborted, "WATCH aborted the transaction")
  eqs(pool.get("balance"), some("999"), "aborted transaction changed nothing")
  # blocking pop served by another task
  pool.withConn(blk):
    discard go pusher(pool)
    let got = blk.blpop(["jobs"], 2.0)
    eqs(got, some(("jobs", "job1")), "blpop woken by a push")
  eqs(pool.stats().commands > 0, true, "pool stats")

proc testPubSub(pool: Pool) {.flow.} =
  echo "pub/sub"
  let sub = newSubscriber(openFlow("redis://127.0.0.1:6379/15"))
  sub.subscribe("news", "alerts")
  sub.psubscribe("log.*")
  let c1 = sub.nextMessage(control = true)
  eqs(c1.kind, mkSubscribe, "subscribe confirmation")
  discard sub.nextMessage(control = true)
  discard sub.nextMessage(control = true)
  discard go publisher(pool)
  let m1 = sub.nextMessage()
  eqs((m1.kind, m1.channel, m1.data), (mkMessage, "news", "hello"), "message")
  let m2 = sub.nextMessage()
  eqs((m2.kind, m2.pattern, m2.channel, m2.data), (mkPMessage, "log.*", "log.error", "disk"), "pmessage")
  let m3 = sub.nextMessage()
  eqs(m3.data, "fire", "third message")
  # reading is cancel-safe: a timeout must not lose or corrupt anything
  var tm = false
  try: discard withTimeout(40, sub.nextMessage())
  except TimeoutError: tm = true
  ok(tm, "nextMessage times out cleanly")
  discard pool.publish("news", "after-timeout")
  eqs(sub.nextMessage().data, "after-timeout", "message after a timeout")
  sub.close()

proc testStreams(c: Conn) {.flow.} =
  echo "streams"
  c.flushdb()
  let id1 = c.xadd("st", "*", {"name": "ann", "n": "1"})
  let id2 = c.xadd("st", "*", {"name": "bob", "n": "2"})
  ok(id1.contains("-") and id2.contains("-"), "xadd ids")
  eqs(c.xlen("st"), 2, "xlen")
  let es = c.xrange("st", "-", "+")
  eqs(es.len, 2, "xrange")
  eqs(es[0]["name"], "ann", "entry field access")
  eqs("n" in es[1], true, "entry contains")
  eqs(c.xrevRange("st", "+", "-", count = 1)[0].id, id2, "xrevRange")
  let r = c.xread({"st": "0"}, count = 10)
  eqs(r.len, 1, "xread one stream")
  eqs(r[0].entries.len, 2, "xread entries")
  eqs(c.xread({"st": "$"}).len, 0, "xread nothing new")
  # capped streams
  for i in 1 .. 50: discard c.xadd("cap", "*", {"i": $i}, maxlen = exact(10))
  eqs(c.xlen("cap"), 10, "maxlen exact")
  eqs(c.xtrim("cap", maxlen = exact(5)), 5, "xtrim")
  # consumer groups
  c.xgroupCreate("st", "g", "0")
  let g1 = c.xreadGroup("g", "c1", {"st": ">"}, count = 1)
  eqs(g1[0].entries.len, 1, "xreadGroup")
  eqs(c.xack("st", "g", g1[0].entries[0].id), 1, "xack")
  eqs(c.xreadGroup("g", "c1", {"st": ">"})[0].entries.len, 1, "second entry delivered")
  eqs(c.xdel("st", id1), 1, "xdel")
  ok(c.xinfoStream("st").kind in {rkList, rkMap}, "xinfoStream")
  eqs(c.xgroupDestroy("st", "g"), 1, "xgroupDestroy")

proc testScripts(c: Conn) {.flow.} =
  echo "scripts"
  c.flushdb()
  eqs(c.eval("return ARGV[1]", [], ["hi"]).to(string), "hi", "eval")
  eqs(c.eval("return redis.call('incr', KEYS[1])", ["sk"], []).to(int), 1, "eval keys")
  let sc = newScript("return redis.call('incrby', KEYS[1], ARGV[1])")
  c.scriptFlush()
  eqs(c.run(sc, ["sk2"], ["5"]).to(int), 5, "script runs after NOSCRIPT fallback")
  eqs(c.run(sc, ["sk2"], ["5"]).to(int), 10, "script runs via EVALSHA")
  eqs(c.scriptExists(sc.sha), @[true], "scriptExists")
  eqs(c.scriptLoad("return 1"), sha1Hex("return 1"), "local sha1 matches the server's")
  raises(ServerError, "lua error"):
    discard c.eval("return redis.call('nosuch')", [], [])
  eqs(c.ping(), "PONG", "in sync after a script error")

proc testResp3() {.flow.} =
  echo "RESP3"
  let c = openFlow("127.0.0.1", 6379, Config(protocol: 3, readBufSize: 16384, tcpNoDelay: true, db: 15))
  c.flushdb()
  discard c.hsetMany("h3", {"a": "1", "b": "2"})
  eqs(c.hgetAll("h3"), @[("a", "1"), ("b", "2")], "hgetAll over RESP3 map")
  discard c.sadd("s3", "x", "y")
  eqs(c.smembers("s3").len, 2, "smembers over RESP3 set")
  discard c.zadd("z3", {1.5: "m"})
  eqs(c.zscore("z3", "m"), some(1.5), "zscore over RESP3 double")
  eqs(c.zrangeWithScores("z3", 0, -1), @[("m", 1.5)], "zrangeWithScores RESP3")
  eqs(c.get("nope"), none(string), "nil over RESP3")
  eqs(c.exists("h3"), true, "bool over RESP3")
  eqs(c.zpopMin("z3"), @[("m", 1.5)], "zpopMin RESP3")
  c.close()

proc testConnection() {.flow.} =
  echo "connection"
  var failedConnect = false
  try: discard openFlow("127.0.0.1", 1)
  except CatchableError: failedConnect = true
  ok(failedConnect, "connecting to a closed port raises")
  let c = openFlow(opts = db15)
  ok(c.isConnected, "connected")
  c.close()
  raises(ConnectionError, "use after close"):
    discard c.ping()
  let u = parseRedisUrl("redis://user:p%40ss@example.com:7000/3")
  eqs((u.host, u.port, u.opts.username, u.opts.password, u.opts.db), ("example.com", 7000, "user", "p@ss", 3), "url parsing")
  eqs(parseRedisUrl("redis://localhost").port, 6379, "default port")
  eqs(parseRedisUrl("unix:///tmp/r.sock?db=2").path, "/tmp/r.sock", "unix url")
  # server closing the connection is reported, not hung on
  let d = openFlow(opts = db15)
  discard d.clientId()
  let killer = openFlow(opts = db15)
  discard killer.call("CLIENT", "KILL", "ID", $d.clientId())
  var gotErr = false
  try:
    delay(20)
    discard d.ping()
  except ConnectionError: gotErr = true
  ok(gotErr, "killed connection raises ConnectionError")
  ok(not d.isConnected, "marked broken")
  d.reconnect()
  eqs(d.ping(), "PONG", "reconnect works")
  d.close()
  # a pool replaces a dead shared connection by itself
  let pool = openPool(2, 4, opts = db15)
  let id1 = pool.clientId()
  let id2 = pool.clientId()
  discard killer.call("CLIENT", "KILL", "ID", $id1)
  discard killer.call("CLIENT", "KILL", "ID", $id2)
  delay(30)
  var healed = false
  for _ in 0 ..< 4:
    try:
      discard pool.ping()
      healed = true
    except ConnectionError: discard
  ok(healed, "pool heals after its connections were killed")
  pool.close()
  killer.close()

proc main() {.flow.} =
  let c = openFlow(opts = db15)
  let pool = openPool(3, 8, opts = db15)
  testStrings(c)
  testKeys(c)
  testHashes(c)
  testLists(c)
  testSets(c)
  testZsets(c)
  testMisc(c)
  testErrors(c)
  testPipeline(c)
  testConcurrency(c)
  testCancellation(c, pool)
  testPool(pool)
  testPubSub(pool)
  testStreams(c)
  testScripts(c)
  testResp3()
  testConnection()
  c.flushdb()
  c.close()
  pool.close()
  echo "\n", passed, " passed, ", failed, " failed"
  if failed > 0: quit(1)

run main()
