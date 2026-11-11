## Lua scripts with automatic EVALSHA caching: an atomic fixed-window rate
## limiter shared by many tasks.
import ../src/redwater

let limiter = newScript("""
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end
if n > tonumber(ARGV[2]) then return 0 end
return 1
""")

proc client(c: Conn, id: int, allowed: ref int, denied: ref int) {.flow.} =
  for i in 1 .. 10:
    let ok = c.run(limiter, ["rate:demo"], ["1000", "25"]).to(int)   # 25 per second
    if ok == 1: inc allowed[] else: inc denied[]

proc main() {.flow.} =
  let c = openFlow("redis://127.0.0.1:6379/15")
  c.flushdb()
  let allowed, denied = new int
  scope s:
    for id in 1 .. 8: discard s.go client(c, id, allowed, denied)
  echo "allowed ", allowed[], ", denied ", denied[]            # allowed 25, denied 55
  c.close()

run main()
