## nim-lang/redis (asyncdispatch) benchmark: same workloads.
import std/[monotimes, asyncdispatch]
import redis
import common

const N = 100_000
const Workers = 50

proc seqOps(c: AsyncRedis, n: int): Future[Result] {.async.} =
  var lat = newSeqOfCap[float](n)
  let tm = startTimer()
  for i in 0 ..< n div 2:
    let k = "key:" & $(i mod 1000)
    var t0 = getMonoTime()
    await c.setk(k, Payload)
    lat.add usSince(t0)
    t0 = getMonoTime()
    discard await c.get(k)
    lat.add usSince(t0)
  result = tm.stop("seq SET/GET, 1 conn, 1 task", n, lat)

proc incrLoop(c: AsyncRedis, n: int) {.async.} =
  for _ in 1 .. n: discard await c.incr("bench:ctr")

proc concShared(c: AsyncRedis, n: int): Future[Result] {.async.} =
  let tm = startTimer()
  var fs: seq[Future[void]]
  for _ in 1 .. Workers: fs.add incrLoop(c, n div Workers)
  await all(fs)
  result = tm.stop("conc INCR, 50 tasks, 1 shared conn", n)

proc incrOwn(n: int) {.async.} =
  let c = await openAsync()
  for _ in 1 .. n: discard await c.incr("bench:ctr")
  c.quit()

proc concOwn(n: int): Future[Result] {.async.} =
  let tm = startTimer()
  var fs: seq[Future[void]]
  for _ in 1 .. Workers: fs.add incrOwn(n div Workers)
  await all(fs)
  result = tm.stop("conc INCR, 50 tasks, 50 conns (1 per task)", n)

proc pipelined(c: AsyncRedis, n: int, batch: int): Future[Result] {.async.} =
  let tm = startTimer()
  var done = 0
  while done < n:
    c.startPipelining()
    for i in 0 ..< batch: await c.setk("pk:" & $((done + i) mod 5000), Payload)
    discard await c.flushPipeline()
    done += batch
  result = tm.stop("pipeline SET, batch " & $batch, n)

proc main() {.async.} =
  let c = await openAsync()
  discard await c.flushdb()
  discard await seqOps(c, 20_000)
  report await seqOps(c, N)
  report await concShared(c, N)
  report await concOwn(N)
  report await pipelined(c, N, 100)
  report await pipelined(c, N * 5, 1000)

waitFor main()
