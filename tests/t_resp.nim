## Pure protocol-engine tests: no sockets, no runtime.
import std/[options, unittest]
import ../src/redwater/resp

proc decodeAll(s: string): Reply =
  var b = initRBuf(64)
  b.feed s
  let n = b.peek()
  doAssert n == s.len, "peek said " & $n & " for " & $s.len
  b.takeValue(n)

suite "encoder":
  test "command layout":
    var b: string
    b.addArrayHeader 3
    b.addArg "SET"; b.addArg "k"; b.addArg 42
    check b == "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n42\r\n"
  test "integers, extremes, negatives":
    var b: string
    b.addArg 0; b.addArg -7; b.addArg high(int64); b.addArg low(int64)
    check b == "$1\r\n0\r\n$2\r\n-7\r\n$19\r\n9223372036854775807\r\n$20\r\n-9223372036854775808\r\n"
  test "binary-safe, empty":
    var b: string
    b.addArg "a\0\r\nb"; b.addArg ""
    check b == "$5\r\na\0\r\nb\r\n$0\r\n\r\n"
  test "floats and tuples":
    var b: string
    b.addArg 1.5; b.addArg Inf; b.addArg (3, 4)
    check b == "$3\r\n1.5\r\n$3\r\ninf\r\n$1\r\n3\r\n$1\r\n4\r\n"

suite "decoder":
  test "resp2 types":
    check decodeAll("+OK\r\n") == Reply(kind: rkStatus, str: "OK")
    check decodeAll(":-12\r\n") == -12
    check decodeAll("$5\r\nhello\r\n") == "hello"
    check decodeAll("$-1\r\n").kind == rkNil
    check decodeAll("*-1\r\n").kind == rkNil
    check decodeAll("$0\r\n\r\n") == ""
    check decodeAll("-ERR boom\r\n").kind == rkError
    let l = decodeAll("*3\r\n:1\r\n$1\r\na\r\n*1\r\n+x\r\n")
    check l.len == 3 and l[0] == 1 and l[1] == "a" and l[2][0].str == "x"
  test "resp3 types":
    check decodeAll("_\r\n").kind == rkNil
    check decodeAll("#t\r\n").flag
    check not decodeAll("#f\r\n").flag
    check decodeAll(",3.25\r\n").dbl == 3.25
    check decodeAll(",-inf\r\n").dbl == -Inf
    check decodeAll("(12345678901234567890\r\n").str == "12345678901234567890"
    check decodeAll("=7\r\ntxt:abc\r\n") == "abc"
    let m = decodeAll("%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n")
    check m.kind == rkMap and m.entries.len == 2 and m.entries[1][1] == 2
    check decodeAll("~2\r\n:1\r\n:2\r\n").kind == rkSet
    check decodeAll(">2\r\n+message\r\n+x\r\n").kind == rkPush
    # an attribute is dropped, the real reply follows it
    check decodeAll("|1\r\n+k\r\n+v\r\n:5\r\n") == 5
  test "bulk containing CRLF":
    check decodeAll("$4\r\n\r\n\r\n\r\n") == "\r\n\r\n"

suite "framing":
  const replies = [
    "+OK\r\n", ":1000\r\n", "$11\r\nhello world\r\n", "$-1\r\n",
    "*2\r\n$3\r\nfoo\r\n*2\r\n:1\r\n:2\r\n", "%1\r\n+k\r\n*0\r\n",
    "$6\r\n\r\n\r\n\r\n\r\n"]
  test "every split point of every reply is incomplete until the last byte":
    for r in replies:
      for cut in 0 ..< r.len:
        var b = initRBuf(8)
        b.feed r[0 ..< cut]
        check b.peek() == 0
        b.feed r[cut .. ^1]
        check b.peek() == r.len
  test "byte-at-a-time, many replies back to back":
    var all = ""
    for r in replies: all.add r
    var b = initRBuf(8)
    var got = 0
    for ch in all:
      b.feed $ch
      while true:
        let n = b.peek()
        if n == 0: break
        discard b.takeValue(n); inc got
    check got == replies.len
    check b.buffered == 0
  test "need hint for a big bulk":
    var b = initRBuf(16)
    b.feed "$100000\r\nabc"
    check b.peek() == 0
    check b.need == 9 + 100000 + 2       # header + data + crlf
  test "buffer slides and grows":
    var b = initRBuf(64)
    for i in 1 .. 1000:
      b.feed "$3\r\nabc\r\n"
      let n = b.peek()
      check n == 9
      check b.takeValue(n) == "abc"
    b.feed newString(0)
    check b.buffered == 0

suite "scalar fast paths":
  test "takeInt / takeBulk":
    var b = initRBuf()
    b.feed ":42\r\n$3\r\nabc\r\n$-1\r\n+OK\r\n"
    var i: int64
    check b.takeInt(b.peek(), i) and i == 42
    var s: string
    check b.takeBulk(b.peek(), s) == bkString and s == "abc"
    check b.takeBulk(b.peek(), s) == bkNil
    check b.takeBulk(b.peek(), s) == bkOther   # status is not a bulk
    check not b.takeInt(b.peek(), i)
    check b.takeValue(b.peek()) == Reply(kind: rkStatus, str: "OK")

suite "malformed input":
  proc bad(s: string) =
    var b = initRBuf()
    b.feed s
    expect ProtocolError: discard b.peek()
  test "rejects":
    bad "?x\r\n"
    bad ":abc\r\n"
    bad "$3\r\nabcXY"
    bad "$-5\r\n"
    bad "*99999999999\r\n"
    bad "+a\rb\r\n"
    bad ":99999999999999999999\r\n"
    var deep = ""
    for _ in 0 .. 100: deep.add "*1\r\n"
    bad deep

suite "conversion":
  test "to[T]":
    let v = decodeAll("*3\r\n$1\r\na\r\n$-1\r\n$1\r\nc\r\n")
    check v.to(seq[Option[string]]) == @[some("a"), none(string), some("c")]
    check decodeAll(":1\r\n").to(bool)
    check decodeAll("$3\r\n1.5\r\n").to(float) == 1.5
    check decodeAll("*4\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n").toPairs(string, int) ==
      @[("a", 1), ("b", 2)]
    expect ServerError: discard decodeAll("-WRONGTYPE nope\r\n").to(string)
    check newServerError("WRONGTYPE nope").code == "WRONGTYPE"
