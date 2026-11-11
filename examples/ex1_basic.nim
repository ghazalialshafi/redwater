## The basics: connect, strings, hashes, lists, errors. No `await` anywhere.
## nim c -d:danger --mm:arc -r examples/ex1_basic.nim
import std/options
import ../src/redwater

proc main() {.flow.} =
  let c = openFlow("redis://127.0.0.1:6379/15")      # parks, never blocks the thread
  c.flushdb()

  discard c.set("greeting", "hello", ex = 60)          # SET greeting hello EX 60
  echo c.get("greeting")                               # some("hello")
  echo c.get("nothing")                                # none(string): a missing key is not ""

  discard c.incr("visits")
  echo c.incrBy("visits", 41)                          # 42

  discard c.hsetMany("user:1", {"name": "Ada", "lang": "Nim"})
  for (field, value) in c.hgetAll("user:1"):
    echo field, " = ", value

  discard c.rpush("queue", "a", "b", "c")
  echo c.lrange("queue", 0, -1)                        # @["a", "b", "c"]

  try:
    discard c.lpush("greeting", "x")                   # wrong type
  except ServerError as e:
    echo "server said ", e.code                        # WRONGTYPE

  c.close()

run main()
