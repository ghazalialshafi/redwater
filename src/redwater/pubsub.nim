## redwater/pubsub - subscribing to channels.
##
## A subscribed connection can only receive, so a `Subscriber` owns one
## connection. Publish from any other connection (`c.publish(...)`).
##
## ```nim
## let sub = newSubscriber(openFlow())
## sub.subscribe("news", "alerts")
## sub.eachMessage(m):
##   echo m.channel, ": ", m.data
## ```
##
## Reading is cancel-safe, so `withTimeout(100, sub.nextMessage())` and
## `select`-style loops are fine.

import stagelane
import ./resp, ./conn

type
  MessageKind* = enum
    mkMessage       ## a published message on a channel you subscribed to
    mkPMessage      ## a message matched by a pattern subscription
    mkSubscribe, mkUnsubscribe, mkPSubscribe, mkPUnsubscribe
    mkPong
  PubSubMessage* = object
    kind*: MessageKind
    channel*: string    ## channel (for pattern messages: the actual channel)
    pattern*: string    ## the matching pattern (`mkPMessage` only)
    data*: string       ## the payload
    count*: int         ## subscription count (control messages)
  Subscriber* = ref object
    c*: Conn

proc newSubscriber*(c: Conn): Subscriber =
  ## Turns a *dedicated* connection into a subscriber.
  Subscriber(c: c)

proc close*(s: Subscriber) = s.c.close()

proc subscribe*(s: Subscriber, channels: varargs[string]) {.flow.} =
  ## Subscribes to channels. Confirmations arrive via `nextMessage(true)`.
  var args = @["SUBSCRIBE"]
  for ch in channels: args.add ch
  s.c.sendRaw(args)

proc psubscribe*(s: Subscriber, patterns: varargs[string]) {.flow.} =
  ## Subscribes to glob patterns (`news.*`).
  var args = @["PSUBSCRIBE"]
  for p in patterns: args.add p
  s.c.sendRaw(args)

proc unsubscribe*(s: Subscriber, channels: varargs[string]) {.flow.} =
  ## Unsubscribes (from everything when no channel is given).
  var args = @["UNSUBSCRIBE"]
  for ch in channels: args.add ch
  s.c.sendRaw(args)

proc punsubscribe*(s: Subscriber, patterns: varargs[string]) {.flow.} =
  var args = @["PUNSUBSCRIBE"]
  for p in patterns: args.add p
  s.c.sendRaw(args)

proc ping*(s: Subscriber, message: string = "") {.flow.} =
  ## Sends `PING`; the `mkPong` reply arrives via `nextMessage(true)`.
  if message.len > 0: s.c.sendRaw("PING", message)
  else: s.c.sendRaw("PING")

proc parseMessage(v: Reply): PubSubMessage =
  if v.kind notin {rkList, rkPush} or v.elems.len < 1:
    raise newException(ProtocolError, "unexpected frame in subscriber mode: " & $v.kind)
  let k = v.elems[0].to(string)
  case k
  of "message":
    result = PubSubMessage(kind: mkMessage, channel: v.elems[1].to(string),
                           data: v.elems[2].to(string))
  of "pmessage":
    result = PubSubMessage(kind: mkPMessage, pattern: v.elems[1].to(string),
                           channel: v.elems[2].to(string), data: v.elems[3].to(string))
  of "subscribe", "unsubscribe", "psubscribe", "punsubscribe":
    let kind = case k
      of "subscribe": mkSubscribe
      of "unsubscribe": mkUnsubscribe
      of "psubscribe": mkPSubscribe
      else: mkPUnsubscribe
    result = PubSubMessage(kind: kind, channel: v.elems[1].to(string),
                           count: v.elems[2].to(int))
  of "pong":
    result = PubSubMessage(kind: mkPong,
                           data: (if v.elems.len > 1: v.elems[1].to(string) else: ""))
  else:
    raise newException(ProtocolError, "unknown pub/sub frame: " & k)

proc nextMessage*(s: Subscriber, control: bool = false): PubSubMessage {.flow.} =
  ## Waits for the next message. Subscription confirmations and pongs are
  ## skipped unless `control` is true.
  while true:
    let v = s.c.readFrame()
    let m = parseMessage(v)
    if control or m.kind in {mkMessage, mkPMessage}:
      return m

template eachMessage*(s: Subscriber, m: untyped, body: untyped) =
  ## Runs `body` for every message until the connection closes (then it ends
  ## quietly) or the task is cancelled.
  while true:
    var alive = true
    var m: PubSubMessage
    try:
      m = s.nextMessage()
    except ConnectionError:
      alive = false
    if not alive: break
    body
