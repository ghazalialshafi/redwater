# Command reference

_Generated from the `{.cmd.}` declarations in `src/redwater/` by `tools/gen_api.py` - do not edit by hand._

Every command below exists in **four forms** with the same arguments:

| form | call | what it does |
|---|---|---|
| connection | `c.get("k")` | `{.flow.}` proc: sends, waits for the reply, returns the typed result |
| batch | `p.get("k")` | queues the command, returns the index of its reply in `p.exec()` |
| pool | `pool.get("k")` | runs on the pool's next shared connection, retried when safe |
| cluster | `cl.get("k")` | routed to the master owning the key's slot; MOVED/ASK followed (except per-node commands: dbsize, flushdb, flushall, keys, scan, randomkey, select, watch) |

Optional arguments are shown with their defaults; `noArg` means "not sent". A boolean option sends just its keyword (`nx = true` sends `NX`).


## Connection & server

| signature | returns | sends | description |
|---|---|---|---|
| `asking()` | `void` | `ASKING` | Cluster redirection helper (sent for you after an `ASK` reply). |
| `ping()` | `string` | `PING` | Returns `PONG`. |
| `ping(message: string)` | `string` | `ECHO` | Returns `message` (round-trips it through the server). |
| `useDb(index: int)` | `void` | `SELECT` | Selects database `index` for this connection. |
| `quit()` | `void` | `QUIT` | Asks the server to close the connection. |
| `clientSetName(name: string)` | `void` | `CLIENT SETNAME` | Names this connection (visible in `CLIENT LIST`). |
| `clientGetName()` | `Option[string]` | `CLIENT GETNAME` | The name set with `clientSetName`, if any. |
| `clientId()` | `int` | `CLIENT ID` | This connection's id. |
| `clientList()` | `string` | `CLIENT LIST` | Text describing every client connection. |
| `clientKill(addrPort: string)` | `bool` | `CLIENT KILL` | Closes the client at `ip:port`. |
| `reset()` | `void` | `RESET` | Resets the connection state (database, name, subscriptions, ...). |
| `info(section: string = "")` | `string` | `INFO` | Server information; `section` is sent as an argument when given. |
| `dbsize()` | `int` | `DBSIZE` | Number of keys in the current database. |
| `flushdb(async: bool = false)` | `void` | `FLUSHDB` | Removes every key of the current database. |
| `flushall(async: bool = false)` | `void` | `FLUSHALL` | Removes every key of every database. |
| `lastsave()` | `int` | `LASTSAVE` | Unix time of the last successful save. |
| `save()` | `void` | `SAVE` | Synchronous save (blocks the server). |
| `bgsave()` | `string` | `BGSAVE` | Starts a background save. |
| `bgrewriteaof()` | `string` | `BGREWRITEAOF` | Starts an append-only-file rewrite. |
| `time()` | `seq[string]` | `TIME` | `[unix seconds, microseconds]`. |
| `configGet(pattern: string)` | `seq[(string, string)]` | `CONFIG GET` | Configuration parameters matching `pattern`. |
| `configSet(parameter, value: string)` | `void` | `CONFIG SET` | Sets a configuration parameter at runtime. |
| `configResetStat()` | `void` | `CONFIG RESETSTAT` | Resets the `INFO` statistics. |
| `replicaof(host, port: string)` | `void` | `REPLICAOF` | Makes this server a replica of `host:port` (`"NO", "ONE"` stops). |
| `waitReplicas(replicas, timeoutMs: int)` | `int` | `WAIT` | Blocks until `replicas` acknowledged the writes so far; returns how many did. |
| `memoryUsage(key: string)` | `Option[int]` | `MEMORY USAGE` | Bytes used by `key`, `none` if missing. |

## Keys

