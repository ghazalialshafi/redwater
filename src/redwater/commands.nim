## redwater/commands - the typed command set.
##
## Every command below is declared once with `{.cmd.}` (see `dsl`) and exists in
## three forms: on a `Redis` connection (a `{.flow.}` proc that waits for the
## reply), on a `Batch` (queues it), and on a `Pool`.
##
## Return types: a missing key / nil reply is `Option[string]` (`none`) where it
## can happen, a count is `int`, a yes/no is `bool`, and a list is `seq[...]`.
## Server error replies raise `ServerError` (check `.code`, e.g. `WRONGTYPE`).

import std/options
import stagelane
import ./resp, ./conn, ./pool, ./cluster, ./dsl
export dsl.noArg

type
  ListSide* = enum
    ## end of a list, for `lmove`
    lsLeft = "LEFT", lsRight = "RIGHT"
  InsertPos* = enum
    ## for `linsert`
    ipBefore = "BEFORE", ipAfter = "AFTER"
  Aggregate* = enum
    ## how `zunionstore` / `zinterstore` combine scores
    agSum = "SUM", agMin = "MIN", agMax = "MAX"

# ============================================================================
# connection & server
# ============================================================================

proc asking*() {.cmd: "ASKING".} =
  ## Cluster redirection helper (sent for you after an `ASK` reply).

proc ping*(): string {.cmd: "PING".} =
  ## Returns `PONG`.

proc ping*(message: string): string {.cmd: "ECHO".} =
  ## Returns `message` (round-trips it through the server).

proc useDb*(index: int) {.cmd: "SELECT".} =
  ## Selects database `index` for this connection.

proc quit*() {.cmd: "QUIT".} =
  ## Asks the server to close the connection.

proc clientSetName*(name: string) {.cmd: "CLIENT SETNAME".} =
  ## Names this connection (visible in `CLIENT LIST`).

proc clientGetName*(): Option[string] {.cmd: "CLIENT GETNAME".} =
  ## The name set with `clientSetName`, if any.

proc clientId*(): int {.cmd: "CLIENT ID".} =
  ## This connection's id.

proc clientList*(): string {.cmd: "CLIENT LIST".} =
  ## Text describing every client connection.

proc clientKill*(addrPort: string): bool {.cmd: "CLIENT KILL".} =
  ## Closes the client at `ip:port`.

proc reset*() {.cmd: "RESET".} =
  ## Resets the connection state (database, name, subscriptions, ...).

proc info*(section: string = ""): string {.cmd: "INFO #section".} =
  ## Server information; `section` is sent as an argument when given.

proc dbsize*(): int {.cmd: "DBSIZE".} =
  ## Number of keys in the current database.

proc flushdb*(async: bool = false) {.cmd: "FLUSHDB".} =
  ## Removes every key of the current database.

proc flushall*(async: bool = false) {.cmd: "FLUSHALL".} =
  ## Removes every key of every database.

proc lastsave*(): int {.cmd: "LASTSAVE".} =
  ## Unix time of the last successful save.

proc save*() {.cmd: "SAVE".} =
  ## Synchronous save (blocks the server).

proc bgsave*(): string {.cmd: "BGSAVE".} =
  ## Starts a background save.

proc bgrewriteaof*(): string {.cmd: "BGREWRITEAOF".} =
  ## Starts an append-only-file rewrite.

proc time*(): seq[string] {.cmd: "TIME".} =
  ## `[unix seconds, microseconds]`.

proc configGet*(pattern: string): seq[(string, string)] {.cmd: "CONFIG GET".} =
  ## Configuration parameters matching `pattern`.

proc configSet*(parameter, value: string) {.cmd: "CONFIG SET".} =
  ## Sets a configuration parameter at runtime.

proc configResetStat*() {.cmd: "CONFIG RESETSTAT".} =
  ## Resets the `INFO` statistics.

