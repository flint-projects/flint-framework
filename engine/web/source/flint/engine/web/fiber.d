/// Fiber routes: full-D handlers on the request's reactor fiber, with servlet-container framing.
module flint.engine.web.fiber;

import flint.arena : Error, Status;
import flint.conc : Context;
import flint.engine.web.stream : StreamField;
import flint.engine.web.types : Request, RequestContext;

@safe:

/++
A fiber route's handler, called on the request's reactor fiber (ADR-030 section 4).

Unlike owner-loop and stream handlers, it may allocate from the GC, throw, and suspend through `TaskWaker`, as a
servlet does on a virtual thread. The request, its arena and the context are valid for the call only: copy what
must outlive it into GC memory, and never hand arena memory to user code. When an `Exception` escapes, the
engine answers 500 if no response has begun and otherwise closes the connection.
+/
alias FiberHandler = void delegate(ref scope Request, ref scope RequestContext, FiberResponse) @safe;

/// Explicit startup registration of a fiber route. It serves every request, of any method and target, that no
/// owner-loop or stream route serves, as a servlet container's default mapping (`/`) does.
struct FiberRoute
{
    /// The handler run on each request's fiber.
    FiberHandler handler;
}

/// The `contentLength` of a response whose length is not known when it begins: HTTP/1.1 frames it as chunked,
/// and HTTP/1.0 delimits it by closing the connection.
enum long unknownLength = -1;

/++
Generation-checked capability for one fiber route's response. It holds no request storage, so a servlet
response object may keep it to commit on `flushBuffer`; a copy used after its request ended, or from another
task, fails with `unavailable` instead of reaching the next request. The engine owns the framing fields (`Content-Length`, `Transfer-Encoding`, `Connection`,
`Keep-Alive`) and writes them as an embedded Tomcat does:
- the status line has no reason phrase (`HTTP/1.1 200 `);
- the application's fields come first, in the order given, then the framing field, `Date` (unless given) and
  the connection fields;
- 1xx, 204 and 304 carry no framing field, and 205 carries `Content-Length: 0`;
- a HEAD response keeps its framing fields and sends no body bytes;
- `Connection: close` is sent when the connection will close, and `Keep-Alive: timeout=N` with
  `Connection: keep-alive` only when the request asked for keep-alive by name.
+/
struct FiberResponse
{
    private FiberEndpoint endpoint;
    private ulong slot;
    private ulong generation;

    package(flint.engine.web) this(FiberEndpoint endpoint, ulong slot, ulong generation) nothrow @nogc
    {
        this.endpoint = endpoint;
        this.slot = slot;
        this.generation = generation;
    }

    /// Send the status and fields. `contentLength` is the exact body length, or `unknownLength`. The transport
    /// copies every field before it returns.
    // dfmt off
    Error begin(ushort status, scope const(StreamField)[] fields, long contentLength,
            ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.fiberBegin(slot, generation, status, fields,
                contentLength, context);
    }
    // dfmt on

    /// Send body bytes, framed as `begin` chose. Every byte's ownership is resolved before it returns.
    Error send(scope const(ubyte)[] bytes, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.fiberSend(slot, generation, bytes, context);
    }

    /// End the body. A fixed-length body must be complete. The connection then serves its next request.
    Error finish(ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.fiberFinish(slot, generation, context);
    }

    /// Send a whole response: fields and body in as few writes as fit, framed by `Content-Length` or, when
    /// `chunked` is set, as one chunk and the last chunk.
    Error respond(ushort status, scope const(StreamField)[] fields, scope const(ubyte)[] payload,
            bool chunked, ref scope const Context context) scope nothrow @nogc
    {
        return endpoint is null ? missing() : endpoint.fiberRespond(slot, generation, status,
                fields, payload, chunked, context);
    }

    /// Whether the status line has been sent: after that the response can no longer change status or fields.
    bool started() scope nothrow @nogc
    {
        return endpoint !is null && endpoint.fiberStarted(slot, generation);
    }

    private static Error missing() pure nothrow @nogc
    {
        return Error(Status.invalidArgument, "empty fiber response token");
    }
}

/// Owner-local response I/O. Each implementation checks the reactor, slot, generation and running task.
package(flint.engine.web) interface FiberEndpoint
{
@safe nothrow @nogc:

    Error fiberBegin(ulong slot, ulong generation, ushort status, scope const(StreamField)[] fields,
            long contentLength, ref scope const Context context) scope;
    Error fiberSend(ulong slot, ulong generation, scope const(ubyte)[] bytes, ref scope const Context context) scope;
    Error fiberFinish(ulong slot, ulong generation, ref scope const Context context) scope;
    Error fiberRespond(ulong slot, ulong generation, ushort status, scope const(StreamField)[] fields,
            scope const(ubyte)[] payload, bool chunked, ref scope const Context context) scope;
    bool fiberStarted(ulong slot, ulong generation) scope;
}