| signature | returns | sends | description |
|---|---|---|---|
| `del(keys: varargs[string])` | `int` | `DEL` | Deletes keys; returns how many existed. |
| `unlink(keys: varargs[string])` | `int` | `UNLINK` | Like `del`, but frees the memory in the background. |
| `exists(key: string)` | `bool` | `EXISTS` | Whether `key` exists. |
| `countExisting(keys: varargs[string])` | `int` | `EXISTS` | How many of `keys` exist (a key given twice counts twice). |
| `touch(keys: varargs[string])` | `int` | `TOUCH` | Updates the last-access time of keys; returns how many exist. |
| `expire(key: string, seconds: int, nx, xx, gt, lt: bool = false)` | `bool` | `EXPIRE` | Sets a time to live in seconds. `true` if it was set. |
| `pexpire(key: string, milliseconds: int, nx, xx, gt, lt: bool = false)` | `bool` | `PEXPIRE` | Sets a time to live in milliseconds. |
| `expireAt(key: string, unixSeconds: int, nx, xx, gt, lt: bool = false)` | `bool` | `EXPIREAT` | Expires `key` at a unix time (seconds). |
| `pexpireAt(key: string, unixMillis: int, nx, xx, gt, lt: bool = false)` | `bool` | `PEXPIREAT` | Expires `key` at a unix time (milliseconds). |
| `expireTime(key: string)` | `int` | `EXPIRETIME` | Unix time (seconds) `key` expires at; -1 no expiry, -2 missing. |
| `pexpireTime(key: string)` | `int` | `PEXPIRETIME` | Unix time (milliseconds) `key` expires at; -1 no expiry, -2 missing. |
| `ttl(key: string)` | `int` | `TTL` | Seconds to live; -1 no expiry, -2 missing. |
| `pttl(key: string)` | `int` | `PTTL` | Milliseconds to live; -1 no expiry, -2 missing. |
| `persist(key: string)` | `bool` | `PERSIST` | Removes the expiry. `true` if there was one. |
| `keyType(key: string)` | `string` | `TYPE` | `string`, `list`, `set`, `zset`, `hash`, `stream` or `none`. |
| `keys(pattern: string)` | `seq[string]` | `KEYS` | Every key matching a glob `pattern`. O(N): prefer `scanAll` in production. |
| `randomKey()` | `Option[string]` | `RANDOMKEY` | A random key, `none` for an empty database. |
| `rename(key, newKey: string)` | `void` | `RENAME` | Renames `key`, overwriting `newKey`. |
| `renameNX(key, newKey: string)` | `bool` | `RENAMENX` | Renames `key` only if `newKey` does not exist. |
| `move(key: string, db: int)` | `bool` | `MOVE` | Moves `key` to database `db`. |
| `copy(source, destination: string, db: int = noArg, replace: bool = false)` | `bool` | `COPY` | Copies a key. |
| `dump(key: string)` | `Option[string]` | `DUMP` | Serialized form of `key` (binary string). |
| `restore(key: string, ttlMs: int, serialized: string, replace, absttl: bool = false)` | `void` | `RESTORE` | Recreates a key from `dump` output. |
| `objectEncoding(key: string)` | `Option[string]` | `OBJECT ENCODING` | Internal encoding of the value. |
| `objectIdletime(key: string)` | `Option[int]` | `OBJECT IDLETIME` | Seconds since last access. |
| `objectFreq(key: string)` | `Option[int]` | `OBJECT FREQ` | Access frequency (LFU policies). |

## Strings