proc replicaof*(host, port: string) {.cmd: "REPLICAOF".} =
  ## Makes this server a replica of `host:port` (`"NO", "ONE"` stops).

proc waitReplicas*(replicas, timeoutMs: int): int {.cmd: "WAIT".} =
  ## Blocks until `replicas` acknowledged the writes so far; returns how many did.

proc memoryUsage*(key: string): Option[int] {.cmd: "MEMORY USAGE".} =
  ## Bytes used by `key`, `none` if missing.

# ============================================================================
# keys
# ============================================================================

proc del*(keys: varargs[string]): int {.cmd: "DEL".} =
  ## Deletes keys; returns how many existed.

proc unlink*(keys: varargs[string]): int {.cmd: "UNLINK".} =
  ## Like `del`, but frees the memory in the background.

proc exists*(key: string): bool {.cmd: "EXISTS".} =
  ## Whether `key` exists.

proc countExisting*(keys: varargs[string]): int {.cmd: "EXISTS".} =
  ## How many of `keys` exist (a key given twice counts twice).

proc touch*(keys: varargs[string]): int {.cmd: "TOUCH".} =
  ## Updates the last-access time of keys; returns how many exist.

proc expire*(key: string, seconds: int; nx, xx, gt, lt: bool = false): bool {.cmd: "EXPIRE".} =
  ## Sets a time to live in seconds. `true` if it was set.

proc pexpire*(key: string, milliseconds: int; nx, xx, gt, lt: bool = false): bool {.cmd: "PEXPIRE".} =
  ## Sets a time to live in milliseconds.

proc expireAt*(key: string, unixSeconds: int; nx, xx, gt, lt: bool = false): bool {.cmd: "EXPIREAT".} =
  ## Expires `key` at a unix time (seconds).

proc pexpireAt*(key: string, unixMillis: int; nx, xx, gt, lt: bool = false): bool {.cmd: "PEXPIREAT".} =
  ## Expires `key` at a unix time (milliseconds).

proc expireTime*(key: string): int {.cmd: "EXPIRETIME".} =
  ## Unix time (seconds) `key` expires at; -1 no expiry, -2 missing.

proc pexpireTime*(key: string): int {.cmd: "PEXPIRETIME".} =
  ## Unix time (milliseconds) `key` expires at; -1 no expiry, -2 missing.

proc ttl*(key: string): int {.cmd: "TTL".} =
  ## Seconds to live; -1 no expiry, -2 missing.

proc pttl*(key: string): int {.cmd: "PTTL".} =
  ## Milliseconds to live; -1 no expiry, -2 missing.

proc persist*(key: string): bool {.cmd: "PERSIST".} =
  ## Removes the expiry. `true` if there was one.

proc keyType*(key: string): string {.cmd: "TYPE".} =
  ## `string`, `list`, `set`, `zset`, `hash`, `stream` or `none`.

proc keys*(pattern: string): seq[string] {.cmd: "KEYS".} =
  ## Every key matching a glob `pattern`. O(N): prefer `scanAll` in production.

proc randomKey*(): Option[string] {.cmd: "RANDOMKEY".} =
  ## A random key, `none` for an empty database.

proc rename*(key, newKey: string) {.cmd: "RENAME".} =
  ## Renames `key`, overwriting `newKey`.

proc renameNX*(key, newKey: string): bool {.cmd: "RENAMENX".} =
  ## Renames `key` only if `newKey` does not exist.

proc move*(key: string, db: int): bool {.cmd: "MOVE".} =
  ## Moves `key` to database `db`.

proc copy*(source, destination: string; db: int = noArg; replace: bool = false): bool {.cmd: "COPY".} =
  ## Copies a key.

proc dump*(key: string): Option[string] {.cmd: "DUMP".} =
  ## Serialized form of `key` (binary string).

proc restore*(key: string, ttlMs: int, serialized: string; replace, absttl: bool = false) {.cmd: "RESTORE @3".} =
  ## Recreates a key from `dump` output.

