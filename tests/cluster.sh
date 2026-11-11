#!/bin/sh
# 3-master cluster on :7101 :7102 :7103, fresh each run.
for p in 7101 7102 7103; do pkill -f "redis-server.*:$p" 2>/dev/null; done
sleep 0.5
D=/tmp/rwcluster; rm -rf $D; mkdir -p $D
for p in 7101 7102 7103; do
  mkdir -p $D/$p
  redis-server --port $p --bind 127.0.0.1 --dir $D/$p --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 2000 --save "" --appendonly no --daemonize yes --logfile $D/$p.log >/dev/null
done
sleep 1
redis-cli --cluster create 127.0.0.1:7101 127.0.0.1:7102 127.0.0.1:7103 --cluster-replicas 0 --cluster-yes >/dev/null 2>&1
for i in $(seq 1 40); do redis-cli -p 7101 cluster info | grep -q "cluster_state:ok" && break; sleep 0.25; done
redis-cli -p 7101 cluster info | grep cluster_state
