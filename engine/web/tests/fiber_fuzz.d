/++
A seeded fuzz of HTTP/1 request framing through a fiber route.

Each case sends random requests on one connection, pipelined and split into random fragments:
- methods, targets with percent escapes and queries, random fields;
- bodies framed by `Content-Length` or chunked, with random chunk sizes;
- `HEAD`, `Connection: close`, and HTTP/1.0.
The fiber handler echoes what it parsed and answers with `Content-Length` or with chunked output. Every response
must carry the right status, framing and echo. Malformed cases are mixed in:
- bad field lines, bare LF and NUL;
- invalid chunk sizes, duplicate or conflicting lengths;
- oversized heads, and a body short of its `Content-Length`.
Each must end in a 4xx or a closed connection, never a crash or a hung server. A clean request must still succeed
afterwards. The seed is fixed, so a failure reproduces; set `FLINT_FUZZ_SEED` and `FLINT_FUZZ_CASES` to explore.
+/
module flint.engine.web.fiber_fuzz;

import core.time : MonoTime, dur;
import flint.arena : Buffer, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.web.fiber : FiberResponse, FiberRoute, unknownLength;
import flint.engine.web.runtime : Server;
import flint.engine.web.stream : StreamField;
import flint.engine.web.types : Method, Request, RequestContext, ServerOptions;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;

@safe:

private string copyOut(ref scope RequestContext context, Result!Buffer buffer)
{
    if (!buffer.ok() || buffer.value.length() == 0)
        return "";
    auto text = new char[buffer.value.length()];
    context.arena.read(buffer.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        text[] = cast(const(char)[]) bytes;
    });
    return text.idup;
}

/// FNV-1a over the body, so the echo proves every body byte arrived in order.
private uint fnv(scope const(char)[] bytes) pure nothrow @nogc
{
    uint hash = 2_166_136_261u;
    foreach (b; bytes)
    {
        hash ^= b;
        hash *= 16_777_619u;
    }
    return hash;
}

private string hex(uint value) pure nothrow
{
    char[8] digits;
    foreach_reverse (ref d; digits)
    {
        d = "0123456789abcdef"[value & 15];
        value >>= 4;
    }
    return digits.idup;
}

private string decimal(size_t value) pure nothrow
{
    if (value == 0)
        return "0";
    char[20] digits;
    size_t first = digits.length;
    while (value != 0)
    {
        digits[--first] = cast(char)('0' + value % 10);
        value /= 10;
    }
    return digits[first .. $].idup;
}

private immutable string[7] methodNames = [
    "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"
];

/// The echo the handler sends for a request: what a correct parse must produce.
private string echoOf(string method, string target, scope const(char)[] content) pure nothrow
{
    return method ~ " " ~ target ~ " " ~ decimal(content.length) ~ " " ~ hex(fnv(content));
}

private final class Echo
{
    size_t served;

    void serve(ref scope Request request, ref scope RequestContext context, FiberResponse response)
    {
        ++served;
        const path = copyOut(context, request.path());
        const query = copyOut(context, request.query());
        const content = copyOut(context, request.body());
        const target = query.length != 0 ? path ~ "?" ~ query : path;
        const echo = echoOf(methodNames[request.method()], target, content);
        if (path == "/throw")
            throw new Exception("fuzzed handler failure");
        const StreamField[1] type = [StreamField("Content-Type", "text/plain")];
        if (path.length > 1 && path[1] == 'c')
        {
            // Chunked output in uneven pieces, as a committed servlet response writes it.
            if (response.begin(200, type[], unknownLength, context.cancellation).code != Status.ok)
                return;
            size_t at;
            size_t step = 1;
            while (at < echo.length)
            {
                const end = at + step < echo.length ? at + step : echo.length;
                if (response.send(cast(const(ubyte)[]) echo[at .. end], context.cancellation).code != Status.ok)
                    return;
                at = end;
                step = step * 3 + 1;
            }
            return;
        }
        response.respond(200, type[], cast(const(ubyte)[]) echo, false, context.cancellation);
    }
}

/// xorshift64*: deterministic across compilers and runs.
private struct Random
{
    ulong state;

    ulong next() pure nothrow @nogc
    {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 2_685_821_657_736_338_717UL;
    }

