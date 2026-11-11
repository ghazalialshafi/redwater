#!/bin/sh
# Builds and runs every benchmark 3 times against a local Redis/Valkey on :6379
# and writes bench/results/*.txt. Usage: OLDREDIS=/path/to/nim-lang-redis/src sh bench/run_all.sh  (Stagelane is bundled)
set -e
cd "$(dirname "$0")/.."
SL=${STAGELANE:-$(pwd)/vendor/stagelane/src}
OLD=${OLDREDIS:-../redis/src}
mkdir -p bench/results /tmp/rwb
nim c -d:danger --mm:arc --hints:off --warnings:off --path:"$SL" -o:/tmp/rwb/rw bench/rw_bench.nim
nim c -d:danger --mm:orc --hints:off --warnings:off --path:"$OLD" -o:/tmp/rwb/oldasync bench/old_async_bench.nim
nim c -d:danger --mm:orc --hints:off --warnings:off --path:"$OLD" -o:/tmp/rwb/oldsync bench/old_sync_bench.nim
for run in 1 2 3; do
  for b in rw oldasync oldsync; do
    /tmp/rwb/$b | grep '^RESULT' | sed "s/^RESULT/$b/" >> bench/results/clients.txt
  done
done
{
  echo "baseline|seq SET/GET, 1 conn, 1 task|$(redis-benchmark -q -n 100000 -c 1 -d 32 -t set,get 2>/dev/null | tr '\r' '\n' | grep 'requests per second' | sed 's/.*: \([0-9.]*\) requests.*/\1/' | awk '{s+=$1;n++} END{print int(s/n)}')"
  echo "baseline|conc INCR, 50 conns|$(redis-benchmark -q -n 100000 -c 50 -t incr 2>/dev/null | tr '\r' '\n' | grep 'requests per second' | tail -1 | sed 's/.*: \([0-9.]*\) requests.*/\1/' | cut -d. -f1)"
  echo "baseline|pipeline SET, batch 100|$(redis-benchmark -q -n 100000 -c 1 -P 100 -d 32 -t set 2>/dev/null | tr '\r' '\n' | grep 'requests per second' | tail -1 | sed 's/.*: \([0-9.]*\) requests.*/\1/' | cut -d. -f1)"
  echo "baseline|pipeline SET, batch 1000|$(redis-benchmark -q -n 500000 -c 1 -P 1000 -d 32 -t set 2>/dev/null | tr '\r' '\n' | grep 'requests per second' | tail -1 | sed 's/.*: \([0-9.]*\) requests.*/\1/' | cut -d. -f1)"
} > bench/results/baseline.txt
echo done