| signature | returns | sends | description |
|---|---|---|---|
| `get(key: string)` | `Option[string]` | `GET` | The value of `key`, `none` if it does not exist. |
| `set(key, value: string, ex, px, exat, pxat: int = noArg, keepttl, nx, xx: bool = false)` | `bool` | `SET` | Sets `key`. `ex`/`px` give a time to live (seconds/milliseconds), `exat`/`pxat` an absolute expiry. With `nx` (only if missing) or `xx` (only if present) the result is `false` when the condition failed. |
| `setGet(key, value: string, ex, px, exat, pxat: int = noArg, keepttl, nx, xx: bool = false)` | `Option[string]` | `SET` | `SET ... GET`: sets `key` and returns its previous value. |
| `setNX(key, value: string)` | `bool` | `SETNX` | Sets `key` only if it does not exist. |
| `setEx(key: string, seconds: int, value: string)` | `void` | `SETEX` | Sets `key` with a time to live in seconds. |
| `psetEx(key: string, milliseconds: int, value: string)` | `void` | `PSETEX` | Sets `key` with a time to live in milliseconds. |
| `getDel(key: string)` | `Option[string]` | `GETDEL` | Returns the value and deletes the key. |
| `getEx(key: string, ex, px, exat, pxat: int = noArg, persist: bool = false)` | `Option[string]` | `GETEX` | Returns the value and changes its expiry. |
| `getSet(key, value: string)` | `Option[string]` | `GETSET` | Sets the value, returns the old one (prefer `setGet`). |
| `getRange(key: string, start, stop: int)` | `string` | `GETRANGE` | Substring of the value (inclusive, negative counts from the end). |
| `setRange(key: string, offset: int, value: string)` | `int` | `SETRANGE` | Overwrites part of the value; returns the new length. |
| `append(key, value: string)` | `int` | `APPEND` | Appends to the value; returns the new length. |
| `strlen(key: string)` | `int` | `STRLEN` | Length of the value. |
| `incr(key: string)` | `int64` | `INCR` | Increments the integer value by 1; returns the new value. |
| `incrBy(key: string, increment: int64)` | `int64` | `INCRBY` | Adds `increment`; returns the new value. |
| `decr(key: string)` | `int64` | `DECR` | Decrements by 1. |
| `decrBy(key: string, decrement: int64)` | `int64` | `DECRBY` | Subtracts `decrement`. |
| `incrByFloat(key: string, increment: float)` | `float` | `INCRBYFLOAT` | Adds a floating point `increment`. |
| `mget(keys: varargs[string])` | `seq[Option[string]]` | `MGET` | Values of several keys, `none` for the missing ones. |
| `mset(pairs: openArray[(string, string)])` | `void` | `MSET` | Sets several keys at once. |
| `msetNX(pairs: openArray[(string, string)])` | `bool` | `MSETNX` | Sets several keys only if none of them exists. |
| `getBit(key: string, offset: int)` | `int` | `GETBIT` | The bit at `offset`. |
| `setBit(key: string, offset: int, value: int)` | `int` | `SETBIT` | Sets the bit at `offset`; returns the previous bit. |
| `bitCount(key: string)` | `int` | `BITCOUNT` | Number of set bits. |
| `bitCountRange(key: string, start, stop: int, bit: bool = false)` | `int` | `BITCOUNT` | Set bits in a byte range (or bit range with `bit = true`). |
| `bitPos(key: string, bit: int)` | `int` | `BITPOS` | Position of the first bit equal to `bit`. |
| `bitOp(operation, destination: string, keys: varargs[string])` | `int` | `BITOP` | `AND`, `OR`, `XOR` or `NOT` over `keys`, stored in `destination`. |

## Hashes

| signature | returns | sends | description |
|---|---|---|---|
| `hset(key, field, value: string)` | `int` | `HSET` | Sets one field; returns 1 if it is new. |
| `hsetMany(key: string, fields: openArray[(string, string)])` | `int` | `HSET` | Sets several fields; returns how many are new. |
| `hsetNX(key, field, value: string)` | `bool` | `HSETNX` | Sets a field only if it does not exist. |
| `hget(key, field: string)` | `Option[string]` | `HGET` | A field's value, `none` if missing. |
| `hgetAll(key: string)` | `seq[(string, string)]` | `HGETALL` | Every field and value, in server order. |
| `hmget(key: string, fields: varargs[string])` | `seq[Option[string]]` | `HMGET` | Several fields' values. |
| `hdel(key: string, fields: varargs[string])` | `int` | `HDEL` | Deletes fields; returns how many existed. |
| `hexists(key, field: string)` | `bool` | `HEXISTS` | Whether a field exists. |
| `hincrBy(key, field: string, increment: int64)` | `int64` | `HINCRBY` | Adds to an integer field. |
| `hincrByFloat(key, field: string, increment: float)` | `float` | `HINCRBYFLOAT` | Adds to a floating point field. |
| `hkeys(key: string)` | `seq[string]` | `HKEYS` | Field names. |
| `hvals(key: string)` | `seq[string]` | `HVALS` | Field values. |
| `hlen(key: string)` | `int` | `HLEN` | Number of fields. |
| `hstrlen(key, field: string)` | `int` | `HSTRLEN` | Length of a field's value. |
| `hrandField(key: string)` | `Option[string]` | `HRANDFIELD` | A random field name. |

## Lists

