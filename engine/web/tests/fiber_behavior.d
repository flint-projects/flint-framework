module flint.engine.web.fiber_behavior;

import core.time : MonoTime, dur;
import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.web.fiber : FiberResponse, FiberRoute, unknownLength;
import flint.engine.web.runtime : Server;
import flint.engine.web.stream : StreamField;
import flint.engine.web.types : Method, Request, RequestContext, Response, ServerOptions;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;

@safe:

/// Copy request bytes out of the arena into GC memory, as the servlet bridge does.
private string copyOut(ref scope RequestContext context, Result!Buffer buffer)
{
    if (!buffer.ok())
        return null;
    auto text = new char[buffer.value.length()];
    context.arena.read(buffer.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        text[] = cast(const(char)[]) bytes;
    });
    return text.idup;
}

private final class Handlers
{
    size_t calls;

    Result!Response ping(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        static immutable ubyte[] text = cast(immutable(ubyte)[]) "pong";
        auto reply = context.arena.copyIn(text);
        return reply.ok() ? Result!Response(Response(200, "text/plain",
                reply.value)) : Result!Response(Response.init, reply.error);
    }

    /// The fiber route: full D, with the GC and exceptions.
    void serve(ref scope Request request, ref scope RequestContext context, scope FiberResponse response)
    {
        import core.memory : GC;

        ++calls;
        const path = copyOut(context, request.path());
        const query = copyOut(context, request.query());
        string fields;
        foreach (index; 0 .. request.fieldCount())
        {
            // dfmt off
            char[] name;
            char[] value;
            // visitField's visitor is @nogc, so size first and copy in a second visit.
            size_t nameLength, valueLength;
            request.visitField(index, context.arena,
                    (scope const(char)[] n, scope const(ubyte)[] v) @safe nothrow @nogc {
                nameLength = n.length;
                valueLength = v.length;
            });
            name = new char[nameLength];
            value = new char[valueLength];
            request.visitField(index, context.arena,
                    (scope const(char)[] n, scope const(ubyte)[] v) @safe nothrow @nogc {
                name[] = n;
                value[] = cast(const(char)[]) v;
            });
            // dfmt on
            fields ~= name ~ "=" ~ value ~ ";";
        }
        // A collection while the handler runs must keep everything this fiber's stack references.
        GC.collect();
        const summary = path ~ "?" ~ query ~ " " ~ fields ~ " HTTP/1." ~ cast(char)('0' + request.protocolMinor());

        if (path == "/throw")
            throw new Exception("handler failed before responding");
        if (path == "/chunked")
        {
            const StreamField[1] type = [StreamField("Content-Type", "text/plain")];
            assert(response.begin(200, type[], unknownLength, context.cancellation).code == Status.ok);
            assert(response.started());
            assert(response.send(cast(const(ubyte)[]) "hello, ", context.cancellation).code == Status.ok);
            assert(response.send(cast(const(ubyte)[]) "chunks", context.cancellation).code == Status.ok);
            return; // the engine finishes the body
        }
        if (path == "/short")
        {
            assert(response.begin(200, null, 10, context.cancellation).code == Status.ok);
            assert(response.send(cast(const(ubyte)[]) "0123456789x", context.cancellation).code
                    == Status.invalidArgument);
            assert(response.send(cast(const(ubyte)[]) "01234", context.cancellation).code == Status.ok);
            return; // five bytes short: the engine must close
        }
        if (path == "/error-reply")
        {
            const StreamField[2] head = [
                StreamField("Allow", "GET"), StreamField("Content-Type", "application/json")
            ];
            assert(response.respond(405, head[], cast(const(ubyte)[]) `{"status":405}`, true,
                    context.cancellation).code == Status.ok);
            return;
        }
        if (path == "/large")
        {
            auto big = new ubyte[20_000];
            foreach (index, ref value; big)
                value = cast(ubyte)('a' + index % 26);
            assert(response.respond(200, null, big, false, context.cancellation).code == Status.ok);
            return;
        }
        if (path == "/empty")
        {
            const StreamField[1] accept = [StreamField("Accept", "application/json")];
            assert(response.respond(406, accept[], null, false, context.cancellation).code == Status.ok);
            return;
        }
        const StreamField[1] type = [StreamField("Content-Type", "text/plain")];
        assert(response.respond(200, type[], cast(const(ubyte)[]) summary, false, context.cancellation).code
                == Status.ok);
        assert(response.respond(200, null, null, false, context.cancellation).code == Status.conflict);
    }
}

private struct Fixture
{
    Server server;
    ushort port;
    Handlers handlers;

