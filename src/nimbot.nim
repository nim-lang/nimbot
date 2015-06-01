import irc, asyncdispatch, strutils, times, irclogrender, irclog, parseopt,
  future, jester, os, re, httpclient, json, base64

type
  AsyncIRC = PAsyncIRC
  IrcEvent = TIrcEvent
  State = ref object
    ircClient: AsyncIRC
    ircServerAddr: string
    logger: PLogger
    irclogsFilename: string
    packagesJson: string # Nimble packages.json

const
  ircServer = "irc.freenode.net"
  joinChans = @["#nim"]
  botNickname = "NimBot"

proc getCommandArgs(state: State) =
  for kind, key, value in getOpt():
    case kind
    of cmdArgument:
      quit("Syntax: ./ircbot [--sa:serverAddr] --il:irclogsPath")
    of cmdLongOption, cmdShortOption:
      if value == "":
        quit("Syntax: ./ircbot [--sa:serverAddr] --il:irclogsPath")
      case key
      of "serverAddr", "sa":
        state.ircServerAddr = value
      of "irclogs", "il":
        state.irclogsFilename = value
      else: quit("Syntax: ./ircbot [--sa:serverAddr] --il:irclogsPath")
    of cmdEnd: assert false

proc refreshPackagesJson(state: State) {.async.} =
  var client = newAsyncHttpClient()
  let resp = await client.get("https://raw.githubusercontent.com/nimrod-code/" &
    "packages/master/packages.json")
  if resp.status.startsWith("200"):
    try:
      var test = parseJson(resp.body)
      state.packagesJson = base64.encode(resp.body)
    except:
      echo("Got incorrect packages.json, not saving.")
      echo(getCurrentExceptionMsg())
      if state.packagesJson == nil: raise
  else:
    echo("Could not retrieve packages.json.")

proc refreshLoop(state: State) {.async.} =
  while true:
    await refreshPackagesJson(state)
    await sleepAsync(6 * 60 * 60 * 1000) # 6 hours.

proc onIrcEvent(client: PAsyncIrc, event: TIrcEvent, state: State) {.async.} =
  case event.typ
  of EvConnected:
    nil
  of EvDisconnected, EvTimeout:
    await client.reconnect()
  of EvMsg:
    state.logger.log(event)
    if event.cmd == MPrivMsg:
      var msg = event.params[event.params.high]
      proc pmOrig(msg: string): Future[void] =
        client.privmsg(event.origin, msg)
      if msg == "!lag":
        if state.ircClient.getLag != -1.0:
          var lag = state.ircClient.getLag
          lag = lag * 1000.0
          await pmOrig($int(lag) & "ms between me and the server.")
        else:
          await pmOrig("Unknown.")
      if msg == "!ping":
        await pmOrig("pong")
    echo("< ", event.raw)

proc open(): State =
  var res: State
  new(res)
  getCommandArgs(res)

  if res.irclogsFilename.isNil:
    quit("No IRC logs filename specified.")

  res.logger = newLogger(res.irclogsFilename)

  res.ircClient = newAsyncIrc(ircServer, nick=botNickname,
       joinChans = joinChans,
       callback = (client: AsyncIRC, event: IrcEvent) =>
                     (onIrcEvent(client, event, res)))
  return res

var state = open()
asyncCheck state.ircClient.run()

var settings = newSettings(port = Port(5001))
routes:
  get "/?":
    let curTime = getTime().getGMTime()
    let path = state.irclogsFilename / curTime.format("dd'-'MM'-'yyyy'.logs'")
    var logs = loadRenderer(path)
    resp logs.renderHTML(request)
  
  get re"^\/([0-9]{2})-([0-9]{2})-([0-9]{4})\.(.+)$":
    # /@dd-@MM-@yyyy.html
    let day = request.matches[0]
    let month = request.matches[1]
    let year = request.matches[2]
    let format = request.matches[3]
    cond (day.parseInt() <= 31)
    cond (month.parseInt() <= 12)
    var logs: PLogRenderer
    let logsPath = state.irclogsFilename / "$1-$2-$3.logs" % [day, month, year]
    # TODO: Async file read.
    case format
    of "html":
      if existsFile(logsPath):
        logs = loadRenderer(logsPath)
        resp logs.renderHTML(request)
      else:
        let logsHtml = logsPath.changeFileExt("html")
        cond existsFile(logsHtml)
        resp readFile(logsHtml)
    of "logs":
      resp readFile(logsPath)
    else:
      halt()

  get "/packages/?":
    var jsonDoc = %{"content": %state.packagesJson}
    cond (jsonDoc != nil)
    var text = $jsonDoc
    if @"callback" != "":
      text = @"callback" & "(" & text & ")"

    resp text, "text/javascript"

asyncCheck refreshLoop(state)

runForever()
