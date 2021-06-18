import irc, htmlgen, times, strutils, marshal, os, xmltree, re, json
from jester import Request, makeUri
import irclog
import strtabs

type
  # These legacy types are required to properly marshal the old format so old
  # logs can still be read. The only differences are the timestamps and the new
  # json format for strtabs.
  LegacyIrcEvent = object
    case typ: IrcEventType
    of EvConnected:
      nil
    of EvDisconnected:
      nil
    of EvTimeout:
      nil
    of EvMsg:
      cmd: IrcMType
      nick, user, host, servername: string
      numeric: string
      tags: LegacyStringTableRef
      params: seq[string]
      origin: string
      raw: string
      timestamp: int64
  LegacyStringTableRef = ref StringTableObj
  LegacyEntry = tuple[time: int64, msg: LegacyIRCEvent]

  Entry = tuple[time: Time, msg: IRCEvent]
  TLogRenderer = object of TLogger
    items*: seq[Entry] ## Only used for HTML gen
  PLogRenderer* = ref TLogRenderer

proc toNewEntry(entry: LegacyEntry): Entry =
  result.time = fromUnix(entry.time)
  result.msg = IRCEvent(
    typ: entry.msg.typ
  )
  if result.msg.typ == EvMsg:
    result.msg.cmd = entry.msg.cmd
    result.msg.nick = entry.msg.nick
    result.msg.user = entry.msg.user
    result.msg.host = entry.msg.host
    result.msg.servername = entry.msg.servername
    result.msg.numeric = entry.msg.numeric
    result.msg.tags = cast[StringTableRef](entry.msg.tags)
    result.msg.params = entry.msg.params
    result.msg.origin = entry.msg.origin
    result.msg.raw = entry.msg.raw
    result.msg.timestamp = entry.msg.timestamp.fromUnix

proc loadRenderer*(f: string): PLogRenderer =
  new result
  result.items = @[]
  let logs = readFile(f)
  let lines = logs.splitLines()
  var i = 1
  # Line 1: Start time
  result.startTime = fromUnixFloat(to[float](lines[0])).utc()

  result.logFilepath = f.splitFile.dir
  echo "Reading file: ", f, ": ", f.endsWith(".logs")
  while i < lines.len:
    if lines[i] != "":
      if f.endsWith(".logs"):
        result.items.add(marshal.to[LegacyEntry](lines[i]).toNewEntry)
      elif f.endsWith(".json"):
        result.items.add(json.to(lines[i].parseJson, Entry))
    inc i

const IRCColours = [
  "#e6e6e6",
  "#000000",
  "#bd93f9",
  "#50fa7b",
  "#ff5555",
  "#ff5555",
  "#ff79c6",
  "#ffb86c",
  "#f1fa8c",
  "#50fa7b",
  "#8be9fd",
  "#8be9fd",
  "#bd93f9",
  "#ff79c6",
  "#b3b3b3",
  "#cccccc"
]

proc colourMessage(msg: string): string =
  echo("Calling with ", msg.repr)
  var
    currentChar = 0
    c: char
    openedTags = 0
    currentStyle = ""
    bold, italic, underline, color = false
  template switchStyle(style: var bool, css: string) =
    if not style:
      currentStyle &= css
      style = true
    elif openedTags > 0:
      result &= "</span>"
      openedTags -= 1
      style = false
  while currentChar < msg.len:
    c = msg[currentChar]
    inc currentChar
    case ord c:
    of 0x02: switchStyle bold, "font-weight: bold;"
    of 0x1D: switchStyle italic, "font-style: italic;"
    of 0x1F: switchStyle underline, "text-decoration: underline;"
    of 0x03:
        let colourCode =
          if not color: to[int](msg[currentChar..currentChar+1])
          else: 0
        if not color:
          currentChar += 2
        switchStyle(color, "color: " & IRCColours[colourCode] & ";")
    of 0x0F:
      result &= "</span>".repeat openedTags
      openedTags = 0
      bold = false
      italic = false
      underline = false
    else:
      if currentStyle.len != 0:
        result &= "<span style=\"" & currentStyle & "\">"
        openedTags += 1
        currentStyle = ""
      result &= c
  if openedTags > 0:
    result &= "</span>".repeat openedTags

const NickColours = [
  "#6272a4",
  "#8be9fd",
  "#50fa7b",
  "#ffb86c",
  "#ff79c6",
  "#bd93f9",
  "#ff5555",
  "#f1fa8c",
  "#6272a4",
  "#8be9fd",
  "#50fa7b",
  "#ffb86c",
  "#ff79c6",
  "#bd93f9",
  "#ff5555",
  "#f1fa8c"
]
proc colourNick(msg: string): string =
  var hash = 0
  for c in msg:
    hash += ord c
  "<span style=\"color: " & NickColours[hash mod 16] & "\">" & msg & "</span>"

