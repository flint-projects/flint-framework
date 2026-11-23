# HTTP acceptance traceability

Source: `handoff/specs/tier-2/http.md`, section 7 ("Required unit, protocol, fuzz and benchmark acceptance"). Section 6 of this spec is the size budget. The table also traces the section 4 edge cases that have observable behaviour.

Locations:

- `behavior` is `tests/http_behavior.d`.
- `acceptance` is `tests/http_acceptance.d`.
- `negative/` holds the compile-fail sources. `tests/fixture/negative.py <dmd|ldc2>` checks each for a nonzero exit, the method name and the diagnostic text.
- `native.c` is `tests/fixture/native.c`, built against the pinned curl/nghttp2/OpenSSL/zlib receipt with `-fsanitize=address,undefined` and `-DFLINT_HTTP_TEST_OWNER=1` by `tests/fixture/native.py`.
- `bench` is `bench/source/app.d` with `bench/harness/http_workload.d`.

Tests marked "fixture" need the Go protocol peers (`tests/fixture/run.py --server <built server.go> -- dub test :http`). Without the peers they return early. Only the thread-owner test and the policy checks at the top of `behavior` run offline.

| Case | Spec item (abridged) | Covering test(s) | Status |
| --- | --- | --- | --- |
| tls_policy | Expired certificate fails | behavior: "Linux pinned HTTP transport, TLS policy, redirects, limits and typed bindings" (fixture, `EXPIRED` → `permissionDenied`) | covered |
| tls_policy | Hostname mismatch fails | behavior: same test (fixture, `MISMATCH`: 127.0.0.1 against a `localhost` certificate → `permissionDenied`) | covered |
| tls_policy | Untrusted certificate fails | behavior: same test (fixture, the platform trust store rejects the private CA → `permissionDenied`) | covered |
| tls_policy | Configured private CA succeeds | behavior: same test (fixture, `caBundle` → HTTP/2 204), plus the 64-request multiplex test | covered |
| tls_policy | Redirects do not leak Authorization | behavior: same test, `exerciseRedirects` (fixture, cross-origin peer answers 409 if Authorization or Cookie arrives; same-origin hop keeps them). acceptance: "tls_policy, stream_chunks and body_limit acceptance against the local protocol peers" (fixture) also sends Proxy-Authorization and Cookie2 across the origin change | covered / added |
| tls_policy (§4) | A missing CA path cannot silently disable verification | acceptance: same test, `exerciseMissingTrust` (fixture, unreadable `caBundle` → HTTPS `permissionDenied`, cleartext still 204) | added |
| tls_policy (§4) | Supplied CA bundle and platform trust store both tested | Supplied bundle: covered above. Platform store negative path (private CA rejected) covered above | blocked (positive platform-store success needs a publicly trusted server or a change to the system trust store; neither is available on the loopback runner) |
| tls_policy (§4) | Verification cannot be disabled; redirects need a destination policy | behavior: "invalid TLS and bounded-pool policies fail before allocation" (`verifyPeer = false`, `followRedirects` without a policy → `invalidArgument`) | covered |
| tls_policy (§4) | Redirect cap of five, no HTTPS→HTTP downgrade, destination policy on every hop | behavior: `exerciseRedirects` (fixture, `/again?n=5` 204 and `n=6` `resourceExhausted`; HTTPS→HTTP `permissionDenied`; policy called per hop, `/banned` denied) | covered |
| http2_multiplex | 64 requests share one negotiated h2 connection without cross-request corruption | behavior: "64 pinned reactor fibers multiplex over one negotiated and verified HTTP/2 connection" (fixture, per-request header/body checks and one `X-Connection` id, epoll and io_uring) | covered |
| owner_wake (ADR-017) | A waiting fiber resumes on readiness, a fired or moved libcurl timer, or cancellation, without spinning or a 1 ms poll | behavior: "reactor-fiber exchanges with an origin slower than 200 µs are neither paced by a 1 ms poll nor spun for" (fixture, `/delayed` answers after 300 µs; median exchange under 800 µs and worker CPU under 15 ms for 100 exchanges). native.c `complete_stream` checks `flint_http_timer` on a running transfer and `wrong_owner` checks its owner rejection | added |
| stream_chunks | Every split of a two-byte UTF-8 sequence | behavior: `exerciseStreams` (fixture, `/utf?split=0..2` with a flush and a 4 ms gap between halves) | covered |
| stream_chunks | 1..4096-byte body chunks arrive as the exact original bytes | behavior: `exerciseStreams` (fixture, `/chunks` 1..2048 and 2049..4096, byte-checked). acceptance: `exerciseFlushedChunks` (fixture) flushes each write as its own HTTP/1.1 chunk or HTTP/2 DATA frame, over both protocols | covered / added |
| cancel_stages | Cancel while queued | behavior: "bounded queue, paused consumer backpressure and cancellation preserve owner progress" (fixture, deadline while pending behind a held connection). acceptance: "cancel_stages: explicit cancellation of a queued transfer delivers one completion and frees its slot" (fixture, explicit `CancelSource`, one completion, arena empty, slot reused) | covered / added |
| cancel_stages | Cancel while resolving | native.c `cancel_resolving` (the wrapped `getaddrinfo` blocks inside the pinned threaded resolver; cancel completes with `CANCELLED`, release retires the generation, the resolver thread returns later) | covered |
| cancel_stages | Cancel while connecting | behavior: `exerciseCancellation` (fixture, an 80 ms Context deadline on a peer that accepts TCP and never finishes TLS → `timedOut`; a separate 35 ms connect timeout → "HTTP connection deadline elapsed") | covered |
| cancel_stages | Cancel while receiving | behavior: `exerciseCancellation` (fixture, `/late` cancelled from the consumer, exactly one callback, arena reset, next request succeeds) | covered |
| cancel_stages | Cancel while paused | behavior: "bounded queue, paused consumer…" with `paused = true` (fixture, the consumer suspends while libcurl pauses an 8 MiB stream, another origin completes, then cancel). native.c `cancel_paused` checks the native pause state and chunk | covered |
| cancel_stages | One completion; no borrowed memory remains | Every cancel test above asserts one outcome and a resettable or empty arena. behavior also checks that a stale arena body handle is rejected and that a too-small arena leaves `used == 0` | covered |
| curl_thread_owner | Every easy/multi call for a handle runs on the recorded owner thread | native.c `main` (`FLINT_HTTP_TEST_OWNER` asserts the owner on each wrapped call: 1,802 checked calls; a foreign thread gets `CONFLICT`) | covered |
| curl_thread_owner | D transport rejects a second thread | acceptance: "curl_thread_owner: a second thread cannot drive or close a client bound to its first caller" (offline; send, stream and close from another thread → `conflict`, owner unchanged) | added |
| body_limit | 8,388,608 bytes succeeds; the next byte returns resourceExhausted | behavior: `exerciseStreams` (fixture, buffered `/bytes` 8388608 ok and 8388609 `resourceExhausted`, arena empty) | covered |
| body_limit | Streaming transfers obey the same limit | acceptance: `exerciseUpstreamStop` (fixture, the stream of exactly 8388608 bytes succeeds; an unbounded stream returns `resourceExhausted` after at most 8388608 delivered bytes) | added |
| body_limit | The limit stops the upstream transfer | acceptance: `exerciseUpstreamStop` (fixture, buffered, streaming and consumer-stopped requests for a 256 MiB entity over HTTP/1.1 and HTTP/2; the peer reports that its write failed after less than 64 MiB) | added |
| exchange_negative | Unknown parameter UDA fails with method identity | `negative/unknown_uda.d` (`unknownParameter`, "unknown parameter UDA") | covered |
| exchange_negative | Two body arguments fail with method identity | `negative/two_bodies.d` (`duplicateBodies`, "multiple body arguments") | covered |
| exchange_negative | Unsupported return type fails with method identity | `negative/bad_return.d` (`scalarResponse`, "requires Result!HttpResponse") | covered |
| exchange_negative (§4) | Unannotated methods and ambiguous header names fail | `negative/unannotated.d`, `negative/ambiguous_header.d`. Scope escapes: `negative/escape_chunk.d`, `escape_destination.d`, `escape_request_view.d` | covered |
| exchange (§4) | Path components use RFC 3986 encoding and never reach the authority | behavior: `exerciseExchange` (fixture, `a/λ?%#` → `a%2F%CE%BB%3F%25%23`; `..` → `invalidArgument`; typed JSON body through serde) | covered |
| transport_bench | Warm reused HTTPS, 1 KiB/64 KiB streaming; no D GC allocation on send/stream | bench (LDC release, fixture: 2,048 transfers at each size on one checked h2 connection, `d_gc_bytes 0`). native.c `sample_allocations` reports C allocation calls separately (1,232 at 1 KiB, 1,646 at 64 KiB over 16 transfers). behavior multiplex and stage tests assert reactor `gcAllocated == 0` | covered |
| limits (§4) | Queue capacity is twice maxConnections; exhaustion returns resourceExhausted before network work | behavior: "bounded queue…" (`queueFull`, arena `used == 0`) | covered |
| limits (§4) | Connection, origin, header and pool-size bounds | behavior: "invalid TLS and bounded-pool policies…" (129 connections rejected); `exercisePolicy` (16-byte `maxHeaderBytes` → `resourceExhausted`; CRLF and `Content-Length` fields rejected) | covered |
| duplex early end (§4 "one completion") | A peer that completes the response while the duplex upload is still open | behavior: "duplex_early_end: a response completed while the upload is open ends receive, trailers and the request side" (fixture). net/http over TLS ends with END_STREAM and RST_STREAM(NO_ERROR): head, body EOF and trailers arrive in well under 1 s against a 3 s deadline, a later `send`/`finishSend` returns `conflict`, `close` is idempotent, and four rounds plus an unread close reuse a two-slot pool. A raw prior-knowledge peer that sends END_STREAM without RST_STREAM: the pinned libcurl keeps the end and the trailers until the stream closes, so `receive` waits while the upload is open and delivers EOF and trailers at once after `finishSend`. HTTP/1.1-only peers (TLS ALPN and cleartext) fail at once with `ioError`, since duplex is HTTP/2 only | added |
| fuzz seeds | Truncated input, maximum lengths, empty values, cancellation, generation reuse | native.c `corpus` (truncated and over-long URLs at the exact boundary, empty header values, cancel and release, stale-generation `CONFLICT`/`NOT_FOUND`), under ASan/UBSan | covered |

