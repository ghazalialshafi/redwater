## One connection, a thousand tasks. Commands from all tasks are pipelined
## automatically; every task still gets exactly its own reply.
import ../src/redwater

proc worker(c: Conn, id: int) {.flow.} =
  for i in 1 .. 100:
    discard c.incr("hits")
    let tag = $id & ":" & $i
    doAssert c.ping(tag) == tag          # never somebody else's reply

proc main() {.flow.} =
  let c = openFlow("redis://127.0.0.1:6379/15")
  c.flushdb()
  scope s:                                   # structured: waits for every task
    for id in 1 .. 1000: discard s.go worker(c, id)
  echo "hits = ", c.get("hits")              # 100000
  let st = c.stats
  echo st.commands, " commands in ", st.writes, " writes and ", st.reads, " reads"
  c.close()

run main()