    void open()
    {
        ServerOptions options;
        options.port = 0;
        options.cores = 1;
        options.maxConnectionsPerCore = 16;
        options.http2 = false;
        options.idleTimeoutNanos = 60_000_000_000L;
        const started = server.start(options);
        assert(started.code == Status.ok, started.message);
        handlers = new Handlers;
        assert(server.route(Method.get, "/ping", &handlers.ping).code == Status.ok);
        assert(server.routeFiber(FiberRoute(&handlers.serve)).code == Status.ok);
        assert(server.routeFiber(FiberRoute(&handlers.serve)).code == Status.conflict);
        assert(server.routeFiber(FiberRoute(null)).code != Status.ok);
        port = server.listenPort();
        assert(port != 0);
        Context context;
        assert(server.poll(context).code == Status.ok);
        assert(server.routeFiber(FiberRoute(&handlers.serve)).code == Status.conflict);
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

private string readUntilClosed(Socket socket)
{
    char[] received;
    char[8192] chunk;
    const deadline = MonoTime.currTime + dur!"seconds"(5);
    while (MonoTime.currTime < deadline)
    {
        const count = receiveSome(socket, chunk[]);
        if (count <= 0)
            break;
        received ~= chunk[0 .. count];
    }
    return received.idup;
}

private ptrdiff_t find(scope const(char)[] text, scope const(char)[] needle, size_t from = 0)
{
    foreach (index; from .. text.length >= needle.length ? text.length - needle.length + 1 : from)
        if (text[index .. index + needle.length] == needle)
            return index;
    return -1;
}

/// Read one response whose framing is Content-Length, chunked, or none (head only); keep any suffix.
private string readOne(Socket socket, ref char[] received, out string head, bool headOnly = false)
{
    char[4096] chunk;
    const deadline = MonoTime.currTime + dur!"seconds"(5);
    for (;;)
    {
        const end = find(received, "\r\n\r\n");
        if (end >= 0)
        {
            const headText = received[0 .. end + 4];
            const bodyStart = end + 4;
            const lengthAt = find(headText, "\r\nContent-Length: ");
            if (headOnly)
            {
                head = headText.idup;
                received = received[bodyStart .. $].dup;
                return "";
            }
            if (lengthAt >= 0)
            {
                size_t length;
                foreach (character; headText[lengthAt + 18 .. $])
                {
                    if (character < '0' || character > '9')
                        break;
                    length = length * 10 + (character - '0');
                }
                if (received.length >= bodyStart + length)
                {
                    head = headText.idup;
                    const content = received[bodyStart .. bodyStart + length].idup;
                    received = received[bodyStart + length .. $].dup;
                    return content;
                }
            }
            else if (find(headText, "\r\nTransfer-Encoding: chunked\r\n") >= 0)
            {
                const last = find(received, "\r\n0\r\n\r\n", bodyStart - 2);
                if (last >= 0)
                {
                    head = headText.idup;
                    const content = dechunk(received[bodyStart .. last + 7]);
                    received = received[last + 7 .. $].dup;
                    return content;
                }
            }
        }
        assert(MonoTime.currTime < deadline, "timed out reading a response: " ~ received.idup);
        const count = receiveSome(socket, chunk[]);
        assert(count > 0, "connection closed mid-response: " ~ received.idup);
        received ~= chunk[0 .. count];
    }
}

private string dechunk(scope const(char)[] text)
{
    string reply;
    size_t at;
    for (;;)
    {
        size_t size;
        while (text[at] != '\r')
        {
            const c = text[at++];
            size = size * 16 + (c <= '9' ? c - '0' : c - 'a' + 10);
        }
        at += 2;
        if (size == 0)
            return reply;
        reply ~= text[at .. at + size];
        at += size + 2;
    }
}

@("fiber routes run full-D handlers with Tomcat framing, copy request fields out, and keep the connection")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;
    string head;

    // Owner-loop routes keep precedence; their framing is unchanged.
    sendAll(socket, "GET /ping HTTP/1.1\r\nHost: a\r\n\r\n");
    assert(readOne(socket, pending, head) == "pong");
    assert(head[0 .. 15] == "HTTP/1.1 200 OK", head);

    // Every other target reaches the fiber route: no reason phrase, fields in order, Content-Length.
    sendAll(socket, "GET /greeting?name=Jane+Q%20Public HTTP/1.1\r\nHost: a\r\nX-Trace: 7\r\n\r\n");
    auto reply = readOne(socket, pending, head);
    assert(reply == "/greeting?name=Jane+Q%20Public host=a;x-trace=7; HTTP/1.1", reply);
    assert(head[0 .. 15] == "HTTP/1.1 200 \r\n", head);
    assert(head[15 .. 59] == "Content-Type: text/plain\r\nContent-Length: 57", head);
    assert(find(head, "\r\nDate: ") > 0 && find(head, "Connection") < 0, head);

    // A path whose owner-loop route has another method also reaches the fiber route (servlet 405s are its own).
    sendAll(socket, "POST /ping HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n");
    reply = readOne(socket, pending, head);
    assert(reply == "/ping? host=a;content-length=0; HTTP/1.1", reply);

    // Chunked on begin with an unknown length; the engine writes the last chunk when the handler returns.
    sendAll(socket, "GET /chunked HTTP/1.1\r\nHost: a\r\n\r\n");
    reply = readOne(socket, pending, head);
    assert(reply == "hello, chunks", reply);
    assert(find(head, "Content-Type: text/plain\r\nTransfer-Encoding: chunked\r\nDate: ") > 0, head);

    // A whole chunked error body in one respond call, as Boot's error controller produces it.
    sendAll(socket, "POST /error-reply HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n");
    reply = readOne(socket, pending, head);
    assert(reply == `{"status":405}`, reply);
    assert(head[0 .. 15] == "HTTP/1.1 405 \r\n", head);
    assert(find(head, "Allow: GET\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n") == 15, head);

    // An empty uncommitted response: Content-Length: 0.
    sendAll(socket, "GET /empty HTTP/1.1\r\nHost: a\r\n\r\n");
    assert(readOne(socket, pending, head) == "");
    enum empty406 = "HTTP/1.1 406 \r\nAccept: application/json\r\nContent-Length: 0\r\nDate: ";
    assert(head[0 .. empty406.length] == empty406, head);

    // A body larger than one write.
    sendAll(socket, "GET /large HTTP/1.1\r\nHost: a\r\n\r\n");
    reply = readOne(socket, pending, head);
    assert(reply.length == 20_000 && reply[0 .. 3] == "abc" && reply[$ - 1] == 'a' + 19_999 % 26);

    // HEAD keeps Content-Length and sends no reply; the connection stays usable.
    sendAll(socket, "HEAD /greeting HTTP/1.1\r\nHost: a\r\n\r\n");
    readOne(socket, pending, head, true);
    assert(find(head, "Content-Length: 27\r\n") > 0, head);
    sendAll(socket, "GET /again HTTP/1.1\r\nHost: a\r\n\r\n");
    assert(readOne(socket, pending, head) == "/again? host=a; HTTP/1.1");

    // Pipelined requests are served in order on the same connection.
    sendAll(socket, "GET /one HTTP/1.1\r\nHost: a\r\n\r\nGET /two HTTP/1.1\r\nHost: a\r\n\r\n");
    assert(readOne(socket, pending, head) == "/one? host=a; HTTP/1.1");
    assert(readOne(socket, pending, head) == "/two? host=a; HTTP/1.1");

    // A request that names keep-alive gets Tomcat's Keep-Alive and Connection fields.
    sendAll(socket, "GET /k HTTP/1.1\r\nHost: a\r\nConnection: keep-alive\r\n\r\n");
    readOne(socket, pending, head);
    assert(find(head, "\r\nKeep-Alive: timeout=60\r\nConnection: keep-alive\r\n\r\n") > 0, head);
    assert(fixture.handlers.calls == 11);
}

@("fiber routes answer 500 for a handler that throws before responding and close truncated bodies")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();

