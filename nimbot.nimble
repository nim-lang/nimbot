[Package]
name          = "nimbot"
version       = "0.1.0"
author        = "Dominik Picheta"
description   = "The friendly, slightly sentient Nim IRC bot."
license       = "MIT"

srcDir = "src"

bin = "nimbot"

[Deps]
Requires: "nimrod >= 0.10, irc 0.4.0, jester 0.5.0"
