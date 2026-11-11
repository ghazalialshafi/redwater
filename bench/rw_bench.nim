## redwater benchmark. nim c -d:danger --mm:arc --path:<stagelane>/src bench/rw_bench.nim
import std/[monotimes, os, strutils]
import ../src/redwater
import common

const N = 100_000
const Workers = 50

proc seqOps(c: Conn, n: int, tag: string = ""): Result {.flow.} =
  var lat = newSeqOfCap[float](n)
  let tm = startTimer()
  for i in 0 ..< n div 2:
    let k = "key:" & $(i mod 1000)
    var t0 = getMonoTime()
    discard c.set(k, Payload)
    lat.add usSince(t0)
    t0 = getMonoTime()
    discard c.get(k)
    lat.add usSince(t0)
  result = tm.stop("seq SET/GET, 1 conn, 1 task" & tag, n, lat)

proc incrLoop(c: Conn, n: int) {.flow.} =
  for _ in 1 .. n: discard c.incr("bench:ctr")

proc concShared(c: Conn, n: int, tag: string = ""): Result {.flow.} =
  let tm = startTimer()
  scope s:
    for _ in 1 .. Workers: discard s.go incrLoop(c, n div Workers)
  result = tm.stop("conc INCR, 50 tasks, 1 shared conn" & tag, n)

proc incrPool(p: Pool, n: int) {.flow.} =
  for _ in 1 .. n: discard p.incr("bench:ctr")

proc concPool(p: Pool, n: int): Result {.flow.} =
  let tm = startTimer()
  scope s:
    for _ in 1 .. Workers: discard s.go incrPool(p, n div Workers)
  result = tm.stop("conc INCR, 50 tasks, pool of 4 shared conns", n)

proc pipelined(c: Conn, n: int, batch: int): Result {.flow.} =
  let tm = startTimer()
  var done = 0
  while done < n:
    let p = c.batch()
    for i in 0 ..< batch: p.set("pk:" & $((done + i) mod 5000), Payload)
    discard p.commit()
    done += batch
  result = tm.stop("batch SET, batch " & $batch, n)

proc main() {.flow.} =
  let c = openFlow()
  let pool = openPool(4)
  c.flushdb()
  discard seqOps(c, 20_000)                      # warm up
  report seqOps(c, N)
  report concShared(c, N)
  report concPool(pool, N)
  report pipelined(c, N, 100)
  report pipelined(c, N * 5, 1000)
  echo "STATS|", c.stats
  c.close(); pool.close()

run main()
