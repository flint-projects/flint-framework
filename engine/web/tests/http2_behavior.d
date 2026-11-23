module flint.engine.web.http2_behavior;

import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.web.http1_socket_behavior : assertCurrentDate, fieldValue;
import flint.engine.web.h2 : enableHttp2;
import flint.engine.web.runtime : Server;
import flint.engine.web.stream : StreamField, StreamMode, StreamRoute, StreamToken;
import flint.engine.web.types : Method, Request, RequestContext, Response, ServerOptions;

@safe:

private final class Routes
{
    Result!Response text(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        auto copied = context.arena.copyIn(cast(const(ubyte)[]) "hello h2");
        if (!copied.ok())
            return Result!Response(Response.init, copied.error);
        return Result!Response(Response(200, "text/plain", copied.value));
    }

    Result!Response empty(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return Result!Response(Response(204, null, Buffer.init));
    }

    Error stream(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        const StreamField[1] fields = [StreamField("x-mode", "stream")];
        const begun = token.begin(200, fields[], context.cancellation);
        if (begun.code != Status.ok)
            return begun;
        const sent = token.send(cast(const(ubyte)[]) "streamed", context.cancellation);
        if (sent.code != Status.ok)
            return sent;
        return token.finish(null, context.cancellation);
    }
}

private struct Exchange
{
    string head;
    string body;
}

/// Run one request through curl, an independent nghttp2-based HTTP/2 client, with prior knowledge.
private Exchange curl(ushort port, string method, string path)
{
    import std.conv : to;
    import std.process : environment, execute;
    import std.string : indexOf;

    // FLINT_TEST_CURL names the client where the system's lacks HTTP/2: Windows ships one without it, and
    // CreateProcess searches System32 before PATH (ADR-026).
    auto arguments = [
        environment.get("FLINT_TEST_CURL", "curl"), "--silent", "--show-error",
        "--http2-prior-knowledge", "--max-time", "5", "--include"
    ];
    arguments ~= method == "HEAD" ? ["--head"] : ["--request", method];
    arguments ~= "http://127.0.0.1:" ~ port.to!string ~ path;
    const result = execute(arguments);
    assert(result.status == 0, "curl failed: " ~ result.output);
    const split = result.output.indexOf("\r\n\r\n");
    assert(split > 0, result.output);
    return Exchange(result.output[0 .. split + 4], result.output[split + 4 .. $]);
}

@("HTTP/2 responses carry a current date; a known path with another method is 405 with allow")
unittest
{
    Server server;
    ServerOptions options;
    options.port = 0;
    options.cores = 1;
    options.maxConnectionsPerCore = 16;
    options.http2 = true;
    options.http2PriorKnowledge = true;
    enableHttp2();
    assert(server.start(options).code == Status.ok);
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    auto routes = new Routes;
    assert(server.route(Method.get, "/text", &routes.text).code == Status.ok);
    assert(server.route(Method.put, "/text", &routes.text).code == Status.ok);
    assert(server.route(Method.get, "/empty", &routes.empty).code == Status.ok);
    const streamed = StreamRoute(Method.get, "/stream", StreamMode.response, &routes.stream);
    assert(server.routeStream(streamed).code == Status.ok);
    const port = server.listenPort();
    Context context;
    assert(server.poll(context).code == Status.ok);

    auto ok = curl(port, "GET", "/text");
    assert(ok.head[0 .. 10] == "HTTP/2 200", ok.head);
    assert(ok.body == "hello h2", ok.body);
    assert(fieldValue(ok.head, "content-length") == "8", ok.head);
    assert(fieldValue(ok.head, "content-type") == "text/plain", ok.head);
    assertCurrentDate(ok.head);

    auto head = curl(port, "HEAD", "/text");
    assert(head.head[0 .. 10] == "HTTP/2 200", head.head);
    assert(fieldValue(head.head, "content-length") == "8", head.head);
    assert(head.body.length == 0, head.body);
    assertCurrentDate(head.head);

    auto empty = curl(port, "GET", "/empty");
    assert(empty.head[0 .. 10] == "HTTP/2 204", empty.head);
    assert(fieldValue(empty.head, "content-length") is null, empty.head);
    assertCurrentDate(empty.head);

    auto stream = curl(port, "GET", "/stream");
    assert(stream.head[0 .. 10] == "HTTP/2 200", stream.head);
    assert(fieldValue(stream.head, "x-mode") == "stream", stream.head);
    assert(stream.body == "streamed", stream.body);
    assertCurrentDate(stream.head);

    auto refused = curl(port, "DELETE", "/text");
    assert(refused.head[0 .. 10] == "HTTP/2 405", refused.head);
    assert(fieldValue(refused.head, "allow") == "GET, HEAD, PUT", refused.head);
    assertCurrentDate(refused.head);

    auto missing = curl(port, "GET", "/missing");
    assert(missing.head[0 .. 10] == "HTTP/2 404", missing.head);
    assert(fieldValue(missing.head, "allow") is null, missing.head);
    assertCurrentDate(missing.head);
}
