## Shared benchmark harness: identical workloads and identical metrics for every client.
import std/[monotimes, times, algorithm, strutils, posix]

const
  PayloadLen* = 32
  Payload* = "x".repeat(PayloadLen)

type Result* = object
  name*: string
  ops*: int
  secs*: float
  lat*: seq[float]          # per-op latency in microseconds (may be empty)
  minflt*: int
  cpuSecs*: float

proc rusage(): tuple[minflt: int, cpu: float] =
  var ru: RUsage
  discard getrusage(RUSAGE_SELF, addr ru)
  (int(ru.ru_minflt),
   float(ru.ru_utime.tv_sec) + float(ru.ru_utime.tv_usec) / 1e6 +
   float(ru.ru_stime.tv_sec) + float(ru.ru_stime.tv_usec) / 1e6)

type Timer* = object
  t0: MonoTime
  f0: int
  c0: float

proc startTimer*(): Timer =
  let r = rusage()
  Timer(t0: getMonoTime(), f0: r.minflt, c0: r.cpu)

proc stop*(t: Timer, name: string, ops: int, lat: seq[float] = @[]): Result =
  let dt = float((getMonoTime() - t.t0).inNanoseconds) / 1e9
  let r = rusage()
  Result(name: name, ops: ops, secs: dt, lat: lat, minflt: r.minflt - t.f0, cpuSecs: r.cpu - t.c0)

proc usSince*(t0: MonoTime): float {.inline.} =
  float((getMonoTime() - t0).inNanoseconds) / 1000.0

proc pct(s: seq[float], p: float): float =
  if s.len == 0: return 0
  s[min(s.len - 1, int(float(s.len) * p))]

proc report*(r: Result) =
  var lat = r.lat
  lat.sort()
  let avg = r.secs / float(r.ops) * 1e6
  echo "RESULT|", r.name, "|", int(float(r.ops) / r.secs), "|", avg.formatFloat(ffDecimal, 1),
       "|", pct(lat, 0.50).formatFloat(ffDecimal, 1), "|", pct(lat, 0.99).formatFloat(ffDecimal, 1),
       "|", r.minflt, "|", r.cpuSecs.formatFloat(ffDecimal, 2)
