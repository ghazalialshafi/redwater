#!/bin/sh
# master :7001, replica :7002, sentinel :27001 ("mymaster", quorum 1). Fresh state each run.
pkill -f "redis-server.*:7001" 2>/dev/null; pkill -f "redis-server.*:7002" 2>/dev/null; pkill -f "redis-server.*:27001" 2>/dev/null
sleep 0.5
D=/tmp/rwsent; rm -rf $D; mkdir -p $D
redis-server --port 7001 --bind 127.0.0.1 --dir $D --save "" --appendonly no --daemonize yes --logfile $D/m.log --replica-announce-ip 127.0.0.1 >/dev/null
redis-server --port 7002 --bind 127.0.0.1 --dir $D --save "" --appendonly no --daemonize yes --logfile $D/r.log --replicaof 127.0.0.1 7001 >/dev/null
cat > $D/s.conf <<EOC
port 27001
bind 127.0.0.1
dir $D
daemonize yes
logfile $D/s.log
sentinel monitor mymaster 127.0.0.1 7001 1
sentinel down-after-milliseconds mymaster 800
sentinel failover-timeout mymaster 4000
sentinel parallel-syncs mymaster 1
EOC
redis-server $D/s.conf --sentinel >/dev/null
for i in $(seq 1 40); do
  redis-cli -p 7002 info replication 2>/dev/null | grep -q "master_link_status:up" && redis-cli -p 27001 sentinel replicas mymaster 2>/dev/null | grep -q "7002" && break
  sleep 0.25
done
redis-cli -p 27001 sentinel get-master-addr-by-name mymaster | tr '\n' ' '; echo
