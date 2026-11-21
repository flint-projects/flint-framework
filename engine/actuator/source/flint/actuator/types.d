module flint.actuator.types;

import flint.web : Request;

@safe:

/// Readiness of a named startup-registered dependency.
enum HealthStatus : ubyte
{
    up,
    down,
    unknown
}

/// Health probe outcome. Component details remain private by default.
struct Health
{
    /// Result of the dependency check.
    HealthStatus status;
    /// Stable component identifier.
    string component;
}

/// Application callback that observes its dependency without allocating.
alias HealthProbe = Health delegate() @safe nothrow @nogc;

/// Observations from the bounded OTLP export queue.
struct ExportStats
{
    /// Ended spans waiting for a response, including those already sent.
    uint pending;
    /// Count of spans discarded by overload, timeout or shutdown.
    ulong dropped;
    /// Count of points or spans a collector reported rejecting.
    ulong rejected;
}

/// Startup-issued counter identity.
struct Counter
{
    package(flint.actuator) uint id;
    package(flint.actuator) ulong owner;
}

/// Startup-issued histogram identity.
struct Histogram
{
    package(flint.actuator) uint id;
    package(flint.actuator) ulong owner;
}

/// Portable OpenTelemetry correlation, independent of request storage.
struct TraceContext
{
    /// Network-order trace identifier.
    ubyte[16] traceId;
    /// Network-order span identifier.
    ubyte[8] spanId;
    /// W3C trace flags carried by the task envelope.
    ubyte flags;
}

/// Application authorization for an attached management route.
alias ManagementPolicy = bool delegate(ref scope Request request) @safe nothrow @nogc;

/// Limits and destination for the management registry.
struct ActuatorOptions
{
    /// Absolute application path under which endpoints are registered.
    string pathPrefix = "/actuator";
    /// Hard upper bound on total metric series.
    uint maxMetricSeries = 4096;
    /// Total span slots, including those awaiting export.
    uint maxSpansQueued = 8192;
    /// Maximum spans in one exporter request.
    uint maxBatchSpans = 256;
    /// Base URL for the optional OTLP/HTTP destination.
    string otlpEndpoint;
    /// Monotonic interval between scheduled exports.
    long exportIntervalNanos = 5_000_000_000L;
    /// Number of owner-local metric cells per series.
    uint cores = 1;
    /// Stable OTLP resource service name.
    string serviceName = "flint";
    /// Optional policy used when an application shares its public listener.
    ManagementPolicy authorize;
}
