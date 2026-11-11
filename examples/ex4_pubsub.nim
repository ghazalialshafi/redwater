## Publish / subscribe. The subscriber owns a connection; reads are cancel-safe,
## so timeouts compose.
import ../src/redwater

proc publisher(c: Conn) {.flow.} =
  for i in 1 .. 3:
    delay(20)
    discard c.publish("news", "headline " & $i)
  discard c.publish("log.warn", "disk almost full")

proc main() {.flow.} =
  let c = openFlow()
  let sub = newSubscriber(openFlow())
  sub.subscribe("news")
  sub.psubscribe("log.*")
  discard go publisher(c)

  var seen = 0
  while seen < 4:
    let m = sub.nextMessage()                 # waits; skips subscribe confirmations
    case m.kind
    of mkMessage: echo "[", m.channel, "] ", m.data
    of mkPMessage: echo "[", m.pattern, " -> ", m.channel, "] ", m.data
    else: discard
    inc seen

  try:                                        # nothing is coming: give up after 50 ms
    discard withTimeout(50, sub.nextMessage())
  except TimeoutError:
    echo "quiet."
  sub.close(); c.close()

run main()
