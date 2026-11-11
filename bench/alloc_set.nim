import ../src/redwater
proc main() {.flow.} =
  let c = openFlow()
  for i in 0 ..< 10000:
    discard c.set("k", "0123456789abcdef")
    discard c.incr("n")
    discard c.exists("k")
  c.close()
run main()