| signature | returns | sends | description |
|---|---|---|---|
| `lpush(key: string, values: varargs[string])` | `int` | `LPUSH` | Pushes at the head; returns the new length. |
| `rpush(key: string, values: varargs[string])` | `int` | `RPUSH` | Pushes at the tail; returns the new length. |
| `lpushX(key: string, values: varargs[string])` | `int` | `LPUSHX` | Like `lpush`, only if the list exists. |
| `rpushX(key: string, values: varargs[string])` | `int` | `RPUSHX` | Like `rpush`, only if the list exists. |
| `lpop(key: string)` | `Option[string]` | `LPOP` | Pops the head. |
| `rpop(key: string)` | `Option[string]` | `RPOP` | Pops the tail. |
| `lpopCount(key: string, count: int)` | `seq[string]` | `LPOP` | Pops up to `count` elements from the head. |
| `rpopCount(key: string, count: int)` | `seq[string]` | `RPOP` | Pops up to `count` elements from the tail. |
| `lrange(key: string, start, stop: int)` | `seq[string]` | `LRANGE` | Elements `start .. stop` (inclusive; `0, -1` is the whole list). |
| `llen(key: string)` | `int` | `LLEN` | Length of the list. |
| `lindex(key: string, index: int)` | `Option[string]` | `LINDEX` | Element at `index`. |
| `lset(key: string, index: int, value: string)` | `void` | `LSET` | Replaces the element at `index`. |
| `lrem(key: string, count: int, value: string)` | `int` | `LREM` | Removes occurrences of `value`; returns how many. |
| `ltrim(key: string, start, stop: int)` | `void` | `LTRIM` | Keeps only `start .. stop`. |
| `linsert(key: string, where: InsertPos, pivot, value: string)` | `int` | `LINSERT` | Inserts `value` before / after `pivot`; returns the new length, -1 if no pivot. |
| `lmove(source, destination: string, wherefrom, whereto: ListSide)` | `Option[string]` | `LMOVE` | Atomically moves an element between lists. |
| `rpopLPush(source, destination: string)` | `Option[string]` | `RPOPLPUSH` | Pops the tail of `source` and pushes it on the head of `destination`. |
| `lpos(key, element: string, rank, maxlen: int = noArg)` | `Option[int]` | `LPOS` | Index of the first matching element. |
| `blpop(keys: openArray[string], timeoutSeconds: float)` | `Option[(string, string)]` | `BLPOP` | Blocking pop from the head of the first non-empty list. Use a dedicated connection (`pool.withConn`): it occupies the connection while it waits. |
| `brpop(keys: openArray[string], timeoutSeconds: float)` | `Option[(string, string)]` | `BRPOP` | Blocking pop from the tail. See `blpop`. |
| `blmove(source, destination: string, wherefrom, whereto: ListSide, timeoutSeconds: float)` | `Option[string]` | `BLMOVE` | Blocking `lmove`. See `blpop`. |
| `brpopLPush(source, destination: string, timeoutSeconds: float)` | `Option[string]` | `BRPOPLPUSH` | Blocking `rpopLPush`. See `blpop`. |

## Sets

| signature | returns | sends | description |
|---|---|---|---|
| `sadd(key: string, members: varargs[string])` | `int` | `SADD` | Adds members; returns how many are new. |
| `srem(key: string, members: varargs[string])` | `int` | `SREM` | Removes members; returns how many existed. |
| `smembers(key: string)` | `seq[string]` | `SMEMBERS` | Every member. |
| `sismember(key, member: string)` | `bool` | `SISMEMBER` | Whether `member` is in the set. |
| `smismember(key: string, members: varargs[string])` | `seq[bool]` | `SMISMEMBER` | Membership of several members at once. |
| `scard(key: string)` | `int` | `SCARD` | Number of members. |
| `spop(key: string)` | `Option[string]` | `SPOP` | Removes and returns a random member. |
| `spopCount(key: string, count: int)` | `seq[string]` | `SPOP` | Removes and returns up to `count` random members. |
| `srandMember(key: string)` | `Option[string]` | `SRANDMEMBER` | A random member. |
| `srandMemberCount(key: string, count: int)` | `seq[string]` | `SRANDMEMBER` | `count` random members (negative: may repeat). |
| `smove(source, destination, member: string)` | `bool` | `SMOVE` | Moves a member between sets. |
| `sdiff(keys: varargs[string])` | `seq[string]` | `SDIFF` | Members of the first set not in the others. |
| `sinter(keys: varargs[string])` | `seq[string]` | `SINTER` | Members present in every set. |
| `sunion(keys: varargs[string])` | `seq[string]` | `SUNION` | Members present in any set. |
| `sdiffStore(destination: string, keys: varargs[string])` | `int` | `SDIFFSTORE` | `sdiff` stored in `destination`. |
| `sinterStore(destination: string, keys: varargs[string])` | `int` | `SINTERSTORE` | `sinter` stored in `destination`. |
| `sunionStore(destination: string, keys: varargs[string])` | `int` | `SUNIONSTORE` | `sunion` stored in `destination`. |

