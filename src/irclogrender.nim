import irc, htmlgen, times, strutils, marshal, os, xmltree
from jester import PRequest, makeUri
import irclog

type
  TLogRenderer = object of TLogger
    items*: seq[tuple[time: TTime, msg: TIRCEvent]] ## Only used for HTML gen
  PLogRenderer* = ref TLogRenderer

proc loadRenderer*(f: string): PLogRenderer =
  new(result)
  result.items = @[]
  let logs = readFile(f)
  let lines = logs.splitLines()
  var i = 1
  # Line 1: Start time
  result.startTime = fromSeconds(to[float](lines[0])).getGMTime()
  
  result.logFilepath = f.splitFile.dir
  while i < lines.len:
    if lines[i] != "":
      result.items.add(to[tuple[time: TTime, msg: TIRCEvent]](lines[i]))
    inc i

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
      nil
    var message = i.msg.params[i.msg.params.len-1]
    if message.startswith("\x01ACTION "):
      c = "action"
      message = message[8 .. ^2]

    let timestamp = i.time.getGMTime().format("HH':'mm':'ss")
    let prefix = if isToday: logger.startTime.format("dd'-'MM'-'yyyy'.html'") & "#" else: "#"
    if c == "":
      result.add(tr(td(a(id=timestamp, href=prefix & timestamp, class="time", timestamp)),
                    td(class="nick", xmltree.escape(i.msg.nick)),
                    td(id="M" & timestamp, class="msg", xmltree.escape(message))))
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

proc renderHtml*(logger: PLogRenderer, req: jester.PRequest): string =
  let today       = getTime().getGMTime()
  let isToday     = logger.startTime.monthday == today.monthday and
                    logger.startTime.month == today.month and
                    logger.startTime.year == today.year
  let previousDay = logger.startTime - (initInterval(days=1))
  let prevUrl     = req.makeUri(previousDay.format("dd'-'MM'-'yyyy'.html'"),
                                absolute = false)
  let nextDay     = logger.startTime + (initInterval(days=1))
  let nextUrl     =
    if isToday: ""
    else: req.makeUri(nextDay.format("dd'-'MM'-'yyyy'.html'"), absolute = false)
  result = 
    html(
      head(title("#nim logs for " & logger.startTime.format("dd'-'MM'-'yyyy")),
           meta(content="text/html; charset=UTF-8", `http-equiv` = "Content-Type"),
           link(rel="stylesheet", href=req.makeUri("css/boilerplate.css", absolute = false)),
           link(rel="stylesheet", href=req.makeUri("css/log.css", absolute = false)),
           script(src="js/log.js", type="text/javascript")
      ),
      body(
        htmlgen.`div`(id="controls",
            a(href=prevUrl, "<<"),
            span(logger.startTime.format("dd'-'MM'-'yyyy")),
            (if nextUrl == "": span(">>") else: a(href=nextUrl, ">>"))
        ),
        hr(),
        table(
          renderItems(logger, isToday)
        )
      )
    )