    auto thrown = fixture.connect();
    scope (exit)
        thrown.close();
    sendAll(thrown, "GET /throw HTTP/1.1\r\nHost: a\r\n\r\n");
    const failed = readUntilClosed(thrown);
    assert(failed[0 .. 12] == "HTTP/1.1 500", failed);
    assert(find(failed, "Connection: close") > 0, failed);

    // Five bytes short of Content-Length: the engine closes rather than desynchronize the connection.
    auto truncated = fixture.connect();
    scope (exit)
        truncated.close();
    sendAll(truncated, "GET /short HTTP/1.1\r\nHost: a\r\n\r\nGET /next HTTP/1.1\r\nHost: a\r\n\r\n");
    const cut = readUntilClosed(truncated);
    assert(find(cut, "Content-Length: 10\r\n") > 0 && cut[$ - 5 .. $] == "01234", cut);

    // The server still serves new connections.
    auto healthy = fixture.connect();
    scope (exit)
        healthy.close();
    char[] pending;
    string head;
    sendAll(healthy, "GET /ok HTTP/1.1\r\nHost: a\r\n\r\n");
    assert(readOne(healthy, pending, head) == "/ok? host=a; HTTP/1.1");
}

@("HTTP/1.0 fiber responses of unknown length are delimited by closing the connection")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    sendAll(socket, "GET /chunked HTTP/1.0\r\n\r\n");
    const received = readUntilClosed(socket);
    assert(received[0 .. 15] == "HTTP/1.0 200 \r\n", received);
    assert(find(received, "Transfer-Encoding") < 0 && find(received, "Connection: close\r\n") > 0, received);
    assert(received[$ - 13 .. $] == "hello, chunks", received);
}