proc objectEncoding*(key: string): Option[string] {.cmd: "OBJECT ENCODING".} =
  ## Internal encoding of the value.

proc objectIdletime*(key: string): Option[int] {.cmd: "OBJECT IDLETIME".} =
  ## Seconds since last access.

proc objectFreq*(key: string): Option[int] {.cmd: "OBJECT FREQ".} =
  ## Access frequency (LFU policies).

# ============================================================================
# strings
# ============================================================================

proc get*(key: string): Option[string] {.cmd: "GET".} =
  ## The value of `key`, `none` if it does not exist.

proc set*(key, value: string; ex, px, exat, pxat: int = noArg;
          keepttl, nx, xx: bool = false): bool {.cmd: "SET".} =
  ## Sets `key`. `ex`/`px` give a time to live (seconds/milliseconds),
  ## `exat`/`pxat` an absolute expiry. With `nx` (only if missing) or `xx` (only
  ## if present) the result is `false` when the condition failed.

proc setGet*(key, value: string; ex, px, exat, pxat: int = noArg;
             keepttl, nx, xx: bool = false): Option[string] {.cmd: "SET @2 +GET".} =
  ## `SET ... GET`: sets `key` and returns its previous value.

proc setNX*(key, value: string): bool {.cmd: "SETNX".} =
  ## Sets `key` only if it does not exist.

proc setEx*(key: string, seconds: int, value: string) {.cmd: "SETEX".} =
  ## Sets `key` with a time to live in seconds.

proc psetEx*(key: string, milliseconds: int, value: string) {.cmd: "PSETEX".} =
  ## Sets `key` with a time to live in milliseconds.

proc getDel*(key: string): Option[string] {.cmd: "GETDEL".} =
  ## Returns the value and deletes the key.

proc getEx*(key: string; ex, px, exat, pxat: int = noArg; persist: bool = false): Option[string] {.cmd: "GETEX".} =
  ## Returns the value and changes its expiry.

proc getSet*(key, value: string): Option[string] {.cmd: "GETSET".} =
  ## Sets the value, returns the old one (prefer `setGet`).

proc getRange*(key: string, start, stop: int): string {.cmd: "GETRANGE".} =
  ## Substring of the value (inclusive, negative counts from the end).

proc setRange*(key: string, offset: int, value: string): int {.cmd: "SETRANGE".} =
  ## Overwrites part of the value; returns the new length.

proc append*(key, value: string): int {.cmd: "APPEND".} =
  ## Appends to the value; returns the new length.

proc strlen*(key: string): int {.cmd: "STRLEN".} =
  ## Length of the value.

proc incr*(key: string): int64 {.cmd: "INCR".} =
  ## Increments the integer value by 1; returns the new value.

proc incrBy*(key: string, increment: int64): int64 {.cmd: "INCRBY".} =
  ## Adds `increment`; returns the new value.

proc decr*(key: string): int64 {.cmd: "DECR".} =
  ## Decrements by 1.

proc decrBy*(key: string, decrement: int64): int64 {.cmd: "DECRBY".} =
  ## Subtracts `decrement`.

proc incrByFloat*(key: string, increment: float): float {.cmd: "INCRBYFLOAT".} =
  ## Adds a floating point `increment`.

proc mget*(keys: varargs[string]): seq[Option[string]] {.cmd: "MGET".} =
  ## Values of several keys, `none` for the missing ones.

proc mset*(pairs: openArray[(string, string)]) {.cmd: "MSET".} =
  ## Sets several keys at once.

proc msetNX*(pairs: openArray[(string, string)]): bool {.cmd: "MSETNX".} =
  ## Sets several keys only if none of them exists.

proc getBit*(key: string, offset: int): int {.cmd: "GETBIT".} =
  ## The bit at `offset`.

