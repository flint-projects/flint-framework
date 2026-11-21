# HTTP client

The Linux client uses the pinned libcurl, nghttp2, OpenSSL, and zlib provider. D module startup initializes libcurl before Reactor starts its workers. Open a client pool before posting the first task to its owner. The first operation binds the pool to the calling thread. Each owning Reactor core can have its own pool and an ordinary thread can also drive a client. Copies share the pool and its lifetime. Close it on its owner after all requests have settled.

## Transfer lifetime

Each pool reserves twice its connection limit in transfer slots. It reuses a native easy handle per slot and keeps a bounded connection cache in one multi handle. The default limits are 64 connections with up to 16 connections per origin, 8 MiB of decoded response bytes, 64 KiB of received headers per hop, and a five-second connection timeout. Configuration accepts 1 through 128 connections. Each request also observes the caller's monotonic Context deadline.

Libcurl socket callbacks publish descriptor interests. Timer callbacks record a monotonic deadline. The owner applies interest changes to the Reactor watch table and drives libcurl from readiness. Transfer fibers yield while waiting and advance the native timer when due. Standalone callers poll on their owning thread with a bounded cancellation-check interval. Completion comes from CURLMSG_DONE or an acknowledged removal. Removing and releasing the transfer retires its generation before send or stream returns.

The shim copies URL, headers, and upload input synchronously. The upload handle must come from the supplied arena. Buffered response headers and entity bytes are copied into that same arena after completion. Their handles expire when its epoch changes. The response protocol reflects the negotiated version. A streaming request delivers decoded bytes through a scoped visitor. The visitor can suspend on a Reactor fiber while the owner keeps unrelated transfers moving. Libcurl pauses when the bounded native chunk is full and resumes after the visitor returns successfully. A non-ok visitor result stops the request.

## HTTPS and redirects

HTTPS verifies the chain and hostname. The default trust is the Linux platform bundle when available. A supplied CA bundle replaces it. Opening with peer verification disabled is an invalid argument. The client accepts HTTP and HTTPS URLs and requires the caller to authorize redirects through a destination policy. The policy receives the normalized initial URL and every destination before network admission. Each request can follow up to five hops. Origin changes remove Authorization, Proxy-Authorization, Cookie, and Cookie2. HTTPS redirects to HTTP fail. Preserved upload methods use the transport's owned copy. Application retry policy lives outside the client.

## Typed exchanges

Annotate an interface with HttpExchange and each method with GetExchange or PostExchange. A method accepts one ref scope RequestArena and one ref Context. Named string arguments substitute complete path components using RFC 3986 encoding. The generator rejects ambiguous dot components. HeaderParam binds a string argument to a request field. A POST accepts one optional typed JSON body, and its Content-Type defaults to application/json.

Result!HttpResponse exposes status, raw header bytes, body bytes, and protocol. Result!DTO decodes a successful JSON reply through serde in the same request arena. The generator reports missing verb annotations, unknown parameter annotations, duplicate header names, ambiguous bodies, and unsupported result types at compilation with the affected method name.

## Linux verification

Build the pinned provider and start the local protocol peers around each test command. The fixture creates a private CA, binds loopback ports, and provides separate HTTP/1.1, HTTP/2, expired TLS, and stalled TLS endpoints.

~~~sh
python3 tools/native_build.py --profile http --target linux-x86_64-glibc --phase build --emit-dub
go build -trimpath -o artifacts/http-fixture packages/http/tests/fixture/server.go
python3 packages/http/tests/fixture/run.py --server artifacts/http-fixture -- dub test :http --compiler=dmd
python3 packages/http/tests/fixture/run.py --server artifacts/http-fixture -- dub test :http --compiler=ldc2
python3 packages/http/tests/fixture/negative.py dmd
python3 packages/http/tests/fixture/negative.py ldc2
python3 tools/gates.py --package http --gate structural
~~~

The protocol tests exercise certificate and redirect policy, all two-byte UTF-8 splits, server writes from 1 through 4,096 bytes, the 8 MiB body boundary, arena generations, typed bindings, 64 simultaneous HTTP/2 requests on one connection, and owner-loop cancellation. The native fixture links against the provider receipt and instruments easy and multi calls, a pending threaded resolver, and native pause state. Run it with the install prefix printed by native preparation.

~~~sh
python3 packages/http/tests/fixture/native.py --prefix "$FLINT_HTTP_NATIVE_PREFIX" \
  --server artifacts/http-fixture --output artifacts/http-native-corpus
~~~

The feature and direct-provider probes each verify 2,048 requests at 1 KiB and 64 KiB over a warmed HTTP/2 connection. Give each executable a fresh protocol fixture so it can check that the connection remains the same for both samples. Both probes report the same consumed checksum and track hot D GC bytes separately from the native corpus's C allocation counts.
