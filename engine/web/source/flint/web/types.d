/// REST annotations and checked request/response handles.
module flint.web.types;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.web.worker_packet : WorkerRequest;

@safe:

/// Type annotation supplying a controller's path prefix.
struct RestController
{
    /// Absolute base route, or empty for the application root.
    string path;
}

/// Additional controller or action path prefix.
struct RequestMapping
{
    /// Path suffix applied within the explicit controller registry.
    string path;
}

/// Register a GET action.
struct Get
{
    /// Path relative to the controller.
    string path;
}

/// Register a POST action.
struct Post
{
    /// Path relative to the controller.
    string path;
}

/// Register a PUT action.
struct Put
{
    /// Path relative to the controller.
    string path;
}

/// Register a DELETE action.
struct Delete
{
    /// Path relative to the controller.
    string path;
}

/// Bind one positional path segment by name.
struct PathVariable
{
    /// Name used in the registered path pattern.
    string name;
}

/// Bind one decoded query argument by name.
struct QueryParam
{
    /// Query key.
    string name;
    /// Reject omission when true.
    bool required = false;
}

/// Bind a JSON request body.
struct RequestBody
{
}

/// Customize an application's public error response.
struct ControllerAdvice
{
}

/// Include a fixed major version in the generated route policy.
struct ApiVersion
{
    /// Application major version.
    uint major;
}

/// Opt this controller into bounded full-D worker execution.
struct WorkerController
{
}

/// HTTP methods recognized by the public route API.
enum Method : ubyte
{
    /// Retrieve a representation.
    get,
    /// Submit an entity.
    post,
    /// Replace an entity.
    put,
    /// Partially modify an entity.
    patch,
    /// Remove an entity.
    delete_,
    /// Retrieve response metadata without a body.
    head,
    /// Retrieve communication options.
    options
}

/// Listener and per-connection resource ceilings.
struct ServerOptions
{
    /// Bind address.
    string address = "127.0.0.1";
    /// TCP port. Zero requests an ephemeral port.
    ushort port = 8080;
    /// Number of HTTP reactor workers.
    uint cores = 1;
    /// Maximum active connection records per worker.
    uint maxConnectionsPerCore = 4096;
    /// Maximum admitted HTTP/2 streams per connection.
    uint maxStreamsPerConnection = 100;
    /// Combined request line and field byte limit.
    size_t maxHeaderBytes = 16_384;
    /// Largest nonstreamed request body.
    size_t maxBodyBytes = 1_048_576;
    /// Maximum queued response body bytes per connection.
    size_t writeQueueBytes = 262_144;
    /// Time permitted to receive request headers, measured monotonically.
    long headerTimeoutNanos = 5_000_000_000L;
    /// Time permitted without connection activity, measured monotonically.
    long idleTimeoutNanos = 30_000_000_000L;
    /// Advertise HTTP/2 when negotiating a supported encrypted profile.
    bool http2 = true;
    /// Require the HTTP/2 preface on this explicit cleartext listener.
    bool http2PriorKnowledge = false;

    /// PEM certificate chain file for a TLS listener.
    string tlsCertificateFile;
    /// PEM private key file matching the TLS certificate chain.
    string tlsPrivateKeyFile;

}

/// Per-request lifetime and cancellation passed to a controller.
struct RequestContext
{
    /// Region retained through the final socket operation.
    RequestArena arena;
    /// Token cancelled on disconnect or shutdown.
    Context cancellation;
    /// Application correlation identity.
    ulong requestId;
}

package(flint.web) enum maximumFields = 64;
package(flint.web) enum maximumCaptures = 16;

package(flint.web) struct Capture
{
    string name;
    uint start;
    uint end;
}

package(flint.web) struct HeaderRecord
{
    uint start;
    uint end;
    Buffer value;
}

package(flint.web) struct RequestMetadata
{
    ulong generation;
    bool valid;
    Method method;
    Buffer path;
    Buffer query;
    Buffer body;
    ubyte[] names;
    HeaderRecord[maximumFields] headers;
    size_t fieldCount;

    void reset() nothrow @nogc
    {
        valid = false;
        fieldCount = 0;
        path = Buffer.init;
        query = Buffer.init;
        body = Buffer.init;
    }
}

/// Checked request handle. Copying it does not retain its request generation.
struct Request
{
    private RequestMetadata* state;
    private ulong generation;
    private Capture[maximumCaptures] captures;
    private size_t captureCount;

    private this(return scope RequestMetadata* source) nothrow @nogc
    {
        state = source;
        generation = source.generation;
    }

    package(flint.web) static Request fromMetadata(return scope RequestMetadata* source) nothrow @nogc
    {
        return Request(source);
    }

    package(flint.web) void setCaptures(scope const(Capture)[] values) scope nothrow @nogc
    {
        captures[0 .. values.length] = values;
        captureCount = values.length;
    }

