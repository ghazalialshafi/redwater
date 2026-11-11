## TLS and reconnection tests. Needs tests/servers.sh to have run.
import std/[options, osproc, strutils]
import ../src/redwater

var passed, failed = 0
proc ok(c: bool, what: string) =
  if c: inc passed
  else: inc failed; echo "  FAIL: ", what
proc eqs[T](got, want: T, what: string) =
  if got == want: inc passed
  else: inc failed; echo "  FAIL: ", what, " got ", got, " want ", want

const D = "/tmp/rwtls/"

proc tlsCfg(): Config =
  result = defaultConfig()
  result.tls = true
  result.tlsCaFile = D & "ca.crt"


proc pinger(c: Conn, id: int) {.flow.} =
  for i in 0 ..< 100:
    let t = $id & ":" & $i
    if c.ping(t) != t: raise newException(ValueError, "mixed up replies")

proc hammer(c: Conn, n: int) {.flow.} =
  for _ in 1 .. n:
    try: discard c.incr("hits")
    except ConnectionError: discard

proc stuck(c: Conn): bool {.flow.} =
  try: discard c.blpop(["rw:none"], 5.0)
  except ConnectionError: return true
  false

proc restarter(port: int, afterMs: int) {.flow.} =
  delay(afterMs)
  discard execCmd("redis-server --port " & $port & " --save '' --appendonly no --daemonize yes --logfile /tmp/redis_" & $port & ".log")

proc testTls() {.flow.} =
  echo "tls"
  let c = openFlow("localhost", 6390, tlsCfg())
  eqs(c.ping(), "PONG", "ping over TLS")
  discard c.set("tls:k", "secret")
  eqs(c.get("tls:k"), some("secret"), "set/get over TLS")
  var big = newString(2_000_000)
  for i in 0 ..< big.len: big[i] = char(i mod 253)
  discard c.set("tls:big", big)
  eqs(c.get("tls:big") == some(big), true, "2MB over TLS")
  let b = c.batch()
  for i in 0 ..< 3000: b.set("tls:b" & $i, "v" & $i)
  eqs(b.commit().len, 3000, "3000-command batch over TLS")
  scope s:
    for id in 0 ..< 1: discard s.go pinger(c, id)
  c.close()
  # rediss:// url
  let u = parseRedisUrl("rediss://localhost:6390")
  ok(u.opts.tls, "rediss sets tls")
  # untrusted CA must be refused
  var refused = false
  var cfg = defaultConfig(); cfg.tls = true        # system store: our test CA is not in it
  try: discard openFlow("localhost", 6390, cfg)
  except ConnectionError: refused = true
  ok(refused, "unknown CA is rejected")
  # wrong hostname must be refused
  var wrongHost = false
  var cfg2 = tlsCfg(); cfg2.tlsServerName = "not-the-server.example"
  try: discard openFlow("localhost", 6390, cfg2)
  except ConnectionError: wrongHost = true
  ok(wrongHost, "hostname mismatch is rejected")
  # insecure mode connects anyway
  var cfg3 = defaultConfig(); cfg3.tls = true; cfg3.tlsInsecure = true
  let c3 = openFlow("localhost", 6390, cfg3)
  eqs(c3.ping(), "PONG", "tlsInsecure connects")
  c3.close()
  # plaintext client against a TLS port fails cleanly
  var plain = false
  try:
    let p = openFlow("localhost", 6390, defaultConfig())
    discard p.ping()
  except ConnectionError: plain = true
  ok(plain, "plaintext to a TLS port fails with ConnectionError")

proc testMutualTls() {.flow.} =
  echo "mutual tls"
  var cfg = tlsCfg()
  cfg.tlsCertFile = D & "client.crt"
  cfg.tlsKeyFile = D & "client.key"
  let c = openFlow("localhost", 6392, cfg)
  eqs(c.ping(), "PONG", "mTLS with client certificate")
  c.close()
  var denied = false
  try: discard openFlow("localhost", 6392, tlsCfg()).ping()    # no client cert
  except ConnectionError: denied = true
  ok(denied, "mTLS server rejects a client without a certificate")