## Sorted sets

| signature | returns | sends | description |
|---|---|---|---|
| `zadd(key: string, members: openArray[(float, string)], nx, xx, gt, lt, ch: bool = false)` | `int` | `ZADD` | Adds `(score, member)` pairs. Returns how many were added (with `ch`: added or changed). |
| `zincrBy(key: string, increment: float, member: string)` | `float` | `ZINCRBY` | Adds to a member's score; returns the new score. |
| `zscore(key, member: string)` | `Option[float]` | `ZSCORE` | A member's score, `none` if absent. |
| `zmscore(key: string, members: varargs[string])` | `seq[Option[float]]` | `ZMSCORE` | Scores of several members. |
| `zcard(key: string)` | `int` | `ZCARD` | Number of members. |
| `zcount(key, min, max: string)` | `int` | `ZCOUNT` | Members with a score in `min .. max` (`"-inf"`, `"(5"` for exclusive). |
| `zlexCount(key, min, max: string)` | `int` | `ZLEXCOUNT` | Members in a lexicographic range. |
| `zrank(key, member: string)` | `Option[int]` | `ZRANK` | Rank by ascending score. |
| `zrevRank(key, member: string)` | `Option[int]` | `ZREVRANK` | Rank by descending score. |
| `zrange(key: string, start, stop: int)` | `seq[string]` | `ZRANGE` | Members by rank, ascending. |
| `zrangeWithScores(key: string, start, stop: int)` | `seq[(string, float)]` | `ZRANGE` | Members by rank with their scores. |
| `zrevRange(key: string, start, stop: int)` | `seq[string]` | `ZREVRANGE` | Members by rank, descending. |
| `zrevRangeWithScores(key: string, start, stop: int)` | `seq[(string, float)]` | `ZREVRANGE` | Descending members with their scores. |
| `zrangeByScore(key, min, max: string, limit: (int, int) = (noArg, 0))` | `seq[string]` | `ZRANGEBYSCORE` | Members with a score in `min .. max`. `limit` is `(offset, count)`. |
| `zrangeByScoreWithScores(key, min, max: string, limit: (int, int) = (noArg, 0))` | `seq[(string, float)]` | `ZRANGEBYSCORE` | Like `zrangeByScore`, with scores. |
| `zrevRangeByScore(key, max, min: string, limit: (int, int) = (noArg, 0))` | `seq[string]` | `ZREVRANGEBYSCORE` | Descending, by score (note the argument order: `max` first). |
| `zrangeByLex(key, min, max: string, limit: (int, int) = (noArg, 0))` | `seq[string]` | `ZRANGEBYLEX` | Members in a lexicographic range. |
| `zrem(key: string, members: varargs[string])` | `int` | `ZREM` | Removes members. |
| `zremRangeByRank(key: string, start, stop: int)` | `int` | `ZREMRANGEBYRANK` | Removes members by rank. |
| `zremRangeByScore(key, min, max: string)` | `int` | `ZREMRANGEBYSCORE` | Removes members by score. |
| `zremRangeByLex(key, min, max: string)` | `int` | `ZREMRANGEBYLEX` | Removes members by lexicographic range. |
| `zpopMin(key: string)` | `seq[(string, float)]` | `ZPOPMIN` | Removes and returns the lowest-scored member. |
| `zpopMax(key: string)` | `seq[(string, float)]` | `ZPOPMAX` | Removes and returns the highest-scored member. |
| `zpopMinCount(key: string, count: int)` | `seq[(string, float)]` | `ZPOPMIN` | Removes and returns up to `count` lowest-scored members. |
| `zpopMaxCount(key: string, count: int)` | `seq[(string, float)]` | `ZPOPMAX` | Removes and returns up to `count` highest-scored members. |
| `bzpopMin(keys: openArray[string], timeoutSeconds: float)` | `Reply` | `BZPOPMIN` | Blocking `zpopMin`: `[key, member, score]` or nil. See `blpop`. |
| `bzpopMax(keys: openArray[string], timeoutSeconds: float)` | `Reply` | `BZPOPMAX` | Blocking `zpopMax`. See `blpop`. |
| `zrandMember(key: string)` | `Option[string]` | `ZRANDMEMBER` | A random member. |