    size_t below(size_t bound) pure nothrow @nogc
    {
        return bound == 0 ? 0 : cast(size_t)(next() % bound);
    }

    bool chance(uint percent) pure nothrow @nogc
    {
        return below(100) < percent;
    }
}

/// One request on the wire and what its response must be.
private struct Planned
{
    string wire;
    string method;
    bool head;
    /// Expected echo, or null for a request the server must reject or that ends the connection.
    string echo;
    bool closes;
    bool chunkedReply;
}

private string token(ref Random random, size_t maximum)
{
    static immutable string alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    const length = 1 + random.below(maximum);
    auto text = new char[length];
    foreach (ref c; text)
        c = alphabet[random.below(alphabet.length)];
    return text.idup;
}

private string target(ref Random random, out string path)
{
    path = "/" ~ (random.chance(30) ? "c" : "p") ~ token(random, 6);
    foreach (_; 0 .. random.below(3))
        path ~= "/" ~ (random.chance(20) ? "%C3%A9" ~ token(random, 3) : token(random, 8));
    if (!random.chance(40))
        return path;
    string query;
    foreach (index; 0 .. 1 + random.below(3))
        query ~= (index != 0 ? "&" : "") ~ token(random, 5) ~ "=" ~ (random.chance(30) ? "a+b%20c" : token(random, 6));
    return path ~ "?" ~ query;
}

private string randomBody(ref Random random)
{
    const length = random.chance(20) ? 0 : random.below(3000);
    auto text = new char[length];
    foreach (ref c; text)
        c = cast(char)(' ' + random.below(95));
    return text.idup;
}

private string chunked(ref Random random, string content)
{
    string wire;
    size_t at;
    while (at < content.length)
    {
        const size = 1 + random.below(content.length - at < 700 ? content.length - at : 700);
        // Chunk sizes in lowercase hex, with leading zeros half the time.
        auto digits = hex(cast(uint) size);
        size_t first;
        while (first + 1 < digits.length && digits[first] == '0' && !random.chance(50))
            ++first;
        wire ~= digits[first .. $] ~ "\r\n" ~ content[at .. at + size] ~ "\r\n";
        at += size;
    }
    return wire ~ "0\r\n\r\n";
}

private Planned valid(ref Random random, bool last)
{
    Planned plan;
    string path;
    const wireTarget = target(random, path);
    const index = random.below(methodNames.length);
    plan.method = methodNames[index];
    plan.head = plan.method == "HEAD";
    const carriesBody = plan.method == "POST" || plan.method == "PUT" || plan.method == "PATCH";
    const content = carriesBody ? randomBody(random) : "";
    const useChunked = carriesBody && random.chance(40);
    string head = plan.method ~ " " ~ wireTarget ~ " HTTP/1.1\r\nHost: fuzz\r\n";
    foreach (_; 0 .. random.below(6))
        head ~= "X-" ~ token(random, 10) ~ ": " ~ token(random, 30) ~ "\r\n";
    if (carriesBody)
        head ~= useChunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: " ~ decimal(content.length) ~ "\r\n";
    plan.closes = last && random.chance(50);
    if (plan.closes)
        head ~= "Connection: close\r\n";
    else if (random.chance(20))
        head ~= "Connection: keep-alive\r\n";
    plan.wire = head ~ "\r\n" ~ (useChunked ? chunked(random, content) : content);
    plan.echo = echoOf(plan.method, wireTarget, content);
    plan.chunkedReply = path[1] == 'c';
    return plan;
}

