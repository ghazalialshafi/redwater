import std/asyncdispatch
import redis
proc main() {.async.} =
  let c = await openAsync()
  await c.setk("k", "0123456789abcdef0123456789abcdef")
  for i in 0 ..< 10000:
    discard await c.get("k")
    discard await c.incr("n")
  c.quit()
waitFor main()
