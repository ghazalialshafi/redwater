## A job queue on Conn Streams with consumer groups: producers, workers that
## ack, and a clean shutdown by cancelling the scope.
import std/strutils
import ../src/redwater

proc producer(c: Conn, n: int) {.flow.} =
  for i in 1 .. n:
    discard c.xadd("jobs", "*", {"task": "resize", "image": "img" & $i & ".png"})

proc worker(pool: Pool, name: string, done: ref int) {.flow.} =
  pool.withConn(c):                           # XREADGROUP BLOCK occupies its connection
    while true:
      let batches = c.xreadGroup("workers", name, {"jobs": ">"}, count = 5, blockMs = 200)
      for b in batches:
        for e in b.entries:
          # ... do the work for e["image"] ...
          discard c.xack("jobs", "workers", e.id)
          inc done[]
      if done[] >= 20: return

proc main() {.flow.} =
  let pool = openPool(2, 8, opts = initConfig(db = 15))
  pool.flushdb()
  pool.xgroupCreate("jobs", "workers", "0", mkstream = true)
  let done = new int
  scope s:
    discard s.go producer(pool.pick(), 20)
    for i in 1 .. 3: discard s.go worker(pool, "w" & $i, done)
  echo "processed ", done[], " jobs; pending: ", pool.xpending("jobs", "workers")
  pool.close()

run main()