/// A request the server must refuse with a 4xx or by closing; it always ends its connection.
private Planned malformed(ref Random random)
{
    static immutable string[] cases = [
        "GET / HTTP/1.1\r\nHost: fuzz\r\nBad Field: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: fuzz\nX-Bare: lf\r\n\r\n", "GET / HTTP/1.1\r\nHost: fu\x00zz\r\n\r\n",
        "POST /p HTTP/1.1\r\nHost: fuzz\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n",
        "POST /p HTTP/1.1\r\nHost: fuzz\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
        "POST /p HTTP/1.1\r\nHost: fuzz\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n"
        ~ "3\r\nabc\r\n0\r\n\r\n", "GET / HTTP/9.9\r\nHost: fuzz\r\n\r\n", "GET /p HTTP/1.1\r\n\r\n",
        "BREW /pot HTTP/1.1\r\nHost: fuzz\r\n\r\n",
        "POST /p HTTP/1.1\r\nHost: fuzz\r\nContent-Length: -1\r\n\r\n",
    ];
    Planned plan;
    plan.closes = true;
    if (random.chance(15))
    {
        // A head larger than the 16 KiB limit.
        string big = "GET /p HTTP/1.1\r\nHost: fuzz\r\nX-Big: ";
        foreach (_; 0 .. 20_000)
            big ~= 'a';
        plan.wire = big ~ "\r\n\r\n";
    }
    else if (random.chance(15)) // The client hangs up five bytes short of its declared body.
        plan.wire = "POST /p HTTP/1.1\r\nHost: fuzz\r\nContent-Length: 10\r\n\r\n01234";
    else
        plan.wire = cases[random.below(cases.length)];
    return plan;
}

private bool interrupted() @trusted
{
    import core.stdc.errno : EINTR, errno;

    return errno == EINTR;
}

private ptrdiff_t find(scope const(char)[] text, scope const(char)[] needle, size_t from = 0)
{
    foreach (index; from .. text.length >= needle.length ? text.length - needle.length + 1 : from)
        if (text[index .. index + needle.length] == needle)
            return index;
    return -1;
}

/// Reads responses off one connection, buffering across them.
private struct Reader
{
    Socket socket;
    char[] pending;
    bool closed;

    bool fill()
    {
        char[8192] chunk;
        for (;;)
        {
            const count = socket.receive(chunk[]);
            if (count == Socket.ERROR && interrupted())
                continue;
            if (count <= 0)
            {
                closed = true;
                return false;
            }
            pending ~= chunk[0 .. count];
            return true;
        }
    }

    /// A chunked body off the stream, decoded.
    string dechunked()
    {
        string content;
        for (;;)
        {
            const line = find(pending, "\r\n");
            if (line < 0)
            {
                assert(fill(), "connection closed inside a chunked body");
                continue;
            }
            size_t size;
            foreach (c; pending[0 .. line])
                size = size * 16 + (c <= '9' ? c - '0' : c - 'a' + 10);
            while (pending.length < line + 2 + size + 2)
                assert(fill(), "connection closed inside a chunk");
            content ~= pending[line + 2 .. line + 2 + size];
            pending = pending[line + 2 + size + 2 .. $];
            if (size == 0)
                return content;
        }
    }

    /// A body of the length that `digits` starts with.
    string fixed(scope const(char)[] digits)
    {
        size_t length;
        foreach (c; digits)
        {
            if (c < '0' || c > '9')
                break;
            length = length * 10 + (c - '0');
        }
        while (pending.length < length)
            assert(fill(), "connection closed inside a Content-Length body");
        auto content = pending[0 .. length].idup;
        pending = pending[length .. $];
        return content;
    }

    /// One response: its status line and decoded body. Null status when the connection closed first.
    string next(bool head, out string content)
    {
        const deadline = MonoTime.currTime + dur!"seconds"(10);
        ptrdiff_t end;
        while ((end = find(pending, "\r\n\r\n")) < 0)
        {
            assert(MonoTime.currTime < deadline, "response head timed out");
            if (!fill())
                return null;
        }
        const headText = pending[0 .. end + 4].idup;
        pending = pending[end + 4 .. $];
        const lengthAt = find(headText, "\r\nContent-Length: ");
        if (head)
            return headText;
        if (find(headText, "\r\nTransfer-Encoding: chunked\r\n") >= 0)
        {
            content = dechunked();
            return headText;
        }
        if (lengthAt >= 0)
        {
            content = fixed(headText[lengthAt + 18 .. $]);
            return headText;
        }
        while (fill())
        {
        }
        content = pending.idup;
        pending = null;
        return headText;
    }
}

