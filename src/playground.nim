import httpclient, asyncdispatch, json, strutils

type
  EvaluationResult* = object
    success*: bool
    log*: string

proc evalCode*(code: string): Future[EvaluationResult] {.async.} =
  let client = newAsyncHttpClient()

  let payload = %*{
    "code": code,
    "compilationTarget": "c"
  }

  let response = await client.post("https://play.nim-lang.org/compile",
                                   $payload)
  if response.status == Http200:
    # Parse the response.
    let content = await response.bodyStream.readAll()
    let respObj =
      try:
        parseJson(content)
      except Exception as exc:
        %*{"error": exc.msg}

    if respObj.hasKey("error"):
      return EvaluationResult(success: false, log: respObj["error"].getStr())

    var log = respObj["log"].getStr()
    let compileLog = respObj["compileLog"].getStr()
    # Determine whether the compilation was successful.
    let success = "success" in compileLog.toLowerAscii()

    if not success:
      # Lookup the error in the compile log.
      for line in compileLog.splitLines():
        if "error:" in line.toLowerAscii():
          log = line

    return EvaluationResult(success: success, log: log)

when isMainModule:
  let evalResult = waitFor evalCode("echo asd")
  echo(evalResult)
