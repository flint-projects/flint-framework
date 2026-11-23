# RPC

`flint.engine.rpc` registers explicit WebSocket, SSE and gRPC server routes. `registerWebSocket` takes a `WebSocket` path and an owner-fiber handler. `registerSse` takes an `Sse` path and exposes `sendEvent` and `sendHeartbeat` on the borrowed response stream. `registerGrpc` takes a `GrpcService` name, method and handler. The handler uses `RpcStream.receive` and `RpcStream.send` for the method's declared message counts. `RpcStream.finish` commits one terminal status, with an optional message in the request arena.

The WebSocket listener validates the version 13 upgrade and uses pinned OpenSSL for the accept key. It checks masking, canonical lengths, control framing and UTF-8 across fragments. A locally initiated close gives the peer five seconds to complete the handshake. SSE sends chunked HTTP/1 responses or incremental HTTP/2 DATA. Its parser handles LF and CRLF, incremental UTF-8, event ids, retry fields and comments.

gRPC uses pinned nghttp2 for the HTTP/2 transport. Each stream has a 65,535-byte receive window and one bounded outbound chunk. The transport returns receive credit as the application consumes bytes. The gRPC adapter decodes one message at a time and checks the four-MiB limit before reserving its payload. The caller supplies arena space for the admitted message. Each send copies bytes into transport-owned storage and yields when its bounded output queue is full. A request deadline inherits connection cancellation and produces deadline status while the connection can still send trailers. The current profile accepts uncompressed protobuf messages.

## Outbound calls

`beginGrpc` opens an HTTP/2 call through an owner-confined `HttpClient`. Send protobuf buffers with `GrpcCall.send`, finish the upload with `finishSend`, and continue reading with `receive`. The first response can arrive before upload EOF. For concurrent upload and download, run one writer and one reader on separate fibers on the same Reactor owner, using a separate arena for each. A second concurrent reader or writer receives `Status.conflict`. A successful end of the message sequence reports `Status.notFound`; retrieve the remote result with `status` and application trailers with `trailers`. Missing or malformed terminal status fails the call. `close` releases the native transfer slot on the owner.

`connectWebSocket` verifies the HTTP/1.1 upgrade digest and rejects unsolicited extensions and subprotocols. Each outbound frame uses a fresh client mask. `WebSocketClient.receive` handles control frames, and `close` waits up to five seconds for the peer under the caller deadline. `abort` closes immediately. `subscribeSse` validates the response and calls a scoped visitor for events, comments and retry fields. A caller resumes by supplying the last event id in `SseClientOptions`.

All three clients verify TLS trust and hostname by default. Tests can opt in to cleartext for a numeric Linux loopback address. Each gRPC call retains the context supplied when it opens. The transport checks that context alongside the context passed to each operation. The default duplex receive-rate target is 256 KiB/s and callers can choose 32–256 KiB/s. The pinned curl uses that target to pace HTTP/2 stream credit. An independent loopback peer sent 458,754 bytes while reads were paused at the default target, then resumed when the reader drained the buffer. Curl's shared connection pool and window have separate bounds.

## Generated Protobuf

Run `engine/rpc/tools/protoc-gen-flint` with pinned protoc 30.2, protobuf-c 1.5.2 and dfmt 0.15.2. The build-time descriptor reader uses `protobuf==7.36.2`. The checked test schema is `tests/proto/echo.proto`. The generator writes the C codec, a small descriptor adapter, typed D DTOs and a generation receipt. Pass `--check` to compare a fresh generation with the checked artifacts. Link the generated C objects and pinned protobuf-c for any schema used by the application. Native preparation installs the checked test codec in a separate `flint_rpc_fixture` archive. Its receipt hash is checked when the archive is linked through the emitted `unittest` recipe.

The generator accepts a self-contained proto3 schema with scalar and enum values, nested messages, repeated fields, maps and oneof fields. It uses fixed repeated capacities and a bounded native scratch allocator. It rejects recursive descriptor graphs, proto2, groups, editions and proto3 optional scalars. Ordinary nested fields have presence. Maps preserve the entries supplied by protobuf-c. Unknown enum numbers remain visible in generated DTOs. Unknown wire fields are discarded at the typed boundary. The pinned provider models strings as C strings, so the generated encoder rejects embedded NUL.

## Verification

Linux DMD and LDC passed the pinned-provider unit tests and loopback tests. A pinned gRPC-Go v1.76.0 client using its standard Protobuf codec passed all four call shapes, request metadata, deadlines, cancellation and reuse of the same connection. The independent hyper-h2 fixture exercises constrained flow windows, multiplexed 64-KiB messages, terminal trailers, compression rejection and truncated messages. The WebSocket and SSE fixture covers a coalesced upgrade, fragmented UTF-8, ping/pong, binary and text messages, close handshake and timeout, event and heartbeat bytes, and disconnect cancellation. Both compilers reject retained scoped peers and streams in debug and release.

The native C bridge and generated codec wrapper ran with ASan, UBSan and leak detection. Their pinned provider archives were built without sanitizer instrumentation. The LDC DUB unit profile also ran with ASan and leak detection. Native and build results are retained in `artifacts/tasks/m3-rpc`.

Autobahn Testsuite 25.10.1 reported 244 successful and three informational server cases with zero failures. The run excluded groups 9, 12 and 13, following the upstream sample for long-running and compression cases. [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite#using-the-testsuite-docker-image-recommended).

Outbound tests under `artifacts/tasks/m3-rpc-outbound` cover grpc-go on trusted TLS and loopback HTTP/2, SSE field splitting, and WebSocket masking, digest validation and close over TLS and loopback. The pinned Autobahn fuzzing server observed 244 successful and three informational results from the outbound client across the same selected groups.

Fixed-runner performance certification and non-Linux qualification remain open. The local full DUB build reported 10,192 template instances against a ceiling of 2,000.

[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), [HTML server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html), [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md), [gRPC-Go v1.76.0](https://github.com/grpc/grpc-go/releases/tag/v1.76.0).