private void sendFragments(Socket socket, string wire, ref Random random)
{
    const(ubyte)[] bytes = cast(const(ubyte)[]) wire;
    while (bytes.length != 0)
    {
        const piece = 1 + random.below(bytes.length < 1500 ? bytes.length : 1500);
        auto part = bytes[0 .. piece];
        while (part.length != 0)
        {
            const sent = socket.send(part);
            if (sent == Socket.ERROR && interrupted())
                continue;
            if (sent <= 0)
                return; // the server closed after rejecting a malformed request
            part = part[sent .. $];
        }
        bytes = bytes[piece .. $];
    }
}

private ulong environmentNumber(string name, ulong fallback) @trusted
{
    import std.process : environment;
    import std.conv : to;

    const text = environment.get(name);
    return text is null ? fallback : text.to!ulong;
}

/// One fuzz case: a connection, its pipelined plans in random fragments, and every response checked.
private void runCase(ushort port, ref Random random, ref size_t validResponses, ref size_t rejected)
{
    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", port));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(5_000));
    scope (exit)
        socket.close();
    Planned[] plans;
    const count = 1 + random.below(5);
    foreach (index; 0 .. count)
        plans ~= valid(random, index + 1 == count);
    if (random.chance(25))
        plans[$ - 1] = malformed(random);
    else if (random.chance(10))
        plans[$ - 1] = Planned("GET /throw HTTP/1.1\r\nHost: fuzz\r\n\r\n", "GET", false, null, true);
    string wire;
    foreach (ref plan; plans)
        wire ~= plan.wire;
    sendFragments(socket, wire, random);
    // After a malformed request the client is done; its EOF ends a body the server is still waiting for.
    if (plans[$ - 1].echo is null)
        socket.shutdown(SocketShutdown.SEND);
    auto reader = Reader(socket);
    checkResponses(reader, plans, validResponses, rejected);
}

/// Check each plan's response in order; a rejected plan ends the connection.
private void checkResponses(ref Reader reader, Planned[] plans, ref size_t validResponses, ref size_t rejected)
{
    foreach (ref plan; plans)
    {
        string content;
        const head = reader.next(plan.head, content);
        if (plan.echo is null)
        {
            // Rejected: a 4xx or 5xx, or a closed connection; then nothing more on this connection.
            assert(head is null || head[0 .. 10] == "HTTP/1.1 4" || head[0 .. 10] == "HTTP/1.1 5"
                    || head[0 .. 10] == "HTTP/1.0 4", head);
            ++rejected;
            break;
        }
        assert(head !is null, "connection closed before a valid response: " ~ plan.wire[0 .. plan.wire.length < 40
            ? $ : 40]);
        assert(head[0 .. 15] == "HTTP/1.1 200 \r\n", head);
        assert((find(head, "Transfer-Encoding: chunked") >= 0) == plan.chunkedReply, head);
        if (!plan.head)
            assert(content == plan.echo, content ~ " != " ~ plan.echo);
        assert((find(head, "Connection: close") >= 0) == plan.closes, head);
        ++validResponses;
    }
}

@("fiber routes keep HTTP/1 framing intact under a seeded fuzz of valid, pipelined and malformed requests")
unittest
{
    ServerOptions options;
    options.port = 0;
    options.cores = 1;
    options.maxConnectionsPerCore = 64;
    options.http2 = false;
    options.idleTimeoutNanos = 10_000_000_000L;
    Server server;
    assert(server.start(options).code == Status.ok);
    auto echo = new Echo;
    assert(server.routeFiber(FiberRoute(&echo.serve)).code == Status.ok);
    const port = server.listenPort();
    Context context;
    assert(server.poll(context).code == Status.ok);
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);

    auto random = Random(environmentNumber("FLINT_FUZZ_SEED", 0x5eed_f1b3_2026_1123UL));
    const cases = environmentNumber("FLINT_FUZZ_CASES", 120);
    size_t validResponses, rejected;
    foreach (_; 0 .. cases)
        runCase(port, random, validResponses, rejected);
    assert(validResponses >= cases && rejected != 0);

    // The server is still healthy.
    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", port));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(5_000));
    scope (exit)
        socket.close();
    sendFragments(socket, "GET /final HTTP/1.1\r\nHost: fuzz\r\n\r\n", random);
    auto reader = Reader(socket);
    string content;
    const head = reader.next(false, content);
    assert(head !is null && content == echoOf("GET", "/final", ""), content);
}
