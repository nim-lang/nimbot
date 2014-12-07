import irc, asyncdispatch, strutils, times, irclogrender, irclog, parseopt,
  future, jester, os, re

type
  AsyncIRC = PAsyncIRC
  IrcEvent = TIrcEvent
  State = ref object
    ircClient: AsyncIRC
    ircServerAddr: string
    logger: PLogger
    irclogsFilename: string

const
  ircServer = "irc.freenode.net"
  joinChans = @["#nimrod-offtopic"]
  botNickname = "NimBot"

proc getCommandArgs(state: State) =
  for kind, key, value in getOpt():
    case kind
    of cmdArgument:
      quit("Syntax: ./ircbot [--sa serverAddr] --il irclogsPath")
    of cmdLongOption, cmdShortOption:
      if value == "":
        quit("Syntax: ./ircbot [--sa serverAddr] --il irclogsPath")
      case key
      of "serverAddr", "sa":
        state.ircServerAddr = value
      of "irclogs", "il":
        state.irclogsFilename = value
      else: quit("Syntax: ./ircbot [--sa serverAddr] --il irclogsPath")
    of cmdEnd: assert false

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
  
  get re"^\/([0-9]{2})-([0-9]{2})-([0-9]{4})\.html$":
    # /@dd-@MM-@yyyy.html
    let day = request.matches[0]
    let month = request.matches[1]
    let year = request.matches[2]
    cond (day.parseInt() <= 31)
    cond (month.parseInt() <= 12)
    var logs: PLogRenderer
    let logsPath = state.irclogsFilename / "$1-$2-$3.logs" % [day, month, year]
    if existsFile(logsPath):
      logs = loadRenderer(logsPath)
      resp logs.renderHTML(request)
    else:
      let logsHtml = logsPath.changeFileExt("html")
      cond existsFile(logsHtml)
      resp readFile(logsHtml)

runForever()
