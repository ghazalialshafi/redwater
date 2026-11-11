## Chaos test for the ticket / orphan machinery: many tasks share ONE connection,
## some are cancelled at random moments (timeouts of 0-3 ms, slow commands, big
## pipelines). Every task that completes must have received exactly its own reply
## and the connection must stay in sync throughout.
import std/[options, random, strutils, os]
import ../src/redwater

var bad = 0
var completed, cancelled = 0

proc oneOp(c: Conn, id, i: int, r: int) {.flow.} =
  let tag = "w" & $id & ":" & $i
  case r mod 60
  of 0 .. 9:
    let got = c.ping(tag)
    if got != tag: inc bad; echo "MISMATCH echo ", tag, " got ", got
  of 10 .. 24:
    discard c.set("k" & $id, tag)
    let got = c.get("k" & $id)
    # another iteration of the same task may not interleave: only we write k<id>
    if got != some(tag): inc bad; echo "MISMATCH get ", tag, " got ", got
  of 25 .. 36:
    let p = c.batch()
    for j in 0 ..< 5: p.ping(tag & "/" & $j)
    let rs = p.commit()
    for j in 0 ..< 5:
      if rs[j].to(string) != tag & "/" & $j: inc bad; echo "MISMATCH pipe ", tag
  of 37 .. 46:
    let n = c.incr("chaos:ctr")
    if n <= 0: inc bad
  of 47:
    # slow reply (redis checks blocking timeouts on its ~100 ms tick)
    discard c.blpop(["chaos:nolist"], 0.003)
  else:
    let tx = c.atomic()
    tx.ping(tag); tx.incr("chaos:tx")
    let rs = tx.commit()
    if rs.len != 2 or rs[0].to(string) != tag: inc bad; echo "MISMATCH tx ", tag

proc worker(c: Conn, id: int, seed: int, iters: int) {.flow.} =
  var rng = initRand(seed)
  for i in 0 ..< iters:
    let r = rng.rand(1000)
    if rng.rand(5) == 0:
      # run this op under a random, tiny deadline: often cancels mid-flight
      try:
        withTimeout(rng.rand(3), c.oneOp(id, i, r))
        inc completed
      except TimeoutError:
        inc cancelled
    else:
      c.oneOp(id, i, r)
      inc completed

proc main() {.flow.} =
  let c = openFlow(opts = initConfig(db = 15))
  c.flushdb()
  var tasks: seq[Task[void]]
  let nTasks = if paramCount() >= 1: parseInt(paramStr(1)) else: 40
  let iters = if paramCount() >= 2: parseInt(paramStr(2)) else: 60
  for id in 0 ..< nTasks: tasks.add go worker(c, id, 1000 + id, iters)
  for t in tasks: await(t)
  # the connection must be fully usable and in sync afterwards
  for i in 1 .. 100:
    let s = "final" & $i
    if c.ping(s) != s: inc bad
  delay(50)
  if c.ping() != "PONG": inc bad
  echo "completed=", completed, " cancelled=", cancelled, " bad=", bad
  echo c.stats
  c.flushdb()
  c.close()
  if bad > 0 or cancelled == 0: quit(1)

run main()