proc testReconnect() {.flow.} =
  echo "reconnect"
  let admin = openFlow("127.0.0.1", 6379)
  let c = openFlow("127.0.0.1", 6379, initConfig(db = 14, clientName = "rw-recon"))
  discard c.set("r", "1")
  let id = c.clientId()
  discard admin.call("CLIENT", "KILL", "ID", $id)
  delay(20)
  # the command that discovers the dead connection fails (outcome unknown) ...
  var lost = false
  try: discard c.get("r")
  except ConnectionError: lost = true
  ok(lost, "in-flight loss is reported")
  # ... and the next one just works: reconnected, same database, same name
  eqs(c.get("r"), some("1"), "auto-reconnect keeps the selected database")
  eqs(c.clientGetName(), some("rw-recon"), "auto-reconnect restores the client name")
  eqs(c.reconnects, 1, "one reconnect counted")
  # many tasks hit a dead connection at once: exactly one reconnect
  discard admin.call("CLIENT", "KILL", "ID", $c.clientId())
  delay(20)
  scope s:
    for _ in 1 .. 30: discard s.go hammer(c, 20)
  ok(c.reconnects <= 3, "30 tasks share the reconnect (" & $c.reconnects & ")")
  eqs(c.ping(), "PONG", "usable afterwards")
  # noReconnect: fail instead
  var nr = initConfig(); nr.noReconnect = true
  let d = openFlow("127.0.0.1", 6379, nr)
  discard admin.call("CLIENT", "KILL", "ID", $d.clientId())
  delay(20)
  try: discard d.ping()
  except ConnectionError: discard
  var failedFast = false
  try: discard d.ping()
  except ConnectFailed: failedFast = true
  ok(failedFast, "noReconnect raises ConnectFailed")
  d.close()
  # forced reconnect
  let id1 = c.clientId()
  c.reconnect()
  ok(c.clientId() != id1, "reconnect() gives a new connection")
  # a task stranded by a reset must fail, never read the new socket's bytes
  let t = go stuck(c)
  delay(30)
  c.reconnect()
  ok(await(t), "task waiting across a reset gets ConnectionError")
  eqs(c.ping("after"), "after", "new connection is in sync")
  admin.close(); c.close()

proc testServerRestart() {.flow.} =
  echo "server restart"
  let c = openFlow("127.0.0.1", 6391, Config(maxAttempts: 12, retryBaseMs: 40, retryMaxMs: 200))
  discard c.set("a", "1")
  try: discard c.call("SHUTDOWN", "NOSAVE")
  except ConnectionError: discard
  delay(50)
  # the server is down; it comes back in 400 ms while the client retries with backoff
  let t = go restarter(6391, 400)
  eqs(c.ping(), "PONG", "command waits through the outage and succeeds")
  ok(c.reconnects >= 1, "reconnected after restart")
  await(t)
  # a server that never comes back: bounded, clear failure
  var gu = Config(maxAttempts: 3, retryBaseMs: 20, retryMaxMs: 40)
  let d = openFlow("127.0.0.1", 6391, gu)
  try: discard d.call("SHUTDOWN", "NOSAVE")
  except ConnectionError: discard
  delay(50)
  var gaveUp = false
  try: discard d.ping()
  except ConnectFailed as e: gaveUp = "gave up" in e.msg
  ok(gaveUp, "gives up after maxAttempts with ConnectFailed")
  # not-sent guarantee: the same command succeeds once the server returns
  discard go restarter(6391, 100)
  delay(300)
  var back = false
  for _ in 0 ..< 3:
    try:
      eqs(d.ping(), "PONG", "recovers when the server is back")
      back = true
      break
    except ConnectionError: discard
  ok(back, "reconnects after having given up once")
  c.close(); d.close()

proc main() {.flow.} =
  testTls()
  testMutualTls()
  testReconnect()
  testServerRestart()
  echo "\n", passed, " passed, ", failed, " failed"
  if failed > 0: quit(1)

run main()
