## Cluster: commands are routed by key slot; MOVED / ASK are followed for you.
import ../src/redwater

proc main() {.flow.} =
  let cl = openCluster("127.0.0.1:7101,127.0.0.1:7102")   # any seeds; the rest is discovered
  for i in 0 ..< 100: discard cl.set("user:" & $i, "x")   # spread over the masters
  echo cl.get("user:42")
  # related keys: share a slot with a {hash tag}, then multi-key commands and
  # transactions work
  cl.mset({"{cart:9}:items": "3", "{cart:9}:total": "30"})
  let tx = cl.connFor("{cart:9}:items").atomic()
  tx.incr("{cart:9}:items"); tx.incrBy("{cart:9}:total", 10)
  echo tx.commit()
  echo "keys in the cluster: ", cl.totalKeys()
  cl.close()

run main()
