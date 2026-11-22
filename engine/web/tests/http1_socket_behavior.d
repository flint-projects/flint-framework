module flint.web.http1_socket_behavior;

import core.time : Duration, MonoTime, dur;
import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.web.runtime : Server;
import flint.web.stream : StreamField, StreamMode, StreamRoute, StreamToken;
import flint.web.types : Method, Request, RequestContext, Response, ServerOptions;
import std.socket : InternetAddress, Socket, SocketOptionLevel, SocketOption, SocketShutdown, TcpSocket;

@safe:

private enum largeBytes = 100_000;
private enum streamBytes = 4 * 1024 * 1024;

private final class Routes
{
    Result!Response large(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        auto block = context.arena.allocate(largeBytes, 1);
        if (!block.ok())
            return Result!Response(Response.init, block.error);
        const filled = context.arena.write(block.value, (scope ubyte[] bytes) @safe nothrow @nogc {
            foreach (index, ref value; bytes)
                value = cast(ubyte)('a' + index % 23);
        });
        if (filled != Status.ok)
            return Result!Response(Response.init, Error(filled, "unable to fill test body"));
        return Result!Response(Response(200, "text/plain", block.value));
    }

    Result!Response echo(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        const 
        body = request.body();
        if (!body.ok())
            return Result!Response(Response.init, body.error);
        return Result!Response(Response(200, "text/plain", body.value));
    }

    Result!Response empty(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return Result!Response(Response(204, null, Buffer.init));
    }

