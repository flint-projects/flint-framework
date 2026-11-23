/// Bounded owner-fiber streaming over an admitted HTTP request.
module flint.engine.web.stream;

import flint.arena : Error, Result, Status;
import flint.conc : Context;
import flint.engine.web.types : Method, Request, RequestContext;

@safe:

/// Wire transport for a streaming route.
enum StreamMode : ubyte
{
    /// Incremental HTTP response bytes, with a completed request body.
    response,
    /// HTTP/1 protocol switch followed by raw bidirectional bytes.
    upgrade,
    /// HTTP/2 DATA in both directions, with independent request and response completion.
    duplex
}

/// A field copied before its transport call returns.
struct StreamField
{
    /// Lowercase ASCII field name.
    const(char)[] name;
    /// Field bytes without embedded CR, LF or NUL.
    const(char)[] value;
}

/// Called on the owning reactor fiber. The request and context are valid for the call.
// dfmt off
alias StreamHandler = Error delegate(ref scope Request, ref scope RequestContext,
        scope StreamToken) @safe nothrow @nogc;
// dfmt on

/// Explicit startup registration for a streaming action.
struct StreamRoute
{
    /// Exact method served by the route.
    Method method;
    /// Absolute route pattern using the server's ordinary path syntax.
    string path;
    /// Selected transport behavior.
    StreamMode mode;
    /// Owner-fiber handler.
    StreamHandler handler;
}

/// Generation-checked owner-fiber capability. A copied token cannot extend the stream lifetime.
struct StreamToken
{
    private StreamEndpoint endpoint;
    private ulong slot;
    private ulong generation;

    package(flint.engine.web) this(StreamEndpoint endpoint, ulong slot, ulong generation) nothrow @nogc
    {
        this.endpoint = endpoint;
        this.slot = slot;
        this.generation = generation;
    }

    /// Submit response headers. The transport copies or accepts all fields before returning.
    Error begin(ushort status, scope const(StreamField)[] fields, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.begin(slot, generation, status, fields, context);
    }

    /// Receive up to output.length bytes. A successful zero count means peer EOF.
    Result!size_t receive(scope ubyte[] output, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? Result!size_t(0, missing()) : endpoint.receive(slot, generation, output, context);
    }

    /// Resolve ownership of every byte before returning. The stream applies bounded backpressure.
    Error send(scope const(ubyte)[] bytes, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.send(slot, generation, bytes, context);
    }

    /// Finish local output, optionally sending HTTP/2 trailers.
    Error finish(scope const(StreamField)[] trailers, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.finish(slot, generation, trailers, context);
    }

    /// End the stream and make pending I/O observe cancellation.
    Error cancel() scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.cancel(slot, generation);
    }

    private static Error missing() pure nothrow @nogc
    {
        return Error(Status.invalidArgument, "empty web stream token");
    }
}

/// Owner-local lookup and I/O. Each implementation checks the reactor, slot and generation.
package(flint.engine.web) interface StreamEndpoint
{
@safe nothrow @nogc:

    Error begin(ulong slot, ulong generation, ushort status, scope const(StreamField)[] fields,
            ref scope const Context context) scope;
    Result!size_t receive(ulong slot, ulong generation, scope ubyte[] output, ref scope const Context context) scope;
    Error send(ulong slot, ulong generation, scope const(ubyte)[] bytes, ref scope const Context context) scope;
    Error finish(ulong, ulong, scope const(StreamField)[], ref scope const Context) scope;
    Error cancel(ulong slot, ulong generation) scope;
}

/// Return whether user fields can be sent without changing transport framing.
package(flint.engine.web) pure nothrow @nogc bool validStreamFields(scope const(StreamField)[] fields,
        bool permitUpgrade)
{
    enum maximumFields = 32;
    if (fields.length > maximumFields)
        return false;
    foreach (ref field; fields)
    {
        if (!validStreamField(field, permitUpgrade))
            return false;
    }
    return true;
}

private bool validStreamField(scope const ref StreamField field, bool permitUpgrade) pure nothrow @nogc
{
    const name = field.name;
    if (name.length == 0 || name.length > 128 || field.value.length > 4096)
        return false;
    if (transportField(name, permitUpgrade))
        return false;
    foreach (byteValue; name)
    {
        if (!tokenCharacter(byteValue))
            return false;
    }
    foreach (byteValue; field.value)
    {
        if ((byteValue < ' ' && byteValue != '\t') || byteValue == 0x7f)
            return false;
    }
    return true;
}

private bool transportField(scope const(char)[] name, bool permitUpgrade) pure nothrow @nogc
{
    static immutable string[] reserved = [
        "content-length", "transfer-encoding", "keep-alive", "proxy-connection"
    ];
    foreach (candidate; reserved)
    {
        if (name == candidate)
            return true;
    }
    return !permitUpgrade && (name == "connection" || name == "upgrade");
}

private bool tokenCharacter(char value) pure nothrow @nogc
{
    if ((value >= 'a' && value <= 'z') || (value >= '0' && value <= '9'))
        return true;
    foreach (candidate; "!#$%&'*+-.^`_|~")
    {
        if (value == candidate)
            return true;
    }
    return false;
}