## Hyperloglog, geo

| signature | returns | sends | description |
|---|---|---|---|
| `pfadd(key: string, elements: varargs[string])` | `bool` | `PFADD` | Adds elements to a HyperLogLog; `true` if its estimate changed. |
| `pfcount(keys: varargs[string])` | `int` | `PFCOUNT` | Approximate number of distinct elements. |
| `pfmerge(destination: string, sources: varargs[string])` | `void` | `PFMERGE` | Merges HyperLogLogs. |
| `geoadd(key: string, members: openArray[(float, float, string)], nx, xx, ch: bool = false)` | `int` | `GEOADD` | Adds `(longitude, latitude, member)` entries. |
| `geodist(key, member1, member2: string, unit: string = "")` | `Option[float]` | `GEODIST` | Distance between two members (`unit`: `m`, `km`, `mi`, `ft`). |
| `geohash(key: string, members: varargs[string])` | `seq[Option[string]]` | `GEOHASH` | Geohash strings. |
| `geopos(key: string, members: varargs[string])` | `Reply` | `GEOPOS` | Positions as `[[lon, lat] \| nil, ...]`. |
| `geosearch(key: string, spec: varargs[string])` | `seq[string]` | `GEOSEARCH` | `GEOSEARCH` with its arguments given verbatim, e.g. `geosearch("k", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ASC")`. |

## Pub/sub (publisher side; see `pubsub` for subscribing)

| signature | returns | sends | description |
|---|---|---|---|
| `publish(channel, message: string)` | `int` | `PUBLISH` | Publishes a message; returns how many subscribers received it. |
| `pubsubChannels(pattern: string = "")` | `seq[string]` | `PUBSUB CHANNELS` | Active channels. |
| `pubsubNumPat()` | `int` | `PUBSUB NUMPAT` | Number of pattern subscriptions. |

## Transactions on a dedicated connection

| signature | returns | sends | description |
|---|---|---|---|
| `watch(keys: varargs[string])` | `void` | `WATCH` | Watches keys for an optimistic transaction. Needs a connection of your own (`pool.withConn`): other tasks' commands would otherwise interleave. |
| `unwatch()` | `void` | `UNWATCH` | Forgets all watched keys. |

## Connection

| signature | returns | sends | description |
|---|---|---|---|
| `auth(password: string)` | `void` | `AUTH` | Authenticates with the default user's password. |
| `authUser(username, password: string)` | `void` | `AUTH` | Authenticates as `username` (ACL). |
| `hello(protover: int, setname: string = "")` | `Reply` | `HELLO` | Switches the protocol (`2` or `3`) and returns the server's properties. Prefer `Config(protocol: 3)` so the connection starts in RESP3. |

## Cursor scans

| signature | returns | sends | description |
|---|---|---|---|
| `scan(cursor: string, match: string = "", count: int = noArg, `type`: string = "")` | `ScanPage` | `SCAN` | One step of an incremental key scan. Start with `"0"`. |
| `sscan(key, cursor: string, match: string = "", count: int = noArg)` | `ScanPage` | `SSCAN` | One step of a set scan. |
| `hscan(key, cursor: string, match: string = "", count: int = noArg)` | `ScanPage` | `HSCAN` | One step of a hash scan; `items` alternates field, value. |
| `zscan(key, cursor: string, match: string = "", count: int = noArg)` | `ZScanPage` | `ZSCAN` | One step of a sorted-set scan. |

## Sorted-set algebra

| signature | returns | sends | description |
|---|---|---|---|
| `zunionStore(destination: string, keys: openArray[string], weights: seq[float] = @[], aggregate: Aggregate = agSum)` | `int` | `ZUNIONSTORE` | Union of sorted sets stored in `destination`. |
| `zinterStore(destination: string, keys: openArray[string], weights: seq[float] = @[], aggregate: Aggregate = agSum)` | `int` | `ZINTERSTORE` | Intersection of sorted sets stored in `destination`. |
| `zdiffStore(destination: string, keys: openArray[string])` | `int` | `ZDIFFSTORE` | Difference of sorted sets stored in `destination`. |
| `zunionWithScores(keys: openArray[string], weights: seq[float] = @[], aggregate: Aggregate = agSum)` | `seq[(string, float)]` | `ZUNION` | Union of sorted sets, with scores. |
| `zinterWithScores(keys: openArray[string], weights: seq[float] = @[], aggregate: Aggregate = agSum)` | `seq[(string, float)]` | `ZINTER` | Intersection of sorted sets, with scores. |

