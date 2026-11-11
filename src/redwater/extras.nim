## redwater/extras - authentication, scanning, sorted-set algebra, and
## compatibility helpers.

import std/options
import stagelane
import ./resp, ./conn, ./pool, ./cluster, ./dsl, ./commands

# ---- connection --------------------------------------------------------------

proc auth*(password: string) {.cmd: "AUTH".} =
  ## Authenticates with the default user's password.

proc authUser*(username, password: string) {.cmd: "AUTH".} =
  ## Authenticates as `username` (ACL).

proc hello*(protover: int; setname: string = ""): Reply {.cmd: "HELLO #protover".} =
  ## Switches the protocol (`2` or `3`) and returns the server's properties.
  ## Prefer `Config(protocol: 3)` so the connection starts in RESP3.

proc command*(c: Conn, args: varargs[string]): Reply {.flow.} =
  ## Sends any command, e.g. `c.command("OBJECT", "HELP")`. Same as `call`.
  result = c.call(args)

# ---- cursor scans ------------------------------------------------------------

type
  ScanPage* = object
    ## One page of a `SCAN`-family iteration.
    cursor*: string          ## pass it to the next call; `"0"` means finished
    items*: seq[string]
  ZScanPage* = object
    cursor*: string
    items*: seq[(string, float)]

proc finished*(p: ScanPage | ZScanPage): bool {.inline.} = p.cursor == "0"

proc to*(v: Reply, _: typedesc[ScanPage]): ScanPage =
  if v.kind != rkList or v.elems.len != 2:
    raise newException(ProtocolError, "malformed SCAN reply")
  ScanPage(cursor: v.elems[0].to(string), items: v.elems[1].to(seq[string]))

proc to*(v: Reply, _: typedesc[ZScanPage]): ZScanPage =
  if v.kind != rkList or v.elems.len != 2:
    raise newException(ProtocolError, "malformed ZSCAN reply")
  ZScanPage(cursor: v.elems[0].to(string),
            items: v.elems[1].toPairs(string, float))

proc scan*(cursor: string; match: string = ""; count: int = noArg;
           `type`: string = ""): ScanPage {.cmd: "SCAN".} =
  ## One step of an incremental key scan. Start with `"0"`.

proc sscan*(key, cursor: string; match: string = ""; count: int = noArg): ScanPage {.cmd: "SSCAN".} =
  ## One step of a set scan.

proc hscan*(key, cursor: string; match: string = ""; count: int = noArg): ScanPage {.cmd: "HSCAN".} =
  ## One step of a hash scan; `items` alternates field, value.

proc zscan*(key, cursor: string; match: string = ""; count: int = noArg): ZScanPage {.cmd: "ZSCAN".} =
  ## One step of a sorted-set scan.

proc scanAll*(c: Conn, match: string = "*", count: int = 1000): seq[string] {.flow.} =
  ## Every key matching `match`, gathered with repeated `SCAN` steps (never
  ## blocks the server the way `KEYS` does).
  var cur = "0"
  while true:
    let page = c.scan(cur, match = match, count = count)
    result.add page.items
    cur = page.cursor
    if cur == "0": break

template scanEach*(c: Conn, pattern: string, key, body: untyped) =
  ## Runs `body` for every key matching `pattern`, one `SCAN` page at a time
  ## (no need to hold all keys in memory):
  ##
  ## ```nim
  ## c.scanEach("session:*", k):
  ##   discard c.del(k)
  ## ```
  var scanCursor = "0"
  while true:
    let scanPage = c.scan(scanCursor, match = pattern)
    for key in scanPage.items:
      body
    scanCursor = scanPage.cursor
    if scanCursor == "0": break

# ---- sorted-set algebra ------------------------------------------------------

proc zunionStore*(destination: string, keys: openArray[string];
                  weights: seq[float] = @[]; aggregate: Aggregate = agSum): int {.cmd: "ZUNIONSTORE @2 %keys".} =
  ## Union of sorted sets stored in `destination`.

proc zinterStore*(destination: string, keys: openArray[string];
                  weights: seq[float] = @[]; aggregate: Aggregate = agSum): int {.cmd: "ZINTERSTORE @2 %keys".} =
  ## Intersection of sorted sets stored in `destination`.

proc zdiffStore*(destination: string, keys: openArray[string]): int {.cmd: "ZDIFFSTORE @2 %keys".} =
  ## Difference of sorted sets stored in `destination`.

proc zunionWithScores*(keys: openArray[string];
                       weights: seq[float] = @[]; aggregate: Aggregate = agSum): seq[(string, float)] {.cmd: "ZUNION @1 %keys +WITHSCORES".} =
  ## Union of sorted sets, with scores.

proc zinterWithScores*(keys: openArray[string];
                       weights: seq[float] = @[]; aggregate: Aggregate = agSum): seq[(string, float)] {.cmd: "ZINTER @1 %keys +WITHSCORES".} =
  ## Intersection of sorted sets, with scores.

# ---- compatibility with the old client ---------------------------------------

template setk*(c: Conn, key, value: string) =
  ## `set` that ignores the result. Kept for code written against `nim-lang/redis`.
  discard c.set(key, value)

