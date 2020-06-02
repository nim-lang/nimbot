import irc, htmlgen, times, strutils, marshal, os, xmltree, re, json
from jester import Request, makeUri
import irclog

type
  Entry = tuple[time: Time, msg: IRCEvent]
  TLogRenderer = object of TLogger
    items*: seq[Entry] ## Only used for HTML gen
  PLogRenderer* = ref TLogRenderer

proc loadRenderer*(f: string): PLogRenderer =
  new result
  result.items = @[]
  let logs = readFile(f)
  let lines = logs.splitLines()
  var i = 1
  # Line 1: Start time
  result.startTime = fromUnixFloat(to[float](lines[0])).utc()

  result.logFilepath = f.splitFile.dir
  while i < lines.len:
    if lines[i] != "":
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
  var
    currentChar = 0
    c: char
    openedTags = 0
    currentStyle = ""
    bold, italic, underline = false
  template switchStyle(style: var bool, css: string) =
    if not style:
      currentStyle &= css
      style = true
    else:
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
      let colourCode = to[int](msg[currentChar..^1])
      currentStyle &= "color: " & IRCColours[colourCode] & ";"
      currentChar += 2
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