    Error stream(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        const begun = token.begin(200, null, context.cancellation);
        if (begun.code != Status.ok)
            return begun;
        ubyte[16_384] block = 'x';
        foreach (_; 0 .. streamBytes / block.length)
        {
            const sent = token.send(block[], context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
        return token.finish(null, context.cancellation);
    }

    Error echo(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        const StreamField[2] fields = [
            StreamField("connection", "upgrade"), StreamField("upgrade", "flint-echo")
        ];
        const begun = token.begin(101, fields[], context.cancellation);
        if (begun.code != Status.ok)
            return begun;
        ubyte[256] buffer;
        for (;;)
        {
            const received = token.receive(buffer[], context.cancellation);
            if (!received.ok())
                return received.error;
            if (received.value == 0)
                return Error.init;
            const sent = token.send(buffer[0 .. received.value], context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
    }
}

private struct Fixture
{
    Server server;
    ushort port;

    void open()
    {
        ServerOptions options;
        options.port = 0;
        options.cores = 1;
        options.maxConnectionsPerCore = 16;
        options.http2 = false;
        assert(server.start(options).code == Status.ok);
        auto routes = new Routes;
        assert(server.route(Method.get, "/large", &routes.large).code == Status.ok);
        assert(server.route(Method.post, "/echo", &routes.echo).code == Status.ok);
        assert(server.route(Method.get, "/empty", &routes.empty).code == Status.ok);
        const streamed = StreamRoute(Method.get, "/stream", StreamMode.response, &routes.stream);
        assert(server.routeStream(streamed).code == Status.ok);
        const echoed = StreamRoute(Method.get, "/echo", StreamMode.upgrade, &routes.echo);
        assert(server.routeStream(echoed).code == Status.ok);
        port = server.listenPort();
        assert(port != 0);
        Context context;
        assert(server.poll(context).code == Status.ok);
    }

    void close()
    {
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }

    Socket connect()
    {
        auto socket = new TcpSocket(new InternetAddress("127.0.0.1", port));
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(3_000));
        return socket;
    }
}

private bool interrupted() @trusted
{
    import core.stdc.errno : EINTR, errno;

    return errno == EINTR;
}

/// Receive, retrying when a druntime GC signal interrupts the blocking call.
private ptrdiff_t receiveSome(Socket socket, scope void[] buffer)
{
    for (;;)
    {
        const count = socket.receive(buffer);
        if (count != Socket.ERROR || !interrupted())
            return count;
    }
}

private void sendAll(Socket socket, scope const(char)[] text)
{
    const(ubyte)[] bytes = cast(const(ubyte)[]) text;
    while (bytes.length != 0)
    {
        const sent = socket.send(bytes);
        if (sent == Socket.ERROR && interrupted())
            continue;
        assert(sent > 0);
        bytes = bytes[sent .. $];
    }
}

/// Read until EOF, a receive timeout, or the deadline.
private ubyte[] readUntilClosed(Socket socket)
{
    ubyte[] received;
    ubyte[8192] chunk;
    const deadline = MonoTime.currTime + dur!"seconds"(5);
    while (MonoTime.currTime < deadline)
    {
        const count = receiveSome(socket, chunk[]);
        if (count <= 0)
            break;
        received ~= chunk[0 .. count];
    }
    return received;
}

/// Read until the response head and its Content-Length body are complete, keeping any suffix.
private string readResponse(Socket socket, ref char[] received, out string head)
{
    char[4096] chunk;
    const deadline = MonoTime.currTime + dur!"seconds"(5);
    while (MonoTime.currTime < deadline)
    {
        for (size_t index; index + 4 <= received.length; ++index)
        {
            if (received[index .. index + 4] != "\r\n\r\n")
                continue;
            const length = contentLength(received[0 .. index + 4].idup);
            if (received.length < index + 4 + length)
                break;
            head = received[0 .. index + 4].idup;
            const 
            body = received[index + 4 .. index + 4 + length].idup;
            received = received[index + 4 + length .. $].dup;
            return
            body;
        }
        const count = receiveSome(socket, chunk[]);
        if (count <= 0)
            break;
        received ~= chunk[0 .. count];
    }
    head = received.idup;
    return null;
}

private size_t contentLength(string head)
{
    enum field = "\r\nContent-Length: ";
    foreach (index; 0 .. head.length >= field.length ? head.length - field.length + 1 : 0)
    {
        if (head[index .. index + field.length] != field)
            continue;
        size_t value;
        foreach (character; head[index + field.length .. $])
        {
            if (character < '0' || character > '9')
                break;
            value = value * 10 + (character - '0');
        }
        return value;
    }
    return 0;
}

private bool contains(scope const(char)[] text, scope const(char)[] needle)
{
    foreach (index; 0 .. text.length >= needle.length ? text.length - needle.length + 1 : 0)
        if (text[index .. index + needle.length] == needle)
            return true;
    return false;
}

@("HTTP/1 completes a multi-write response after the client half-closes its request side")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    foreach (_; 0 .. 4)
    {
        auto socket = fixture.connect();
        scope (exit)
            socket.close();
        sendAll(socket, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n");
        socket.shutdown(SocketShutdown.SEND);
        const received = cast(const(char)[]) readUntilClosed(socket);
        assert(received.length > 4 && received[0 .. 15] == "HTTP/1.1 200 OK");
        size_t split;
        while (split + 4 <= received.length && received[split .. split + 4] != "\r\n\r\n")
            ++split;
        assert(split + 4 <= received.length);
        assert(contentLength(received[0 .. split + 4].idup) == largeBytes);
        assert(received.length - split - 4 == largeBytes);
    }
}

@("HTTP/1 answers Expect 100-continue before the client sends its body")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(500));
    foreach (_; 0 .. 2)
    {
        sendAll(socket,
                "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n" ~ "Expect: 100-continue\r\n\r\n");
        char[25] interim;
        size_t have;
        while (have < interim.length)
        {
            const count = receiveSome(socket, interim[have .. $]);
            assert(count > 0, "no interim 100 Continue response");
            have += count;
        }
        assert(interim[] == "HTTP/1.1 100 Continue\r\n\r\n");
        sendAll(socket, "hello");
        string head;
        char[] pending;
        assert(readResponse(socket, pending, head) == "hello");
        assert(head[0 .. 15] == "HTTP/1.1 200 OK");
    }

    // A request whose body arrived with its head needs no interim response.
    sendAll(socket,
            "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n" ~ "Expect: 100-continue\r\n\r\nabc");
    string head;
    char[] pending;
    assert(readResponse(socket, pending, head) == "abc");
    assert(head[0 .. 15] == "HTTP/1.1 200 OK");

    // An oversized declared body is refused instead of solicited.
    sendAll(socket,
            "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2000000\r\n" ~ "Expect: 100-continue\r\n\r\n");
    readResponse(socket, pending, head);
    assert(head.length >= 12 && head[0 .. 12] == "HTTP/1.1 413", head);
}

@("HTTP/1 204 responses omit Content-Length and keep the connection reusable")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    sendAll(socket, "GET /empty HTTP/1.1\r\nHost: localhost\r\n\r\nPOST /echo HTTP/1.1\r\n"
            ~ "Host: localhost\r\nContent-Length: 2\r\n\r\nok");
    string head;
    char[] pending;
    assert(readResponse(socket, pending, head).length == 0);
    assert(head[0 .. 12] == "HTTP/1.1 204", head);
    assert(!contains(head, "Content-Length"), head);
    assert(!contains(head, "Content-Type"), head);
    assert(readResponse(socket, pending, head) == "ok");
    assert(head[0 .. 15] == "HTTP/1.1 200 OK");
}

