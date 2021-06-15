import irc, asyncdispatch, strutils, times, parseopt,
  future, jester, os, re, json, base64, asyncnet

import httpclient except Response

import playground, irclogrender, irclog


type
  State = ref object
    ircClient: AsyncIRC
    ircServerAddr: string
    logger: PLogger
    irclogsFilename: string
    packagesJson: string # Nimble packages.json
    hubClient: AsyncSocket

const
  ircServer = "irc.freenode.net"
  joinChans = @["#nim", "#nimbuild"]
  announceChans = @["#nimbuild"]
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
      let body = await resp.body
      state.packagesJson = base64.encode(body)
    except:
      echo("Got incorrect packages.json, not saving.")
      echo(getCurrentExceptionMsg())
      if state.packagesJson.len == 0: raise
  else:
    echo("Could not retrieve packages.json.")

proc sendMessage(state: State, chan, msg: string): Future[void] =
  state.logger.log("NimBot", msg, chan)
  result = state.ircClient.privmsg(chan, msg)

proc refreshLoop(state: State) {.async.} =
  while true:
    await refreshPackagesJson(state)
    await sleepAsync(6 * 60 * 60 * 1000) # 6 hours.

proc trimGitter(msg: string): string =
  # Handle messages from FromGitter.
  result = msg
  var msg = msg.multiReplace({"\2": "", "\15": ""})
  if msg.startsWith("<"):
    let nickEnd = msg.find("> ")
    if nickEnd == -1:
      return

    result = msg[nickEnd + 2 .. ^1]

proc onIrcEvent(client: AsyncIRC, event: IrcEvent, state: State) {.async.} =
  case event.typ
  of EvConnected:
    discard
  of EvDisconnected, EvTimeout:
    await client.reconnect()
  of EvMsg:
    state.logger.log(event)
    if event.cmd == MPrivMsg:
      var msg = event.params[event.params.high].trimGitter()
      proc pmOrig(msg: string): Future[void] =
        state.sendMessage(event.origin, msg)
      if msg == "!lag":
        if state.ircClient.getLag != -1.0:
          var lag = state.ircClient.getLag
          lag = lag * 1000.0
          await pmOrig($int(lag) & "ms between me and the server.")
        else:
          await pmOrig("Unknown.")
      if msg == "!ping":
        await pmOrig("pong")
      if msg.startsWith("!eval "):
        let code = msg[6 .. ^1]
        let evalResult = await evalCode(code)
        # TODO: Gist output that is greater than ~500 chars.
        var log = evalResult.log
        log = log.multiReplace({"\n": "↵", "\r": "↵", "\l": "↵",
                                "\1": "💩"})
        log = log.substr(0, 450)
        if log.endsWith("↵"):
          log = log[0 .. ^(len("↵")+1)]
        if evalResult.log.len >= 450:
          log.add("...")
        if log.len == 0: log = "<no output>"

        if evalResult.success:
          await pmOrig(log)
        else:
          await pmOrig("Compile failed: " & log)
    echo("< ", event.raw.repr)

# -- Commit message handling

proc isRepoAnnounced(state: State, url: string): bool =
  url.toLower() == "nim-lang/nim"

proc getBranch(theRef: string): string =
  if theRef.startswith("refs/heads/"):
    result = theRef[11 .. ^1]
  else:
    result = theRef

proc limitCommitMsg(m: string): string =
  ## Limits the message to 300 chars and adds ellipsis.
  ## Also gets rid of \n, uses only the first line.
  var m1 = m
  if NewLines in m1:
    m1 = m1.splitLines()[0]

  if m1.len >= 300:
    m1 = m1[0..300]

  if m1.len >= 300 or NewLines in m: m1.add("... ")

  if NewLines in m: m1.add($(m.splitLines().len-1) & " more lines")

  return m1

