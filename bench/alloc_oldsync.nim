import redis
let c = redis.open()
c.setk("k", "0123456789abcdef0123456789abcdef")
for i in 0 ..< 10000:
  discard c.get("k")
  discard c.incr("n")
