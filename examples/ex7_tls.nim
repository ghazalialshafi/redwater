## TLS: verified by default. Use `rediss://` or the Config fields.
import ../src/redwater

proc main() {.flow.} =
  var cfg = defaultConfig()
  cfg.tls = true
  cfg.tlsCaFile = "/etc/ssl/my-ca.pem"        # omit to use the system trust store
  # mutual TLS: cfg.tlsCertFile = "client.crt"; cfg.tlsKeyFile = "client.key"
  # cfg.tlsInsecure = true                      # skips verification: testing only
  let c = openFlow("redis.example.com", 6380, cfg)   # or openFlow("rediss://redis.example.com:6380")
  echo c.ping()
  c.close()

run main()
