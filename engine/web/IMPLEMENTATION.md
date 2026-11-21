# Web

`flint.web` registers explicit controllers and compiles the typed route adapters. The listener uses pinned llhttp for HTTP/1 and pinned nghttp2 for HTTP/2. Requests, captures, headers and response bodies use generation-checked arena handles. The server holds response storage until the final transport completion, and a scoped request cannot be retained by a handler.

HTTP/1 is the default. Set `ServerOptions.http2PriorKnowledge` for cleartext HTTP/2. Set both `tlsCertificateFile` and `tlsPrivateKeyFile` for a TLS listener. The TLS listener negotiates `h2` or `http/1.1` through the pinned OpenSSL provider, refuses incompatible ALPN offers and rejects an invalid PEM keypair at startup.

`Server.routeBatch` checks the entire batch before inserting any route. `Server.isLoopbackListener` admits a prepared listener bound to a numeric IPv4 loopback address or `::1`. Register a single `@ControllerAdvice` via `registerAdvice` or as an explicit application field. Advice receives a sanitized error and can provide its response body. The mapped status is determined by the original error.

`@WorkerController` opts a controller into full-D allocation and exception handling. Each registered controller has one dedicated worker and 16 request slots. A slot owns up to 4,096 bytes of request data and 4,096 bytes of response body, with space for up to 64 header fields and 16 captures. An oversized request receives 413. A raw worker response may provide a built-in JSON, plain-text, HTML or binary content type. Give a class-based worker controller exclusive ownership of its instance. A struct instance is copied at registration. Workers receive a retained cancellation token and run the normal binding and response adapters against an independent arena. A canceled job holds its slot until worker completion. Shutdown waits for the reactor and workers and returns a timeout if the supplied deadline expires first.

## Linux verification

The linked native tests passed under DMD and LDC with pinned providers. The socket fixture exercised HTTP/1 framing and bindings, advice, 128 KiB slow-receiver drainage, disconnect and detached worker cancellation, slot reuse, HTTP/2 multiplexing and flow credit, stream caps, trusted TLS negotiation for both HTTP versions, and the shutdown of 1,024 admitted requests. An overflowing WINDOW_UPDATE on a live stream received RST_STREAM with FLOW_CONTROL_ERROR while its sibling stream completed. A peer GOAWAY received reciprocal GOAWAY and the connection drained through EOF. Independent C boundary tests ran with ASan, UBSan and leak detection. Their linked provider archives were built without sanitizer instrumentation. The LDC-native `:web` unit suite also passed ASan and leak detection. Both compilers rejected the four compile-negative fixtures in debug and release.

The integrated h2spec v2.6.0 run passed 138 of 146 cases with zero skips. The live stream-window overflow case passed after the stream-level error handling change. The remaining eight cases are recorded here.

| Cases | Observed behavior |
| --- | --- |
| `generic/3.8.1`, `http2/7.1` | The probe sends PING immediately after peer GOAWAY and observes reciprocal GOAWAY while waiting for TCP close or PING ACK. The separate shutdown fixture verifies bilateral GOAWAY and EOF. |
| `http2/5.1.8`, `5.1.9`, `5.1.11`, `5.1.12` | DATA or HEADERS on a closed stream timed out while h2spec waited for an error. RFC 9113 §5.1 allows minimal processing and discarding of frames on closed streams, with valid minimal processing required for connection state. |
| `http2/5.1.1.2` | The probe reported DATA on the existing higher-numbered stream while waiting for a connection error. RFC 9113 §5.1.1 specifies that skipped lower IDs become closed. |
| `http2/5.3.1.2` | The provider ignores self-dependency in a PRIORITY frame. RFC 9113 deprecates the RFC 7540 dependency scheme. |

[RFC 9113 §5.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.1), [§5.1.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.1.1), [§5.3.2](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.3.2), [§6.8](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.8), [§6.9.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9.1).

The release gate remains open. Local measurements exceeded the DMD edited-build ceiling and the full template instance ceiling. The Linux baseline, million-reply GC and arena accounting, and head-to-head trials remain pending.
