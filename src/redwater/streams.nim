## redwater/streams - Conn Streams with typed entries.

import stagelane
import ./resp, ./conn, ./pool, ./cluster, ./dsl, ./commands

type
  StreamEntry* = object
    ## One stream entry: its id and its field/value pairs.
    id*: string
    fields*: seq[(string, string)]
  StreamBatch* = object
    ## The entries read from one stream by `xread` / `xreadGroup`.
    stream*: string
    entries*: seq[StreamEntry]

proc `[]`*(e: StreamEntry, field: string): string =
  ## the value of `field`, or "" if the entry has no such field
  for (f, v) in e.fields:
    if f == field: return v

proc contains*(e: StreamEntry, field: string): bool =
  for (f, _) in e.fields:
    if f == field: return true

proc `$`*(e: StreamEntry): string = e.id & ": " & $e.fields

proc to*(v: Reply, _: typedesc[StreamEntry]): StreamEntry =
  if v.kind != rkList or v.elems.len != 2:
    raise newException(ProtocolError, "malformed stream entry")
  result.id = v.elems[0].to(string)
  if v.elems[1].kind != rkNil:
    result.fields = v.elems[1].toPairs(string, string)

proc toBatches*(v: Reply): seq[StreamBatch] =
  ## XREAD reply: RESP2 `[[stream, [entries]], ...]` or RESP3 `{stream: [entries]}`
  case v.kind
  of rkNil: discard
  of rkMap:
    for kv in v.entries:
      result.add StreamBatch(stream: kv[0].to(string), entries: kv[1].to(seq[StreamEntry]))
  of rkList:
    for s in v.elems:
      if s.kind != rkList or s.elems.len != 2:
        raise newException(ProtocolError, "malformed XREAD reply")
      result.add StreamBatch(stream: s.elems[0].to(string),
                             entries: s.elems[1].to(seq[StreamEntry]))
  else: raise newException(ProtocolError, "malformed XREAD reply")

proc approx*(n: int): (string, int) {.inline.} =
  ## "about `n`": efficient trimming (`MAXLEN ~ n`)
  ("~", n)
proc exact*(n: int): (string, int) {.inline.} =
  ## exactly `n` (`MAXLEN = n`)
  ("=", n)

proc xadd*(key, id: string, fields: openArray[(string, string)];
           nomkstream: bool = false;
           maxlen: (string, int) = ("", noArg)): string {.cmd: "XADD @1".} =
  ## Appends an entry; `id` is usually `"*"`. Returns the new entry's id.
  ## `maxlen = approx(1000)` caps the stream.

proc xlen*(key: string): int {.cmd: "XLEN".} =
  ## Number of entries.

proc xdel*(key: string, ids: varargs[string]): int {.cmd: "XDEL".} =
  ## Deletes entries by id.

proc xtrim*(key: string; maxlen: (string, int) = ("", noArg);
            minid: (string, string) = ("", "")): int {.cmd: "XTRIM".} =
  ## Trims a stream; `maxlen = approx(n)` or `minid = ("~", "id")`.

proc xrange*(key, start, stop: string; count: int = noArg): seq[StreamEntry] {.cmd: "XRANGE".} =
  ## Entries from `start` to `stop` (`"-"`, `"+"`, `"(id"` exclusive).

proc xrevRange*(key, stop, start: string; count: int = noArg): seq[StreamEntry] {.cmd: "XREVRANGE".} =
  ## Like `xrange`, newest first (note: `stop` comes first).

proc xack*(key, group: string, ids: varargs[string]): int {.cmd: "XACK".} =
  ## Acknowledges entries for a consumer group.

proc xgroupCreate*(key, group, id: string; mkstream: bool = false) {.cmd: "XGROUP CREATE".} =
  ## Creates a consumer group (`id` `"$"` = only new entries, `"0"` = all).