proc setBit*(key: string, offset: int, value: int): int {.cmd: "SETBIT".} =
  ## Sets the bit at `offset`; returns the previous bit.

proc bitCount*(key: string): int {.cmd: "BITCOUNT".} =
  ## Number of set bits.

proc bitCountRange*(key: string, start, stop: int; bit: bool = false): int {.cmd: "BITCOUNT".} =
  ## Set bits in a byte range (or bit range with `bit = true`).

proc bitPos*(key: string, bit: int): int {.cmd: "BITPOS".} =
  ## Position of the first bit equal to `bit`.

proc bitOp*(operation, destination: string, keys: varargs[string]): int {.cmd: "BITOP $destination".} =
  ## `AND`, `OR`, `XOR` or `NOT` over `keys`, stored in `destination`.

# ============================================================================
# hashes
# ============================================================================

proc hset*(key, field, value: string): int {.cmd: "HSET".} =
  ## Sets one field; returns 1 if it is new.

proc hsetMany*(key: string, fields: openArray[(string, string)]): int {.cmd: "HSET".} =
  ## Sets several fields; returns how many are new.

proc hsetNX*(key, field, value: string): bool {.cmd: "HSETNX".} =
  ## Sets a field only if it does not exist.

proc hget*(key, field: string): Option[string] {.cmd: "HGET".} =
  ## A field's value, `none` if missing.

proc hgetAll*(key: string): seq[(string, string)] {.cmd: "HGETALL".} =
  ## Every field and value, in server order.

proc hmget*(key: string, fields: varargs[string]): seq[Option[string]] {.cmd: "HMGET".} =
  ## Several fields' values.

proc hdel*(key: string, fields: varargs[string]): int {.cmd: "HDEL".} =
  ## Deletes fields; returns how many existed.

proc hexists*(key, field: string): bool {.cmd: "HEXISTS".} =
  ## Whether a field exists.

proc hincrBy*(key, field: string, increment: int64): int64 {.cmd: "HINCRBY".} =
  ## Adds to an integer field.

proc hincrByFloat*(key, field: string, increment: float): float {.cmd: "HINCRBYFLOAT".} =
  ## Adds to a floating point field.

proc hkeys*(key: string): seq[string] {.cmd: "HKEYS".} =
  ## Field names.

proc hvals*(key: string): seq[string] {.cmd: "HVALS".} =
  ## Field values.

proc hlen*(key: string): int {.cmd: "HLEN".} =
  ## Number of fields.

proc hstrlen*(key, field: string): int {.cmd: "HSTRLEN".} =
  ## Length of a field's value.

proc hrandField*(key: string): Option[string] {.cmd: "HRANDFIELD".} =
  ## A random field name.

# ============================================================================
# lists
# ============================================================================

proc lpush*(key: string, values: varargs[string]): int {.cmd: "LPUSH".} =
  ## Pushes at the head; returns the new length.

proc rpush*(key: string, values: varargs[string]): int {.cmd: "RPUSH".} =
  ## Pushes at the tail; returns the new length.

proc lpushX*(key: string, values: varargs[string]): int {.cmd: "LPUSHX".} =
  ## Like `lpush`, only if the list exists.

proc rpushX*(key: string, values: varargs[string]): int {.cmd: "RPUSHX".} =
  ## Like `rpush`, only if the list exists.

proc lpop*(key: string): Option[string] {.cmd: "LPOP".} =
  ## Pops the head.

proc rpop*(key: string): Option[string] {.cmd: "RPOP".} =
  ## Pops the tail.

proc lpopCount*(key: string, count: int): seq[string] {.cmd: "LPOP".} =
  ## Pops up to `count` elements from the head.

proc rpopCount*(key: string, count: int): seq[string] {.cmd: "RPOP".} =
  ## Pops up to `count` elements from the tail.