    package(flint.web) Result!Capture capture(scope const(char)[] name) const scope nothrow @nogc
    {
        if (live())
        {
            foreach (ref value; captures[0 .. captureCount])
            {
                if (value.name == name)
                    return Result!Capture(value);
            }
        }
        return Result!Capture(Capture.init, Error(Status.notFound, "HTTP path capture is absent"));
    }

    package(flint.web)
    {
        bool makePacket(ref scope RequestContext context, ref WorkerRequest packet) const scope nothrow @nogc
        {
            if (!live())
                return false;
            packet.identity = context.requestId;
            packet.method = cast(ubyte) state.method;
            packet.fields = 0;
            packet.captureCount = 0;
            packet.used = 0;
            if (!packet.appendBuffer(state.path, context.arena, packet.path)
                    || !packet.appendBuffer(state.query, context.arena, packet.query)
                    || !packet.appendBuffer(state.body, context.arena, packet.body))
                return false;
            return copyHeaders(context.arena, packet) && copyCaptures(packet);
        }
    }

    private bool copyHeaders(ref scope RequestArena arena, ref WorkerRequest packet) const scope nothrow @nogc
    {
        foreach (ref field; state.headers[0 .. state.fieldCount])
        {
            ref destination = packet.headers[packet.fields];
            if (!packet.appendBytes(state.names[field.start .. field.end], destination.name)
                    || !packet.appendBuffer(field.value, arena, destination.value))
                return false;
            ++packet.fields;
        }
        return true;
    }

    private bool copyCaptures(ref WorkerRequest packet) const scope nothrow @nogc
    {
        foreach (ref capture; captures[0 .. captureCount])
        {
            ref destination = packet.captures[packet.captureCount];
            if (!packet.appendBytes(cast(const(ubyte)[]) capture.name, destination.name))
                return false;
            destination.first = capture.start;
            destination.last = capture.end;
            ++packet.captureCount;
        }
        return true;
    }

    private bool live() const scope nothrow @nogc
    {
        return state !is null && state.valid && generation == state.generation;
    }

    /// HTTP method. An invalidated handle has the default enum ordinal.
    Method method() const scope nothrow @nogc
    {
        return live() ? state.method : Method.init;
    }

    /// Target path, excluding any query string.
    Result!Buffer path() const scope nothrow @nogc
    {
        return live() ? Result!Buffer(state.path) : Result!Buffer(Buffer.init,
                Error(Status.invalidArgument, "expired HTTP request"));
    }

    /// First matching field, compared using ASCII case-insensitive names.
    Result!Buffer header(scope const(char)[] name) const scope nothrow @nogc
    {
        if (!live())
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "expired HTTP request"));
        foreach (ref field; state.headers[0 .. state.fieldCount])
        {
            if (sameName(state.names[field.start .. field.end], name))
                return Result!Buffer(field.value);
        }
        return Result!Buffer(Buffer.init, Error(Status.notFound, "HTTP field is absent"));
    }

    /// Dechunked body in the enclosing request arena.
    Result!Buffer body() const scope nothrow @nogc
    {
        return live() ? Result!Buffer(state.body) : Result!Buffer(Buffer.init,
                Error(Status.invalidArgument, "expired HTTP request"));
    }

    package(flint.web) Result!Buffer query() const scope nothrow @nogc
    {
        return live() ? Result!Buffer(state.query) : Result!Buffer(Buffer.init,
                Error(Status.invalidArgument, "expired HTTP request"));
    }
}

/// Response whose body must belong to the current request arena.
struct Response
{
    /// HTTP status code.
    ushort status = 200;
    /// Media type supplied by the handler.
    string contentType = "application/json";
    /// Body handle valid through the final successful or cancelled write.
    Buffer body;
}

/// Checked owner-loop request action.
alias Handler = Result!Response delegate(ref scope Request, ref scope RequestContext) @safe nothrow @nogc;

package(flint.web) alias ErrorAdvice = Response delegate(Error, ref scope RequestContext) @safe nothrow @nogc;

/// One startup route and its owned handler for atomic batch registration.
struct RouteRegistration
{
    /// HTTP request method.
    Method method;
    /// Absolute path pattern.
    string path;
    /// Owner-loop handler retained by the server.
    Handler handler;
}

package(flint.web) ubyte lower(ubyte value) pure nothrow @nogc
{
    return value >= 'A' && value <= 'Z' ? cast(ubyte)(value + ('a' - 'A')) : value;
}

package(flint.web) bool sameName(scope const(ubyte)[] bytes, scope const(char)[] name) pure nothrow @nogc
{
    if (bytes.length != name.length)
        return false;
    foreach (index, value; bytes)
    {
        if (lower(value) != lower(cast(ubyte) name[index]))
            return false;
    }
    return true;
}
