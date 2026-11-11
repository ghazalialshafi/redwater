## Sentinel tests. Needs tests/sentinel.sh (master 7001, replica 7002, sentinel 27001).
import std/[options, strutils]
import ../src/redwater

var passed, failed = 0
proc ok(c: bool, what: string) =
  if c: inc passed
  else: inc failed; echo "  FAIL: ", what
proc eqs[T](got, want: T, what: string) =
  if got == want: inc passed
  else: inc failed; echo "  FAIL: ", what, " got ", got, " want ", want

proc sentCfg(): Config =
  result = defaultConfig()
  result.sentinels = @[("127.0.0.1", 27001)]
  result.masterName = "mymaster"
  result.connectTimeoutMs = 1500

proc role(c: Conn): string {.flow.} =
  c.call("ROLE")[0].to(string)

proc writer(pool: Pool, stop: ref bool, okCount, errCount: ref int) {.flow.} =
  var i = 0
  while not stop[]:
    inc i
    try:
      discard pool.set("fo:" & $i, "v")
      inc okCount[]
    except CatchableError:
      inc errCount[]
    delay(10)

proc main() {.flow.} =
  echo "discovery"
  let c = openFlow(sentCfg())
  eqs(c.port, 7001, "found the master through the sentinel")
  eqs(c.role(), "master", "ROLE is master")
  discard c.set("sent:k", "v")
  c.close()

  var rc = sentCfg(); rc.useReplica = true
  let r = openFlow(rc)
  eqs(r.port, 7002, "found the replica")
  eqs(r.role(), "slave", "ROLE is slave")
  r.close()

  var two = sentCfg()
  two.sentinels = @[("127.0.0.1", 1), ("127.0.0.1", 27001)]      # first one is dead
  let c2 = openFlow(two)
  eqs(c2.port, 7001, "skips an unreachable sentinel")
  c2.close()

  var bad = sentCfg(); bad.masterName = "nosuchmaster"
  var unknown = false
  try: discard openFlow(bad)
  except ConnectFailed as e: unknown = "nosuchmaster" in e.msg
  ok(unknown, "unknown master name is a clear ConnectFailed")

  echo "failover"
  var pc = sentCfg(); pc.maxAttempts = 20; pc.retryBaseMs = 100; pc.retryMaxMs = 500
  let pool = openPool(2, 4, opts = pc)
  let admin = openFlow("127.0.0.1", 7001)
  let stop = new bool
  let okCount, errCount = new int
  let w = go writer(pool, stop, okCount, errCount)
  delay(300)
  ok(okCount[] > 5, "writes flowing before the failure")
  let before = okCount[]
  try: discard admin.call("SHUTDOWN", "NOSAVE")                 # the master dies
  except ConnectionError: discard
  # keep writing: the pool must find the promoted replica on its own
  var recovered = false
  for _ in 0 ..< 120:
    delay(100)
    if okCount[] > before + 20:
      recovered = true
      break
  stop[] = true
  await(w)
  ok(recovered, "writes resume on the new master (ok=" & $okCount[] & " err=" & $errCount[] & ")")
  let info = openFlow("127.0.0.1", 7002)
  eqs(info.role(), "master", "the replica was promoted")
  eqs(info.get("sent:k"), some("v"), "data survived the failover")
  eqs(pool.get("sent:k"), some("v"), "pool reads from the new master")
  info.close(); pool.close(); admin.close()
  echo "\n", passed, " passed, ", failed, " failed"
  if failed > 0: quit(1)

run main()
