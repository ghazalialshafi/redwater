## nim-lang/redis (blocking client) benchmark: sequential + pipeline only.
import std/monotimes
import redis
import common

const N = 100_000

proc seqOps(c: Redis, n: int): Result =
  var lat = newSeqOfCap[float](n)
  let tm = startTimer()
  for i in 0 ..< n div 2:
    let k = "key:" & $(i mod 1000)
    var t0 = getMonoTime()
    c.setk(k, Payload)
    lat.add usSince(t0)
    t0 = getMonoTime()
    discard c.get(k)
    lat.add usSince(t0)
  result = tm.stop("seq SET/GET, 1 conn, 1 task", n, lat)

proc pipelined(c: Redis, n: int, batch: int): Result =
  let tm = startTimer()
  var done = 0
  while done < n:
    c.startPipelining()
    for i in 0 ..< batch: c.setk("pk:" & $((done + i) mod 5000), Payload)
    discard c.flushPipeline()
    done += batch
  result = tm.stop("pipeline SET, batch " & $batch, n)

let c = redis.open()
discard c.flushdb()
discard seqOps(c, 20_000)
report seqOps(c, N)
report pipelined(c, N, 100)
report pipelined(c, N * 5, 1000)