/// Return whether application fields can be written beside the engine's framing. Names are tokens in any case
/// (Tomcat writes `Content-Type`), values carry no CR, LF, NUL or other control byte except tab, and the
/// framing and hop-by-hop fields belong to the engine.
package(flint.engine.web) bool validFiberFields(scope const(StreamField)[] fields) pure nothrow @nogc
{
    enum maximumFields = 64;
    if (fields.length > maximumFields)
        return false;
    foreach (ref field; fields)
    {
        if (field.name.length == 0 || field.name.length > 128 || field.value.length > 8192)
            return false;
        foreach (character; field.name)
            if (!tokenCharacter(character))
                return false;
        foreach (character; field.value)
            if ((character < ' ' && character != '\t') || character == 0x7f)
                return false;
        if (engineField(field.name))
            return false;
    }
    return true;
}

private bool engineField(scope const(char)[] name) pure nothrow @nogc
{
    static immutable string[] reserved = [
        "content-length", "transfer-encoding", "connection", "keep-alive", "proxy-connection",
        "upgrade"
    ];
    foreach (candidate; reserved)
        if (equalsLower(name, candidate))
            return true;
    return false;
}

/// ASCII case-insensitive comparison against a lowercase name.
package(flint.engine.web) bool equalsLower(scope const(char)[] name, scope const(char)[] lowercase) pure nothrow @nogc
{
    if (name.length != lowercase.length)
        return false;
    foreach (index, character; name)
    {
        const folded = character >= 'A' && character <= 'Z' ? cast(char)(character + 32) : character;
        if (folded != lowercase[index])
            return false;
    }
    return true;
}

/// Whether a comma-separated field value such as `Connection: Keep-Alive, Upgrade` lists `token` (lowercase),
/// ignoring case and optional whitespace.
// dfmt off
package(flint.engine.web) bool hasConnectionToken(scope const(char)[] value, scope const(char)[] token)
        pure nothrow @nogc
{
    size_t start;
    foreach (end; 0 .. value.length + 1)
    {
        if (end != value.length && value[end] != ',')
            continue;
        size_t first = start, last = end;
        while (first < last && (value[first] == ' ' || value[first] == '\t'))
            ++first;
        while (last > first && (value[last - 1] == ' ' || value[last - 1] == '\t'))
            --last;
        if (equalsLower(value[first .. last], token))
            return true;
        start = end + 1;
    }
    return false;
}
// dfmt on

private bool tokenCharacter(char value) pure nothrow @nogc
{
    if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9'))
        return true;
    foreach (candidate; "!#$%&'*+-.^`_|~")
        if (value == candidate)
            return true;
    return false;
}

@("fiber fields accept mixed-case tokens and reject framing, hop-by-hop and malformed fields")
unittest
{
    const StreamField[2] typed = [
        StreamField("Content-Type", "application/json"), StreamField("Accept-Patch", "")
    ];
    assert(validFiberFields(typed[]));
    const StreamField[2] varied = [
        StreamField("Vary", "Origin"), StreamField("Vary", "Access-Control-Request-Method")
    ];
    assert(validFiberFields(varied[]));
    assert(!validFiberFields([StreamField("Content-Length", "3")]));
    assert(!validFiberFields([StreamField("transfer-encoding", "chunked")]));
    assert(!validFiberFields([StreamField("Connection", "close")]));
    assert(!validFiberFields([StreamField("Keep-Alive", "timeout=5")]));
    assert(!validFiberFields([StreamField("X-Bad Name", "v")]));
    assert(!validFiberFields([StreamField("X-Split", "a\r\nInjected: yes")]));
    assert(!validFiberFields([StreamField("", "v")]));
    StreamField[65] many = StreamField("X-A", "b");
    assert(!validFiberFields(many[]));
}

@("Connection tokens match without regard to case or whitespace")
unittest
{
    assert(hasConnectionToken("keep-alive", "keep-alive"));
    assert(hasConnectionToken("Upgrade, Keep-Alive", "keep-alive"));
    assert(hasConnectionToken(" \tKEEP-ALIVE\t ", "keep-alive"));
    assert(!hasConnectionToken("close", "keep-alive"));
    assert(!hasConnectionToken("keep-alive-ish", "keep-alive"));
    assert(!hasConnectionToken("", "keep-alive"));
}