proc lrange*(key: string, start, stop: int): seq[string] {.cmd: "LRANGE".} =
  ## Elements `start .. stop` (inclusive; `0, -1` is the whole list).

proc llen*(key: string): int {.cmd: "LLEN".} =
  ## Length of the list.

proc lindex*(key: string, index: int): Option[string] {.cmd: "LINDEX".} =
  ## Element at `index`.

proc lset*(key: string, index: int, value: string) {.cmd: "LSET".} =
  ## Replaces the element at `index`.

proc lrem*(key: string, count: int, value: string): int {.cmd: "LREM".} =
  ## Removes occurrences of `value`; returns how many.

proc ltrim*(key: string, start, stop: int) {.cmd: "LTRIM".} =
  ## Keeps only `start .. stop`.

proc linsert*(key: string, where: InsertPos, pivot, value: string): int {.cmd: "LINSERT".} =
  ## Inserts `value` before / after `pivot`; returns the new length, -1 if no pivot.

proc lmove*(source, destination: string, wherefrom, whereto: ListSide): Option[string] {.cmd: "LMOVE".} =
  ## Atomically moves an element between lists.

proc rpopLPush*(source, destination: string): Option[string] {.cmd: "RPOPLPUSH".} =
  ## Pops the tail of `source` and pushes it on the head of `destination`.

proc lpos*(key, element: string; rank, maxlen: int = noArg): Option[int] {.cmd: "LPOS".} =
  ## Index of the first matching element.

proc blpop*(keys: openArray[string], timeoutSeconds: float): Option[(string, string)] {.cmd: "BLPOP".} =
  ## Blocking pop from the head of the first non-empty list. Use a dedicated
  ## connection (`pool.withConn`): it occupies the connection while it waits.

proc brpop*(keys: openArray[string], timeoutSeconds: float): Option[(string, string)] {.cmd: "BRPOP".} =
  ## Blocking pop from the tail. See `blpop`.

proc blmove*(source, destination: string, wherefrom, whereto: ListSide,
             timeoutSeconds: float): Option[string] {.cmd: "BLMOVE".} =
  ## Blocking `lmove`. See `blpop`.

proc brpopLPush*(source, destination: string, timeoutSeconds: float): Option[string] {.cmd: "BRPOPLPUSH".} =
  ## Blocking `rpopLPush`. See `blpop`.

# ============================================================================
# sets
# ============================================================================

proc sadd*(key: string, members: varargs[string]): int {.cmd: "SADD".} =
  ## Adds members; returns how many are new.

proc srem*(key: string, members: varargs[string]): int {.cmd: "SREM".} =
  ## Removes members; returns how many existed.

proc smembers*(key: string): seq[string] {.cmd: "SMEMBERS".} =
  ## Every member.

proc sismember*(key, member: string): bool {.cmd: "SISMEMBER".} =
  ## Whether `member` is in the set.

proc smismember*(key: string, members: varargs[string]): seq[bool] {.cmd: "SMISMEMBER".} =
  ## Membership of several members at once.

proc scard*(key: string): int {.cmd: "SCARD".} =
  ## Number of members.

proc spop*(key: string): Option[string] {.cmd: "SPOP".} =
  ## Removes and returns a random member.

proc spopCount*(key: string, count: int): seq[string] {.cmd: "SPOP".} =
  ## Removes and returns up to `count` random members.

proc srandMember*(key: string): Option[string] {.cmd: "SRANDMEMBER".} =
  ## A random member.

proc srandMemberCount*(key: string, count: int): seq[string] {.cmd: "SRANDMEMBER".} =
  ## `count` random members (negative: may repeat).

proc smove*(source, destination, member: string): bool {.cmd: "SMOVE".} =
  ## Moves a member between sets.

proc sdiff*(keys: varargs[string]): seq[string] {.cmd: "SDIFF".} =
  ## Members of the first set not in the others.

proc sinter*(keys: varargs[string]): seq[string] {.cmd: "SINTER".} =
  ## Members present in every set.