## streams

| signature | returns | sends | description |
|---|---|---|---|
| `xadd(key, id: string, fields: openArray[(string, string)], nomkstream: bool = false, maxlen: (string, int) = ("", noArg))` | `string` | `XADD` | Appends an entry; `id` is usually `"*"`. Returns the new entry's id. `maxlen = approx(1000)` caps the stream. |
| `xlen(key: string)` | `int` | `XLEN` | Number of entries. |
| `xdel(key: string, ids: varargs[string])` | `int` | `XDEL` | Deletes entries by id. |
| `xtrim(key: string, maxlen: (string, int) = ("", noArg), minid: (string, string) = ("", ""))` | `int` | `XTRIM` | Trims a stream; `maxlen = approx(n)` or `minid = ("~", "id")`. |
| `xrange(key, start, stop: string, count: int = noArg)` | `seq[StreamEntry]` | `XRANGE` | Entries from `start` to `stop` (`"-"`, `"+"`, `"(id"` exclusive). |
| `xrevRange(key, stop, start: string, count: int = noArg)` | `seq[StreamEntry]` | `XREVRANGE` | Like `xrange`, newest first (note: `stop` comes first). |
| `xack(key, group: string, ids: varargs[string])` | `int` | `XACK` | Acknowledges entries for a consumer group. |
| `xgroupCreate(key, group, id: string, mkstream: bool = false)` | `void` | `XGROUP CREATE` | Creates a consumer group (`id` `"$"` = only new entries, `"0"` = all). |
| `xgroupDestroy(key, group: string)` | `int` | `XGROUP DESTROY` | Destroys a consumer group. |
| `xgroupCreateConsumer(key, group, consumer: string)` | `int` | `XGROUP CREATECONSUMER` | Creates a consumer in a group. |
| `xgroupDelConsumer(key, group, consumer: string)` | `int` | `XGROUP DELCONSUMER` | Deletes a consumer; returns its pending entries count. |
| `xgroupSetId(key, group, id: string)` | `void` | `XGROUP SETID` | Sets the group's last delivered id. |
| `xpending(key, group: string)` | `Reply` | `XPENDING` | Summary of pending entries: `[count, min id, max id, [[consumer, n], ...]]`. |
| `xpendingRange(key, group, start, stop: string, count: int, consumer: string = "")` | `Reply` | `XPENDING` | Detailed pending entries in an id range. |
| `xclaim(key, group, consumer: string, minIdleMs: int, ids: varargs[string])` | `seq[StreamEntry]` | `XCLAIM` | Takes ownership of pending entries idle for at least `minIdleMs`. |
| `xautoclaim(key, group, consumer: string, minIdleMs: int, start: string, count: int = noArg)` | `Reply` | `XAUTOCLAIM` | `[next cursor, [entries], [deleted ids]]`. |
| `xinfoStream(key: string)` | `Reply` | `XINFO STREAM` | Stream properties. |
| `xinfoGroups(key: string)` | `Reply` | `XINFO GROUPS` | Consumer groups of a stream. |

## scripting

| signature | returns | sends | description |
|---|---|---|---|
| `eval(script: string, keys: openArray[string], args: openArray[string])` | `Reply` | `EVAL` | Runs Lua source. Prefer `Script` + `run` for scripts you call repeatedly. |
| `evalSha(sha: string, keys: openArray[string], args: openArray[string])` | `Reply` | `EVALSHA` | Runs a script that is already cached on the server. |
| `scriptLoad(script: string)` | `string` | `SCRIPT LOAD` | Caches a script on the server; returns its SHA1. |
| `scriptExists(shas: varargs[string])` | `seq[bool]` | `SCRIPT EXISTS` | Which of the SHA1s are cached. |
| `scriptFlush()` | `void` | `SCRIPT FLUSH` | Empties the script cache. |
| `scriptKill()` | `void` | `SCRIPT KILL` | Stops the running script (if it has not written yet). |

---
210 commands, each in up to four forms.