@("HTTP/1 serves an ordinary route normally when the client offers a protocol upgrade")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    // curl --http2 against a cleartext URL offers h2c this way; RFC 9110 section 7.8 lets a server ignore it.
    sendAll(socket, "GET /large HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade, HTTP2-Settings\r\n"
            ~ "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n");
    string head;
    char[] pending;
    const received = readResponse(socket, pending, head);
    assert(head.length >= 15 && head[0 .. 15] == "HTTP/1.1 200 OK", head);
    assert(received.length == largeBytes);
    assert(contains(head, "Connection: close"), head);
    assert(readUntilClosed(socket).length == 0);
}

@("HTTP/1 response streams are paced by write completions rather than a millisecond poll")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    const started = MonoTime.currTime;
    sendAll(socket, "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const received = cast(const(char)[]) readUntilClosed(socket);
    const elapsed = MonoTime.currTime - started;
    assert(received.length > streamBytes && received[0 .. 15] == "HTTP/1.1 200 OK", elapsed.toString());
    assert(received[$ - 5 .. $] == "0\r\n\r\n");
    // About 1,000 transport writes: a 1 ms poll per write needs over a second.
    assertWallClock(elapsed < dur!"msecs"(400), "streamed response took " ~ elapsed.toString() ~ " against 400 ms");
}

@("HTTP/1 upgraded streams echo without a millisecond receive poll")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    sendAll(socket, "GET /echo HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: flint-echo\r\n\r\n");
    char[] pending;
    string head;
    readResponse(socket, pending, head);
    assert(head.length >= 12 && head[0 .. 12] == "HTTP/1.1 101", head);
    enum rounds = 200;
    char[16] reply;
    const started = MonoTime.currTime;
    foreach (round; 0 .. rounds)
    {
        sendAll(socket, "0123456789abcdef");
        size_t have;
        while (have < reply.length)
        {
            const count = receiveSome(socket, reply[have .. $]);
            assert(count > 0);
            have += count;
        }
        assert(reply[] == "0123456789abcdef");
    }
    const elapsed = MonoTime.currTime - started;
    // Each round trip waits for one receive and one send completion: 1 ms polls need over 200 ms.
    assertWallClock(elapsed < dur!"msecs"(100), "200 echo round trips took " ~ elapsed.toString() ~ " against 100 ms");
}

