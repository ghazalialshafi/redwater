## Allocation probe: runs a fixed number of GET/SET/INCR round trips (run it under ltrace).
import ../src/redwater
proc main() {.flow.} =
  let c = openFlow()
  discard c.set("k", "0123456789abcdef0123456789abcdef")
  for i in 0 ..< 10000:
    discard c.get("k")
    discard c.incr("n")
  c.close()
run main()