## Stubs and ignored inputs

None found in `source/`. Every `return Error.init` in `client.d` follows completed work or is the idempotent close of an unopened client or stream. Without the pinned provider, `ffi/shim.d` returns `unsupported` and never reports success. `Bridge.allow` accepts when no destination policy is set; `open` requires a policy whenever redirects are enabled.

Finding outside this package: the rpc review reported that a duplex `HttpStream.receive` does not see the end of a gRPC call that the server ends while the client's upload is still open. The client shim is not the cause. The pinned libcurl (8.23.0-DEV, `lib/http2.c`) treats END_STREAM on a 2xx response with an unfinished upload as a legal half-closed stream: `on_frame_recv` only marks the transfer dirty, the trailers stay buffered in `resp_trailers`, and `http2_handle_stream_close` delivers them and the 0-byte EOF only after nghttp2 calls `on_stream_close`, which needs both directions closed. While the shim's read callback is paused (`CURL_READFUNC_PAUSE`), no public libcurl callback or info reports the server's END_STREAM. A server that follows RFC 9113 section 8.1 and sends RST_STREAM(NO_ERROR) after its complete response closes the stream; `sendrecv_dl` then aborts the upload (`Curl_req_stop_send_recv`) and the transfer completes once through `CURLMSG_DONE`. net/http (verified by the test above) and grpc-go do this. Flint's own HTTP/2 server (`native/ffi/flint_web.c`) does not, which is what the rpc tests hit. The `duplex_early_end` row above covers both peer behaviours.

## Verification (2026-11-21, Linux x86-64)

- `tests/fixture/run.py --server <server.go build> -- dub test :http`: passed on DMD and LDC (2 modules). Each test binary was rerun 10 times under the peers and passed every time.
- The same suite without the peers passed on both compilers.
- `tests/fixture/negative.py dmd|ldc2`: all 8 compile-negative cases are rejected with the expected method name and diagnostic.
- `tests/fixture/native.py --prefix <native install>` (ASan and UBSan): passed.
- `bench/build/probe-http` (LDC release) under the peers: 1 KiB 2,048 transfers in 312 ms, 64 KiB 2,048 transfers in 1,171 ms, `d_gc_bytes 0` for both, checksum `http-stream 33293017088`.
- `tools/gates.py --package http --gate structural`: passed.
- `tools/quality.py --path engine/http`: 0 issues.
