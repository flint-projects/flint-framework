# flint:engine-actuator

Open a registry at startup and register its counters, histogram boundaries and
readiness probes before serving requests. The registry uses bounded per-core
metric cells and merges each series during a Prometheus scrape. An invalid
histogram sample increments the invalid-sample counter. Each series reserves
its generated metric names when it registers.

Use `Registry.attach` on a prepared loopback listener or supply an explicit
management authorization callback for a shared listener. Liveness follows
the process. Readiness follows dependency health and turns off when draining
starts. An active readiness check cannot recursively invoke itself.

`beginSpan` returns a handle and a portable trace context. An application
can copy that context into a reactor task and an owned worker packet. Finish
each span on the supplied monotonic clock. Each registry admits up to 8,192
spans, including batches waiting for a collector response.

Set `ActuatorOptions.otlpEndpoint` to enable OTLP/HTTP JSON. The background
exporter uses separate bounded retry windows for metrics and traces, honors
Retry-After, and reports parsed partial-success rejections. The same batch is
retained until acknowledgement, expiry or shutdown. `exportStats` and the
scrape counters expose queue depth, drops and collector rejections. Closing
can return the final flush error after retiring the exporter.

On Linux, the retained fixtures exercise a real Collector, a 503 response with
Retry-After, malformed acknowledgements, concurrent scrapes, and trace
propagation through 100 interleaved fibers and worker round trips. A 600.033
second collector outage reached 8,192 queued spans, counted 14,991,617 drops
and served 598 liveness requests. The slowest sampled liveness request took
1.0932 milliseconds on that host.

The observation probe runs the same loopback HTTP transport in both variants
before timing counter and histogram updates. On the local glibc host, the
complete O3 binaries were 8,853,984 bytes for the feature and 8,793,952 for the
control. The Oz binaries were 8,813,024 and 8,765,280 bytes. The largest observed
wrapper delta was 60,032 bytes. Timed workers allocated zero D GC bytes.

[OTLP protocol](https://opentelemetry.io/docs/specs/otlp/)
