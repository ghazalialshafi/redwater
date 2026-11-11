# Package

version       = "1.0.0"
author        = "redwater contributors"
description   = "redwater: a Redis / Valkey client for Nim on the Stagelane runtime. No futures, no await: flow procs, automatic pipelining, RESP2/RESP3."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
# Stagelane is bundled in vendor/stagelane and put on the path by nim.cfg

task test, "run the protocol, integration and chaos tests (needs Redis/Valkey on :6379)":
  exec "sh tests/run_all.sh"

task bench, "benchmark against nim-lang/redis (see bench/run_all.sh)":
  exec "sh bench/run_all.sh"

task commands, "regenerate docs/commands.md from the command declarations":
  exec "python3 tools/gen_api.py"
