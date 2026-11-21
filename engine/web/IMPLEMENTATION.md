# Web

`flint.web` registers explicit controllers and compiles the typed route adapters. The listener uses pinned llhttp for HTTP/1 and pinned nghttp2 for HTTP/2. Requests, captures, headers and response bodies use generation-checked arena handles. The server holds response storage until the final transport completion, and a scoped request cannot be retained by a handler.

HTTP/1 is the default. Set `ServerOptions.http2PriorKnowledge` for cleartext HTTP/2. Set both `tlsCertificateFile` and `tlsPrivateKeyFile` for a TLS listener. The TLS listener negotiates `h2` or `http/1.1` through the pinned OpenSSL provider, refuses incompatible ALPN offers and rejects an invalid PEM keypair at startup.

`Server.routeBatch` checks the entire batch before inserting any route. `Server.isLoopbackListener` admits a prepared listener bound to a numeric IPv4 loopback address or `::1`. Register a single `@ControllerAdvice` via `registerAdvice` or as an explicit application field. Advice receives a sanitized error and can provide its response body. The mapped status is determined by the original error.

`@WorkerController` opts a controller into full-D allocation and exception handling. Each registered controller has one dedicated worker and 16 request slots. A slot owns up to 4,096 bytes of request data and 4,096 bytes of response body, with space for up to 64 header fields and 16 captures. An oversized request receives 413. A raw worker response may provide a built-in JSON, plain-text, HTML or binary content type. Give a class-based worker controller exclusive ownership of its instance. A struct instance is copied at registration. Workers receive a retained cancellation token and run the normal binding and response adapters against an independent arena. A canceled job holds its slot until worker completion. Shutdown waits for the reactor and workers and returns a timeout if the supplied deadline expires first.

## Linux verification

The linked native tests passed under DMD and LDC with pinned providers. The socket fixture exercised HTTP/1 framing and bindings, advice, slow-receiver drainage, disconnect and detached worker cancellation, slot reuse, HTTP/2 multiplexing, flow credit, reset, stream caps and shutdown GOAWAY, trusted TLS negotiation for both HTTP versions, and the shutdown of 1,024 admitted requests. Independent C boundary tests ran with ASan, UBSan and leak detection. Their linked provider archives were built without sanitizer instrumentation. The LDC-native `:web` unit suite also passed ASan and leak detection. Both compilers rejected the four compile-negative fixtures in debug and release.

The full h2spec v2.6.0 run passed 137 of 146 cases with zero skips. The direct pinned C adapter control passed 129 of 146 cases, and reproduced all nine Flint failures. The control uses a simplified transport. Its additional failures provide no conclusion about the Flint listener.

| Cases | Observed behavior and follow-up |
| --- | --- |
| `generic/3.8.1`, `http2/7.1` | A peer GOAWAY followed immediately by a PING can reset the socket. Distinguish successful peer GOAWAY from local fatal termination. Drain to a bounded peer EOF or allow the provider to acknowledge the PING. |
| `http2/5.1.8`, `5.1.9`, `5.1.11`, `5.1.12` | DATA or HEADERS on a closed stream timed out in h2spec. RFC 9113 allows minimal processing of raced frames after RST_STREAM and retains error requirements for other closed-stream cases. Reproduce the orderly-close cases separately. |
| `http2/5.1.1.2` | The test observes DATA on the existing higher-numbered stream. Stream IDs are increasing, and skipped lower IDs become implicitly closed. Observe the connection verdict after the existing stream's DATA to resolve the expected outcome. |
| `http2/5.3.1.2` | The provider ignores self-dependency in a PRIORITY frame. RFC 9113 deprecates the RFC 7540 dependency scheme. |
| `http2/6.9.1.3` | A stream-window overflow closes the connection. RFC 9113 requires RST_STREAM with FLOW_CONTROL_ERROR for a live stream. Reproduce while the affected stream remains live and observe the provider's error callback. |

[RFC 9113 §5.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.1), [§5.1.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.1.1), [§5.3.2](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.3.2), [§6.7](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.7), [§6.9.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9.1).

The release gate remains open. Local measurements exceeded the DMD edited-build ceiling and the full template instance ceiling. The dedicated-runner baseline, million-reply GC and arena accounting, head-to-head trials and other target builds remain pending.