proc onHubMessage(state: State, json: JsonNode) {.async.} =
  if json.hasKey("payload"):
    if isRepoAnnounced(state, json["payload"]["repository"]["full_name"].str):
      let commitsToAnnounce = min(4, json["payload"]["commits"].len)
      if commitsToAnnounce != 0:
        for i in 0..commitsToAnnounce-1:
          var commit = json["payload"]["commits"][i]
          # Create the message
          var message = ""
          message.add(json["payload"]["repository"]["owner"]["name"].str & "/" &
                      json["payload"]["repository"]["name"].str & " ")
          message.add(json["payload"]["ref"].str.getBranch() & " ")
          message.add(commit["id"].str[0..6] & " ")
          message.add(commit["author"]["name"].str & " ")
          message.add("[+" & $commit["added"].len & " ")
          message.add("±" & $commit["modified"].len & " ")
          message.add("-" & $commit["removed"].len & "]: ")
          message.add(limitCommitMsg(commit["message"].str))

          # Send message to #nim.
          await sendMessage(state, joinChans[0], message)
        if commitsToAnnounce != json["payload"]["commits"].len:
          let unannounced = json["payload"]["commits"].len-commitsToAnnounce
          await sendMessage(state, joinChans[0], $unannounced & " more commits.")
      else:
        # New branch
        var message = ""
        message.add(json["payload"]["repository"]["owner"]["name"].str & "/" &
                              json["payload"]["repository"]["name"].str & " ")
        let theRef = json["payload"]["ref"].str.getBranch()
        if json["payload"].hasKey("base_ref"):
          let baseRef = json["payload"]["base_ref"].str.getBranch()
          message.add("New branch: " & baseRef & " -> " & theRef)
        else:
          message.add("New branch: " & theRef)

        message.add(" by " & json["payload"]["pusher"]["name"].str)
        await sendMessage(state, joinChans[0], message)
  elif json.hasKey("announce"):
    proc announce(state: State, msg: string, important: bool) {.async.} =
      var newMsg = ""
      if important:
        newMsg.add("IMPORTANT: ")
      newMsg.add(msg)
      for i in announceChans:
        await sendMessage(state, i, newMsg)
    await announce(state, json["announce"].str, json["important"].bval)

# -- Hub Handling end

proc open(): State =
  var res: State
  new(res)
  getCommandArgs(res)

  if res.irclogsFilename.len == 0:
    quit("No IRC logs filename specified.")


  if not dirExists(res.irclogsFilename):
    quit("IRC logs path does not exist: " & res.irclogsFilename)

  res.logger = newLogger(res.irclogsFilename)

  res.ircClient = newAsyncIrc(ircServer, nick = botNickname,
       joinChans = joinChans,
       callback = (client: AsyncIRC, event: IrcEvent) =>
                     (onIrcEvent(client, event, res)))

  return res

proc connect(state: State): Future[void]
proc hubConnectionLoop(state: State): Future[void]

async:
  proc hubReadLoop(state: State) =
    # Loop until disconnected from hub.
    while true:
      var line = await state.hubClient.recvLine()
      if line == "":
        echo("Disconnected from hub.")
        break
      echo("Got message from Hub: ", line)
      await onHubMessage(state, parseJson(line))
    state.hubClient.close()
    asyncCheck hubConnectionLoop(state)

async:
  proc hubConnectionLoop(state: State) =
    # Loop until we connect to the hub.
    while true:
      state.hubClient = newAsyncSocket()
      try:
        await connect(state)
        break
      except:
        state.hubClient.close()
        echo("Unable to connect to Hub, retrying in 5 seconds")
      await sleepAsync(5000)

    asyncCheck hubReadLoop(state)

async:
  proc connect(state: State) =
    await state.hubClient.connect("127.0.0.1", 9321.Port)

    # Send welcome message to hub.
    await state.hubClient.send(
        $(%{"name": %"irc", "platform": %"n/a", "version": %"1"}) & "\c\l")

    let line = await state.hubClient.recvLine()
    assert line != ""
    echo("Got welcome response: ", line)
    if line.parseJson()["reply"].str == "OK":
      echo("Hub accepted me!")
    else:
      raise newException(ValueError,
          "Hub sent incorrect response to welcome: " & line)

var state = open()
asyncCheck state.ircClient.run()

var settings = newSettings(port = Port(5001))
routes:
  get "/":
    let curTime = getTime().utc()
    var path = state.irclogsFilename / curTime.format("dd'-'MM'-'yyyy'.json'")
    if not fileExists(path):
      path = path.changeFileExt("logs")
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
      if fileExists(logsPath):
        logs = loadRenderer(logsPath)
        resp logs.renderHTML(request)
      else:
        let logsHtml = logsPath.changeFileExt("html")
        cond fileExists(logsHtml)
        resp readFile(logsHtml)
    of "json":
      resp readFile(logsPath.changeFileExt("json"))
    of "logs":
      resp readFile(logsPath)
    else:
      halt()

  get "/static/css/log.css":
    redirect(uri("css/log.css"))

  get "/packages/?":
    var jsonDoc = %{"content": %state.packagesJson}
    cond (jsonDoc != nil)
    var text = $jsonDoc
    if @"callback" != "":
      text = @"callback" & "(" & text & ")"

    resp text, "application/javascript"

  get "/packages.json":
    cond (state.packagesJson.len != 0)

    resp base64.decode(state.packagesJson), "application/json"

asyncCheck refreshLoop(state)

#asyncCheck hubConnectionLoop(state)

runForever()