/// User plus system CPU time of the whole test process.
// SAFETY: getrusage writes only the local rusage it is given and retains no pointer to it.
private Duration processCpu() @trusted
{
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;

    rusage usage;
    assert(getrusage(RUSAGE_SELF, &usage) == 0);
    return dur!"seconds"(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + dur!"usecs"(
            usage.ru_utime.tv_usec + usage.ru_stime.tv_usec);
}

@("HTTP/1 upgraded echoes from a peer slower than 200 µs are neither paced by a 1 ms poll nor spun for")
unittest
{
    import core.thread : Thread;

    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
    sendAll(socket, "GET /echo HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: flint-echo\r\n\r\n");
    char[] pending;
    string head;
    readResponse(socket, pending, head);
    assert(head.length >= 12 && head[0 .. 12] == "HTTP/1.1 101", head);
    enum rounds = 200;
    Duration[rounds] replies;
    char[16] reply;
    const cpuBefore = processCpu();
    const started = MonoTime.currTime;
    foreach (round; 0 .. rounds)
    {
        // The handler has been waiting for this message for longer than the former 200 µs spin window,
        // as it would behind a LAN or internet round trip.
        Thread.sleep(dur!"usecs"(300));
        const sent = MonoTime.currTime;
        sendAll(socket, "0123456789abcdef");
        size_t have;
        while (have < reply.length)
        {
            const count = receiveSome(socket, reply[have .. $]);
            assert(count > 0);
            have += count;
        }
        replies[round] = MonoTime.currTime - sent;
        assert(reply[] == "0123456789abcdef");
    }
    const elapsed = MonoTime.currTime - started;
    const cpu = processCpu() - cpuBefore;
    foreach (index; 1 .. rounds)
        for (size_t at = index; at > 0 && replies[at] < replies[at - 1]; --at)
        {
            const swap = replies[at];
            replies[at] = replies[at - 1];
            replies[at - 1] = swap;
        }
    const median = replies[rounds / 2];
    // A 1 ms poll answers each message at the next poll, roughly 0.8 ms after it arrives.
    assertWallClock(median < dur!"usecs"(250), "median delayed echo took " ~ median.toString() ~ " against 250 µs");
    // Spinning for 200 µs of every wait costs at least 40 ms of CPU over these rounds.
    assertWallClock(cpu < dur!"msecs"(30),
            "delayed echoes used " ~ cpu.toString() ~ " of CPU in " ~ elapsed.toString() ~ " against 30 ms");
}

/// Return a response field's value, matching the name case-insensitively.
package string fieldValue(string head, string name)
{
    import std.uni : toLower;

    size_t start;
    foreach (index; 0 .. head.length)
    {
        if (index + 1 < head.length && head[index] == '\r' && head[index + 1] == '\n')
        {
            const line = head[start .. index];
            if (line.length > name.length && line[name.length] == ':' && toLower(line[0 .. name.length]) == toLower(
                    name))
            {
                size_t value = name.length + 1;
                while (value < line.length && line[value] == ' ')
                    ++value;
                return line[value .. $];
            }
            start = index + 2;
        }
    }
    return null;
}

/// Assert an RFC 9110 IMF-fixdate within a few seconds of the current UTC time.
package void assertCurrentDate(string head)
{
    import core.time : abs;
    import std.datetime.systime : Clock, parseRFC822DateTime;
    import std.datetime.timezone : UTC;

    const value = fieldValue(head, "date");
    assert(value.length == 29, "missing or malformed Date: " ~ head);
    assert(value[3 .. 5] == ", " && value[$ - 4 .. $] == " GMT", value);
    const parsed = parseRFC822DateTime(value);
    assert(abs(parsed - Clock.currTime(UTC())) < dur!"seconds"(5), value);
}

@("HTTP/1 responses carry a current Date; a known path with another method is 405 with Allow")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    string head;
    char[] pending;

    sendAll(socket, "GET /empty HTTP/1.1\r\nHost: localhost\r\n\r\n");
    readResponse(socket, pending, head);
    assert(head[0 .. 12] == "HTTP/1.1 204", head);
    assertCurrentDate(head);

    sendAll(socket, "POST /large HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    readResponse(socket, pending, head);
    assert(head[0 .. 12] == "HTTP/1.1 405", head);
    assert(fieldValue(head, "allow") == "GET, HEAD", head);
    assert(contains(head, "Connection: keep-alive"), head);
    assertCurrentDate(head);

    // /echo registers POST and a GET upgrade stream; a stream route does not imply HEAD.
    sendAll(socket, "DELETE /echo HTTP/1.1\r\nHost: localhost\r\n\r\n");
    readResponse(socket, pending, head);
    assert(head[0 .. 12] == "HTTP/1.1 405", head);
    assert(fieldValue(head, "allow") == "GET, POST", head);

    sendAll(socket, "GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n");
    readResponse(socket, pending, head);
    assert(head[0 .. 12] == "HTTP/1.1 404", head);
    assert(fieldValue(head, "allow") is null, head);
    assertCurrentDate(head);

    // Streamed response heads carry the Date field too.
    auto streamed = fixture.connect();
    scope (exit)
        streamed.close();
    sendAll(streamed, "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const received = cast(string) readUntilClosed(streamed).idup;
    size_t end;
    while (end + 4 <= received.length && received[end .. end + 4] != "\r\n\r\n")
        ++end;
    assert(end + 4 <= received.length, "no streamed response head");
    assertCurrentDate(received[0 .. end + 4]);

    // The connection is still usable after the error responses.
    sendAll(socket, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nok");
    assert(readResponse(socket, pending, head) == "ok");
    assert(head[0 .. 15] == "HTTP/1.1 200 OK", head);
    assertCurrentDate(head);
}

/// Wall-clock bounds are enforced on native hardware. A lane that runs these tests under full-system
/// emulation sets `FLINT_EMULATED=1`, and the bound is then reported with its measurement instead of
/// asserted, because emulated syscalls and context switches cost milliseconds (ADR-017).
private void assertWallClock(bool within, lazy string measurement) @trusted
{
    import core.stdc.stdio : fflush, printf, stdout;
    import std.process : environment;

    if (environment.get("FLINT_EMULATED") == "1")
    {
        const text = measurement;
        printf("FLINT-EMULATED wall-clock bound %s: %.*s\n", within ? "met".ptr : "not met".ptr,
                cast(int) text.length, text.ptr);
        fflush(stdout);
        return;
    }
    assert(within, measurement);
}
