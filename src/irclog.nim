import htmlgen, times, irc, streams, strutils, os, parseutils, marshal, sequtils, strtabs
from xmltree import escape
import json except to

type
  TLogger* = object of RootObj # Items get erased when new day starts.
    startTime*: DateTime
    logFilepath*: string
    logFile*: File
  PLogger* = ref TLogger
  LoggedIRCEvent* = object

const
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

proc loadLogger*(f: string): PLogger =
  new result
  let logs = readFile(f)
  let lines = logs.splitLines()
  # Line 1: Start time
  result.startTime = fromUnixFloat(to[float](lines[0])).utc()
  if not open(result.logFile, f, fmAppend):
    echo("Warning: Could not open logger: " & f)
  result.logFilepath = f.splitFile.dir

proc writeFlush(file: File, s: string) =
  file.write(s)
  file.flushFile()

proc newLogger*(logFilepath: string): PLogger =
  let startTime = getTime().utc()
  let log = logFilepath / startTime.format("dd'-'MM'-'yyyy'.json'")
  if fileExists(log):
    result = loadLogger(log)
  else:
    new result
    result.startTime = startTime
    result.logFilepath = logFilepath
    doAssert open(result.logFile, log, fmAppend)
    # Write start time
    result.logFile.writeFlush($$epochTime() & "\n")

proc `$`(s: seq[string]): string =
  var escaped = sequtils.map(s) do (x: string) -> string:
    strutils.escape(x)
  result = "[" & join(escaped, ",") & "]"

proc toJson(msg: IRCEvent): JsonNode =
  result = newJObject()
  result["typ"] = %msg.typ
  case msg.typ
  of EvMsg:
    for name, value in msg.fieldPairs:
      when name notin ["tags"]:
        result[name] = %value
    result["tags"] = newJNull()
  else:
    discard # Other types have no fields.

proc writeLog(logger: PLogger, msg: IRCEvent) =
  let event = %{
    "time": %getTime(),
    "msg": toJson(msg)
  }
  logger.logFile.writeFlush($(event) & "\n")

proc log*(logger: PLogger, msg: IRCEvent) =
  if msg.origin != "#nim" and msg.cmd notin {MQuit, MNick}: return
  if getTime().utc().yearday != logger.startTime.yearday:
    # It's time to cycle to next day.
    # Reset logger.
    logger.logFile.close()
    logger.startTime = getTime().utc()
    let log = logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.json'")
    doAssert open(logger.logFile, log, fmAppend)
    # Write start time
    logger.logFile.writeFlush($epochTime() & "\n")

  case msg.cmd
  of MPrivMsg, MJoin, MPart, MNick, MQuit: # TODO: MTopic? MKick?
    #logger.items.add((getTime(), msg))
    #logger.save(logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.json'"))
    writeLog(logger, msg)
  else: discard

proc log*(logger: PLogger, nick, msg, chan: string) =
  var m: IRCEvent
  m.typ = EvMsg
  m.cmd = MPrivMsg
  m.params = @[chan, msg]
  m.origin = chan
  m.nick = nick
  logger.log(m)

when isMainModule:
  var logger = newLogger("testing/logstest")
  logger.log("dom96", "Hello!", "#nim")
  logger.log("dom96", "Hello\r, testingí, \"\"", "#nim")
  #logger = loadLogger("testing/logstest/26-05-2013.logs")
  echo repr(logger)