proc xgroupDestroy*(key, group: string): int {.cmd: "XGROUP DESTROY".} =
  ## Destroys a consumer group.

proc xgroupCreateConsumer*(key, group, consumer: string): int {.cmd: "XGROUP CREATECONSUMER".} =
  ## Creates a consumer in a group.

proc xgroupDelConsumer*(key, group, consumer: string): int {.cmd: "XGROUP DELCONSUMER".} =
  ## Deletes a consumer; returns its pending entries count.

proc xgroupSetId*(key, group, id: string) {.cmd: "XGROUP SETID".} =
  ## Sets the group's last delivered id.

proc xpending*(key, group: string): Reply {.cmd: "XPENDING".} =
  ## Summary of pending entries: `[count, min id, max id, [[consumer, n], ...]]`.

proc xpendingRange*(key, group, start, stop: string, count: int;
                    consumer: string = ""): Reply {.cmd: "XPENDING #consumer".} =
  ## Detailed pending entries in an id range.

proc xclaim*(key, group, consumer: string, minIdleMs: int,
             ids: varargs[string]): seq[StreamEntry] {.cmd: "XCLAIM".} =
  ## Takes ownership of pending entries idle for at least `minIdleMs`.

proc xautoclaim*(key, group, consumer: string, minIdleMs: int, start: string;
                 count: int = noArg): Reply {.cmd: "XAUTOCLAIM".} =
  ## `[next cursor, [entries], [deleted ids]]`.

proc xinfoStream*(key: string): Reply {.cmd: "XINFO STREAM".} =
  ## Stream properties.

proc xinfoGroups*(key: string): Reply {.cmd: "XINFO GROUPS".} =
  ## Consumer groups of a stream.

proc xread*(c: Conn, streams: openArray[(string, string)],
            count: int = noArg, blockMs: int = noArg): seq[StreamBatch] {.flow.} =
  ## Reads entries after the given ids: `c.xread({"events": "0"})`. Use `"$"`
  ## for "only entries added from now on". With `blockMs >= 0` it waits for
  ## data; a blocking read needs a connection of its own (`pool.withConn`).
  ## Returns nothing when the wait times out.
  ensureLive(c)
  var n = 2 + streams.len * 2
  if count != noArg: n += 2
  if blockMs != noArg: n += 2
  c.wb.addArrayHeader(n)
  c.wb.addArg "XREAD"
  if count != noArg: c.wb.addArg "COUNT"; c.wb.addArg count
  if blockMs != noArg: c.wb.addArg "BLOCK"; c.wb.addArg blockMs
  c.wb.addArg "STREAMS"
  for (k, _) in streams: c.wb.addArg k
  for (_, id) in streams: c.wb.addArg id
  let t = c.submit()
  result = toBatches(c.replyChecked(t))

proc xreadGroup*(c: Conn, group, consumer: string, streams: openArray[(string, string)],
                 count: int = noArg, blockMs: int = noArg, noack: bool = false): seq[StreamBatch] {.flow.} =
  ## Reads as `consumer` in `group`; ids are usually `">"` (never delivered).
  ## See `xread` for blocking.
  ensureLive(c)
  var n = 5 + streams.len * 2
  if count != noArg: n += 2
  if blockMs != noArg: n += 2
  if noack: n += 1
  c.wb.addArrayHeader(n)
  c.wb.addArg "XREADGROUP"; c.wb.addArg "GROUP"; c.wb.addArg group; c.wb.addArg consumer
  if count != noArg: c.wb.addArg "COUNT"; c.wb.addArg count
  if blockMs != noArg: c.wb.addArg "BLOCK"; c.wb.addArg blockMs
  if noack: c.wb.addArg "NOACK"
  c.wb.addArg "STREAMS"
  for (k, _) in streams: c.wb.addArg k
  for (_, id) in streams: c.wb.addArg id
  let t = c.submit()
  result = toBatches(c.replyChecked(t))
