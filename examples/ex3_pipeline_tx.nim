## Pipelines, atomic transactions, and optimistic locking with WATCH.
import std/[options, strutils]
import ../src/redwater

proc withdraw(pool: Pool, amount: int): bool {.flow.} =
  ## optimistic locking: retry while somebody else touches the key
  for attempt in 1 .. 5:
    pool.withConn(c):                         # WATCH needs a connection of its own
      c.watch("balance")
      let bal = parseInt(c.get("balance").get())
      if bal < amount:
        c.unwatch()
        return false
      let tx = c.atomic()
      tx.set("balance", $(bal - amount))
      discard tx.commit()
      if not tx.aborted: return true
  false

proc main() {.flow.} =
  let pool = openPool(2, 4, opts = initConfig(db = 15))
  pool.flushdb()

  pool.withConn(c):
    # 1. a batch: ONE write, N replies. Queue calls return the reply's index.
    let p = c.batch()
    p.set("n", "10")
    let b = p.incrBy("n", 5)
    let g = p.get("n")
    let r = p.commit()
    echo "n after batch = ", r[g].to(string), " (incrBy replied ", r[b].to(int), ")"

    # 2. a transaction: MULTI .. EXEC, results of the queued commands
    let tx = c.atomic()
    tx.decrBy("n", 3)
    tx.get("n")
    echo "transaction results: ", tx.commit()

  # 3. optimistic locking
  discard pool.set("balance", "100")
  echo "withdraw 30: ", withdraw(pool, 30), ", balance ", pool.get("balance")
  echo "withdraw 80: ", withdraw(pool, 80), ", balance ", pool.get("balance")
  pool.close()

run main()
