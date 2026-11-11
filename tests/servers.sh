#!/bin/sh
# Starts the extra servers the resilience tests need (idempotent):
#   :6379 plain          :6390 TLS            :6392 mutual TLS
#   :6391 plain, restarted by the tests
D=/tmp/rwtls
mkdir -p $D && cd $D
if [ ! -f ca.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 30 -subj "/CN=redwater-test-ca" 2>/dev/null
  printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > san.ext
  for n in server client; do
    openssl req -newkey rsa:2048 -nodes -keyout $n.key -out $n.csr -subj "/CN=localhost" 2>/dev/null
    openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out $n.crt -days 30 -extfile san.ext 2>/dev/null
  done
fi
start() { redis-cli -p $1 ping >/dev/null 2>&1 || redis-server "$@" --save "" --appendonly no --daemonize yes --logfile /tmp/redis_$1.log >/dev/null; }
redis-cli -p 6379 ping >/dev/null 2>&1 || redis-server --port 6379 --save "" --appendonly no --daemonize yes --logfile /tmp/redis.log >/dev/null
redis-cli -p 6391 ping >/dev/null 2>&1 || redis-server --port 6391 --save "" --appendonly no --daemonize yes --logfile /tmp/redis_6391.log >/dev/null
redis-cli --tls --cacert ca.crt -p 6390 ping >/dev/null 2>&1 || redis-server --port 0 --tls-port 6390 --tls-cert-file $D/server.crt --tls-key-file $D/server.key --tls-ca-cert-file $D/ca.crt --tls-auth-clients no --save "" --daemonize yes --logfile /tmp/redis_6390.log >/dev/null
redis-cli --tls --cacert ca.crt --cert client.crt --key client.key -p 6392 ping >/dev/null 2>&1 || redis-server --port 0 --tls-port 6392 --tls-cert-file $D/server.crt --tls-key-file $D/server.key --tls-ca-cert-file $D/ca.crt --tls-auth-clients yes --save "" --daemonize yes --logfile /tmp/redis_6392.log >/dev/null
sleep 0.5
for p in 6379 6391; do redis-cli -p $p ping >/dev/null || echo "server $p down"; done
redis-cli --tls --cacert ca.crt -p 6390 ping | grep -q PONG || echo "TLS 6390 down"
redis-cli --tls --cacert ca.crt --cert client.crt --key client.key -p 6392 ping | grep -q PONG || echo "mTLS 6392 down"
echo servers ok
