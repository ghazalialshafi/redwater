## redwater/tls - TLS transport (OpenSSL, non-blocking).
##
## OpenSSL is bound through Nim's `std/openssl`, which loads `libssl` lazily at
## the first TLS call: a program that never connects with TLS never needs the
## library. The functions here never block; they return a status telling the
## connection layer whether to wait for the socket to become readable or
## writable, which it does with Stagelane's `waitReadable` / `waitWritable`.

import std/[openssl, nativesockets]
export openssl.SslPtr

const
  ioWantRead* = -2      ## retry after the socket is readable
  ioWantWrite* = -3     ## retry after the socket is writable
  ioError* = -1         ## fatal: see `tlsLastError`
  ioEof* = 0            ## the peer closed the connection cleanly

type
  TlsSettings* = object
    ## What `newTlsContext` needs; filled from `Config`.
    verify*: bool                ## verify the server certificate (default: true)
    caFile*: string              ## PEM bundle of trusted CAs ("" = system store)
    caDir*: string               ## directory of hashed CA certs
    certFile*: string            ## client certificate chain (mutual TLS)
    keyFile*: string             ## client private key
    serverName*: string          ## SNI + hostname to verify ("" = the host dialled)
  TlsContext* = ref object
    ctx: SslCtx

proc SSL_set1_host(ssl: SslPtr, name: cstring): cint {.cdecl, dynlib: DLLSSLName, importc.}
proc SSL_CTX_set_default_verify_paths(ctx: SslCtx): cint {.cdecl, dynlib: DLLSSLName, importc.}

const
  SSL_VERIFY_NONE = 0
  SSL_VERIFY_PEER = 1
  SSL_CTRL_MODE = 33
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123
  SSL_MODE_ENABLE_PARTIAL_WRITE = 1
  SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 2
  TLS1_2_VERSION = 0x0303

proc tlsLastError*(): string =
  ## the most recent OpenSSL error, as text
  var code = ERR_get_error()
  if code == 0: return "unknown TLS error"
  var buf = newString(256)
  discard ERR_error_string(code, cstring(buf))
  result = $cstring(buf)
  while true:                                  # drain the rest of the queue
    code = ERR_get_error()
    if code == 0: break

proc newTlsContext*(s: TlsSettings): TlsContext =
  ## Builds a client context (TLS 1.2 or newer). Raises `IOError` on a bad
  ## certificate / key / CA path.
  let ctx = SSL_CTX_new(TLS_client_method())
  if ctx == nil: raise newException(IOError, "TLS: cannot create context: " & tlsLastError())
  discard SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)
  discard SSL_CTX_ctrl(ctx, SSL_CTRL_MODE,
    SSL_MODE_ENABLE_PARTIAL_WRITE or SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, nil)
  if s.verify:
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
    if s.caFile.len > 0 or s.caDir.len > 0:
      if SSL_CTX_load_verify_locations(ctx,
          (if s.caFile.len > 0: cstring(s.caFile) else: nil),
          (if s.caDir.len > 0: cstring(s.caDir) else: nil)) != 1:
        let e = tlsLastError()
        SSL_CTX_free(ctx)
        raise newException(IOError, "TLS: cannot load CA certificates: " & e)
    else:
      discard SSL_CTX_set_default_verify_paths(ctx)
  else:
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
  if s.certFile.len > 0:
    if SSL_CTX_use_certificate_chain_file(ctx, cstring(s.certFile)) != 1:
      let e = tlsLastError()
      SSL_CTX_free(ctx)
      raise newException(IOError, "TLS: cannot load client certificate: " & e)
    let key = if s.keyFile.len > 0: s.keyFile else: s.certFile
    if SSL_CTX_use_PrivateKey_file(ctx, cstring(key), SSL_FILETYPE_PEM) != 1:
      let e = tlsLastError()
      SSL_CTX_free(ctx)
      raise newException(IOError, "TLS: cannot load client key: " & e)
  TlsContext(ctx: ctx)

proc tlsNew*(c: TlsContext, fd: SocketHandle, serverName: string, verify: bool): SslPtr =
  ## A fresh TLS session on a connected, non-blocking socket.
  let ssl = SSL_new(c.ctx)
  if ssl == nil: raise newException(IOError, "TLS: cannot create session: " & tlsLastError())
  discard SSL_set_fd(ssl, fd)
  if serverName.len > 0:
    discard SSL_set_tlsext_host_name(ssl, cstring(serverName))   # SNI
    if verify: discard SSL_set1_host(ssl, cstring(serverName))   # hostname check
  result = ssl

proc classify(ssl: SslPtr, ret: cint): int =
  case SSL_get_error(ssl, ret)
  of SSL_ERROR_WANT_READ: ioWantRead
  of SSL_ERROR_WANT_WRITE: ioWantWrite
  of 6: ioEof                      # SSL_ERROR_ZERO_RETURN: clean close_notify
  else: ioError

proc tlsHandshake*(ssl: SslPtr): int =
  ## One handshake step: 1 when finished, else `ioWantRead` / `ioWantWrite` /
  ## `ioError`.
  let r = SSL_connect(ssl)
  if r == 1: return 1
  let k = classify(ssl, r)
  if k == ioEof: ioError else: k

proc tlsVerifyError*(ssl: SslPtr): string =
  ## "" if the peer certificate verified, else OpenSSL's reason
  let v = SSL_get_verify_result(ssl)
  if v == 0: "" else: "certificate verify failed (code " & $v & ")"

proc tlsRead*(ssl: SslPtr, p: pointer, n: int): int =
  ## bytes read (> 0), or `ioWantRead` / `ioWantWrite` / `ioEof` / `ioError`
  let r = SSL_read(ssl, p, n)
  if r > 0: int(r) else: classify(ssl, r)

proc tlsWrite*(ssl: SslPtr, p: pointer, n: int): int =
  ## bytes written (> 0), or `ioWantRead` / `ioWantWrite` / `ioError`
  let r = SSL_write(ssl, cast[cstring](p), n)
  if r > 0: int(r)
  else:
    let k = classify(ssl, r)
    if k == ioEof: ioError else: k

proc tlsClose*(ssl: SslPtr) =
  ## best-effort close_notify, then free
  if ssl != nil:
    discard SSL_shutdown(ssl)
    SSL_free(ssl)
