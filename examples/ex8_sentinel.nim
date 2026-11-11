## Sentinel: give the sentinels and the master's name, never an address. After
## a failover the pool re-asks the sentinels and carries on.
import ../src/redwater

proc main() {.flow.} =
  var cfg = defaultConfig()
  cfg.sentinels = @[("sentinel-1", 26379), ("sentinel-2", 26379), ("sentinel-3", 26379)]
  cfg.masterName = "mymaster"
  # cfg.useReplica = true                       # read from a replica instead
  let pool = openPool(4, 8, opts = cfg)
  discard pool.set("k", "v")                    # retried transparently if a failover happens
  echo pool.get("k")
  pool.close()

run main()