proc sunion*(keys: varargs[string]): seq[string] {.cmd: "SUNION".} =
  ## Members present in any set.

proc sdiffStore*(destination: string, keys: varargs[string]): int {.cmd: "SDIFFSTORE".} =
  ## `sdiff` stored in `destination`.

proc sinterStore*(destination: string, keys: varargs[string]): int {.cmd: "SINTERSTORE".} =
  ## `sinter` stored in `destination`.

proc sunionStore*(destination: string, keys: varargs[string]): int {.cmd: "SUNIONSTORE".} =
  ## `sunion` stored in `destination`.

# ============================================================================
# sorted sets
# ============================================================================

proc zadd*(key: string, members: openArray[(float, string)];
           nx, xx, gt, lt, ch: bool = false): int {.cmd: "ZADD @1".} =
  ## Adds `(score, member)` pairs. Returns how many were added (with `ch`: added
  ## or changed).

proc zincrBy*(key: string, increment: float, member: string): float {.cmd: "ZINCRBY".} =
  ## Adds to a member's score; returns the new score.

proc zscore*(key, member: string): Option[float] {.cmd: "ZSCORE".} =
  ## A member's score, `none` if absent.

proc zmscore*(key: string, members: varargs[string]): seq[Option[float]] {.cmd: "ZMSCORE".} =
  ## Scores of several members.

proc zcard*(key: string): int {.cmd: "ZCARD".} =
  ## Number of members.

proc zcount*(key, min, max: string): int {.cmd: "ZCOUNT".} =
  ## Members with a score in `min .. max` (`"-inf"`, `"(5"` for exclusive).

proc zlexCount*(key, min, max: string): int {.cmd: "ZLEXCOUNT".} =
  ## Members in a lexicographic range.

proc zrank*(key, member: string): Option[int] {.cmd: "ZRANK".} =
  ## Rank by ascending score.

proc zrevRank*(key, member: string): Option[int] {.cmd: "ZREVRANK".} =
  ## Rank by descending score.

proc zrange*(key: string, start, stop: int): seq[string] {.cmd: "ZRANGE".} =
  ## Members by rank, ascending.

proc zrangeWithScores*(key: string, start, stop: int): seq[(string, float)] {.cmd: "ZRANGE +WITHSCORES".} =
  ## Members by rank with their scores.

proc zrevRange*(key: string, start, stop: int): seq[string] {.cmd: "ZREVRANGE".} =
  ## Members by rank, descending.

proc zrevRangeWithScores*(key: string, start, stop: int): seq[(string, float)] {.cmd: "ZREVRANGE +WITHSCORES".} =
  ## Descending members with their scores.

proc zrangeByScore*(key, min, max: string; limit: (int, int) = (noArg, 0)): seq[string] {.cmd: "ZRANGEBYSCORE".} =
  ## Members with a score in `min .. max`. `limit` is `(offset, count)`.

proc zrangeByScoreWithScores*(key, min, max: string; limit: (int, int) = (noArg, 0)): seq[(string, float)] {.cmd: "ZRANGEBYSCORE +WITHSCORES".} =
  ## Like `zrangeByScore`, with scores.

proc zrevRangeByScore*(key, max, min: string; limit: (int, int) = (noArg, 0)): seq[string] {.cmd: "ZREVRANGEBYSCORE".} =
  ## Descending, by score (note the argument order: `max` first).

proc zrangeByLex*(key, min, max: string; limit: (int, int) = (noArg, 0)): seq[string] {.cmd: "ZRANGEBYLEX".} =
  ## Members in a lexicographic range.

proc zrem*(key: string, members: varargs[string]): int {.cmd: "ZREM".} =
  ## Removes members.

proc zremRangeByRank*(key: string, start, stop: int): int {.cmd: "ZREMRANGEBYRANK".} =
  ## Removes members by rank.

