#!/bin/sh
# Runs everything. Needs redis-server, redis-cli and openssl on the PATH.
#   STAGELANE=/path/to/stagelane/src sh tests/run_all.sh
set -e
cd "$(dirname "$0")/.."
SL=${STAGELANE:-$(pwd)/vendor/stagelane/src}
F="--hints:off --warnings:off --path:$SL"
mkdir -p /tmp/rw_tests
echo "== protocol engine (no server, no runtime)"
nim c -d:debug --mm:arc $F -r -o:/tmp/rw_tests/resp tests/t_resp.nim | tail -1
nim c -d:danger --mm:orc $F -r -o:/tmp/rw_tests/resp tests/t_resp.nim | tail -1
sh tests/servers.sh
for mode in "-d:danger --mm:arc" "-d:debug --mm:arc" "-d:release --mm:orc --panics:on"; do
  echo "== integration ($mode)"
  nim c $mode $F -r -o:/tmp/rw_tests/rw tests/t_redwater.nim | tail -1
  echo "== chaos ($mode)"
  nim c $mode $F -o:/tmp/rw_tests/chaos tests/t_chaos.nim && /tmp/rw_tests/chaos 60 100 | head -1
done
echo "== TLS + reconnection"
nim c -d:danger --mm:arc $F -r -o:/tmp/rw_tests/res tests/t_resilience.nim | tail -1
echo "== Sentinel (real failover)"
sh tests/sentinel.sh >/dev/null
nim c -d:danger --mm:arc $F -r -o:/tmp/rw_tests/sent tests/t_sentinel.nim | tail -1
echo "== Cluster (reshard, ASK, outage)"
sh tests/cluster.sh >/dev/null
nim c -d:danger --mm:arc $F -r -o:/tmp/rw_tests/cl tests/t_cluster.nim | tail -1
echo "ALL TESTS PASSED"