proc renderMessage(msg: string): string =
  # Transforms anything that looks like a hyperlink into one in the HTML.
  let pattern = re"(https?|ftp)://[^\s/$.?#].[^\s\x02\x1D\x1F\x03\x0F]*"
  result = ""

  var i = 0
  while true:
    let (first, last) = msg.findBounds(pattern, start = i)
    if first == -1: break
    #echo(msg[i .. first-1], "|", msg[first .. last])
    result.add(xmltree.escape(msg[i .. first-1]))
    result.add(a(href=msg[first .. last], xmltree.escape(msg[first .. last])))
    i = last+1
  result.add(xmltree.escape(msg[i .. ^1]))
  result = result.colourMessage()

proc renderItems(logger: PLogRenderer, isToday: bool): string =
  result = ""
  for i in logger.items:
    var c = ""
    case i.msg.cmd
    of MJoin:
      c = "join"
    of MPart:
      c = "part"
    of MNick:
      c = "nick"
    of MQuit:
      c = "quit"
    of MKick:
      c = "kick"
    else:
      discard
    var message = i.msg.params[i.msg.params.len-1]
    if message.startswith("\x01ACTION "):
      c = "action"
      message = message[8 .. ^2]

    let timestamp = i.time.utc().format("HH':'mm':'ss")
    let prefix = if isToday: logger.startTime.format("dd'-'MM'-'yyyy'.html'") & "#" else: "#"
    if c == "":
      result.add(tr(td(a(id=timestamp, href=prefix & timestamp, class="time", timestamp)),
                    td(class="nick", xmltree.escape(i.msg.nick).colourNick),
                    td(id="M" & timestamp, class="msg", message.renderMessage)))
    else:
      case c
      of "join":
        message = i.msg.nick & " joined " & i.msg.origin
      of "part":
        message = i.msg.nick & " left " & i.msg.origin & " (" & message & ")"
      of "nick":
        message = i.msg.nick & " is now known as " & message
      of "quit":
        message = i.msg.nick & " quit (" & message & ")"
      of "action":
        message = i.msg.nick & " " & message
      of "kick":
        message = i.msg.nick & " has kicked " & i.msg.params[1] & " from " & i.msg.params[0]
        if len(i.msg.params) > 2:
          message = message & " (" & i.msg.params[2] & ")"
      else: assert(false)
      result.add(tr(class=c,
                    td(a(id=timestamp, href=prefix & timestamp, class="time", timestamp)),
                    td(class="nick", "*"),
                    td(id="M" & timestamp, class="msg", xmltree.escape(message))))

proc renderHtml*(logger: PLogRenderer, req: jester.Request): string =
  let today       = getTime().utc()
  let isToday     = logger.startTime.monthday == today.monthday and
                    logger.startTime.month == today.month and
                    logger.startTime.year == today.year
  let previousDay = logger.startTime - (initTimeInterval(days=1))
  let prevUrl     = req.makeUri(previousDay.format("dd'-'MM'-'yyyy'.html'"),
                                absolute = false)
  let nextDay     = logger.startTime + (initTimeInterval(days=1))
  let nextUrl     =
    if isToday: ""
    else: req.makeUri(nextDay.format("dd'-'MM'-'yyyy'.html'"), absolute = false)
  result =
    html(
      head(title("#nim logs for " & logger.startTime.format("dd'-'MM'-'yyyy")),
           meta(content="text/html; charset=UTF-8", `http-equiv` = "Content-Type"),
           link(rel="stylesheet", href=req.makeUri("css/boilerplate.css", absolute = false)),
           link(rel="stylesheet", href=req.makeUri("css/log.css", absolute = false)),
           link(rel="stylesheet", href="https://fonts.googleapis.com/css?family=Lato:400,600,900", type="text/css"),
           script(src="js/log.js", type="text/javascript")
      ),
      body(
        htmlgen.`div`(id="controls",
            a(href=prevUrl, "<<"),
            span(logger.startTime.format(" dd'-'MM'-'yyyy ")),
            (if nextUrl == "": span(">>") else: a(href=nextUrl, ">>"))
        ),
        hr(),
        table(
          renderItems(logger, isToday)
        )
      )
    )

when isMainModule:
  doAssert colourMessage("&lt;Rika&gt; so the file size") == """<span style="font-weight: bold;">&lt;Rika&gt;</span> <span style="font-weight: bold;font-style: italic;">so the file size</span>"""
  doAssert(colourMessage("<System64 ~ Flandre Scarlet> (edit) 04removed \"to\"") == """<span style="font-weight: bold;"><System64 ~ Flandre Scarlet></span> (edit) <span style="color: #ff5555;">removed</span> "to"""")
  echo("All good!")