proc zremRangeByScore*(key, min, max: string): int {.cmd: "ZREMRANGEBYSCORE".} =
  ## Removes members by score.

proc zremRangeByLex*(key, min, max: string): int {.cmd: "ZREMRANGEBYLEX".} =
  ## Removes members by lexicographic range.

proc zpopMin*(key: string): seq[(string, float)] {.cmd: "ZPOPMIN".} =
  ## Removes and returns the lowest-scored member.

proc zpopMax*(key: string): seq[(string, float)] {.cmd: "ZPOPMAX".} =
  ## Removes and returns the highest-scored member.

proc zpopMinCount*(key: string, count: int): seq[(string, float)] {.cmd: "ZPOPMIN".} =
  ## Removes and returns up to `count` lowest-scored members.

proc zpopMaxCount*(key: string, count: int): seq[(string, float)] {.cmd: "ZPOPMAX".} =
  ## Removes and returns up to `count` highest-scored members.

proc bzpopMin*(keys: openArray[string], timeoutSeconds: float): Reply {.cmd: "BZPOPMIN".} =
  ## Blocking `zpopMin`: `[key, member, score]` or nil. See `blpop`.

proc bzpopMax*(keys: openArray[string], timeoutSeconds: float): Reply {.cmd: "BZPOPMAX".} =
  ## Blocking `zpopMax`. See `blpop`.

proc zrandMember*(key: string): Option[string] {.cmd: "ZRANDMEMBER".} =
  ## A random member.

# ============================================================================
# hyperloglog, geo
# ============================================================================

proc pfadd*(key: string, elements: varargs[string]): bool {.cmd: "PFADD".} =
  ## Adds elements to a HyperLogLog; `true` if its estimate changed.

proc pfcount*(keys: varargs[string]): int {.cmd: "PFCOUNT".} =
  ## Approximate number of distinct elements.

proc pfmerge*(destination: string, sources: varargs[string]) {.cmd: "PFMERGE".} =
  ## Merges HyperLogLogs.

proc geoadd*(key: string, members: openArray[(float, float, string)];
             nx, xx, ch: bool = false): int {.cmd: "GEOADD @1".} =
  ## Adds `(longitude, latitude, member)` entries.

proc geodist*(key, member1, member2: string; unit: string = ""): Option[float] {.cmd: "GEODIST #unit".} =
  ## Distance between two members (`unit`: `m`, `km`, `mi`, `ft`).

proc geohash*(key: string, members: varargs[string]): seq[Option[string]] {.cmd: "GEOHASH".} =
  ## Geohash strings.

proc geopos*(key: string, members: varargs[string]): Reply {.cmd: "GEOPOS".} =
  ## Positions as `[[lon, lat] | nil, ...]`.

proc geosearch*(key: string, spec: varargs[string]): seq[string] {.cmd: "GEOSEARCH".} =
  ## `GEOSEARCH` with its arguments given verbatim, e.g.
  ## `geosearch("k", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ASC")`.

# ============================================================================
# pub/sub (publisher side; see `pubsub` for subscribing)
# ============================================================================

proc publish*(channel, message: string): int {.cmd: "PUBLISH".} =
  ## Publishes a message; returns how many subscribers received it.

proc pubsubChannels*(pattern: string = ""): seq[string] {.cmd: "PUBSUB CHANNELS #pattern".} =
  ## Active channels.

proc pubsubNumPat*(): int {.cmd: "PUBSUB NUMPAT".} =
  ## Number of pattern subscriptions.

# ============================================================================
# transactions on a dedicated connection
# ============================================================================

proc watch*(keys: varargs[string]) {.cmd: "WATCH".} =
  ## Watches keys for an optimistic transaction. Needs a connection of your own
  ## (`pool.withConn`): other tasks' commands would otherwise interleave.

proc unwatch*() {.cmd: "UNWATCH".} =
  ## Forgets all watched keys.
