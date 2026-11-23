module flint.web.http1_behavior;

import flint.arena : RequestArena, Status;
import flint.web.http1 : Http1Reader, ReadOutcome;
import flint.web.sys.ownership : releaseBytes, reserveH1;
import flint.web.types : HeaderRecord, Method, Request, maximumFields;

@safe:

@("llhttp assembles byte fragments, the pipelined keep-alive suffix, and generation-checked handles")
unittest
{
    enum first = "POST /users?id=3 HTTP/1.1\r\nHost: localhost\r\n"
        ~ "Transfer-Encoding: chunked\r\nX-Test: public\r\n\r\n" ~ "2\r\nab\r\n3\r\ncde\r\n0\r\nExtra: allowed\r\n\r\n";
    enum second = "GET /next HTTP/1.0\r\nConnection: close\r\n\r\n";
    ubyte[4096] storage;
    scope arena = RequestArena(storage[]);
    Http1Reader reader;
    ubyte[] payload;
    auto owned = reserveH1(512, reader.metadata.headers, payload);
    assert(payload.length == 512 && reader.metadata.headers.length == maximumFields);
    scope (exit)
        releaseBytes(owned);
    const opened = reader.open(617, payload, 512, 100);
    assert(opened.code == Status.ok, opened.message);
    scope (exit)
        reader.close();
    assert(reader.begin());

    foreach (index; 0 .. first.length)
    {
        size_t consumed;
        const bytes = cast(const(ubyte)[]) first[index .. index + 1];
        const result = reader.feed(bytes, arena, consumed);
        assert(consumed == 1);
        assert(index + 1 == first.length ? result == ReadOutcome.request : result == ReadOutcome.more);
    }

    scope request = Request.fromMetadata(&reader.metadata);
    assert(reader.keepAlive && request.method() == Method.post && reader.versionMinor == 1);
    assert(arena.read(request.path().value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) "/users");
        }) == Status.ok);
    assert(arena.read(request.query().value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) "id=3");
        }) == Status.ok);
    assert(arena.read(request.body().value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) "abcde");
        }) == Status.ok);
    assert(arena.read(request.header("x-TEST").value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) "public");
        }) == Status.ok);
    assert(request.header("Extra").error.code == Status.notFound);
    assert(arena.reset() == Status.ok);
    assert(reader.begin());
    assert(request.path().error.code == Status.invalidArgument);
    size_t consumed;
    assert(reader.feed(cast(const(ubyte)[]) second, arena, consumed) == ReadOutcome.request);
    assert(consumed == second.length);
    assert(!reader.keepAlive && reader.versionMinor == 0);
    assert(Request.fromMetadata(&reader.metadata).body().value.length() == 0);
}

private ushort rejected(scope const(char)[] input, size_t headerBytes = 256, size_t bodyBytes = 8)
{
    ubyte[2048] storage;
    scope arena = RequestArena(storage[]);
    Http1Reader reader;
    reader.metadata.headers = new HeaderRecord[maximumFields];
    assert(reader.open(23, new ubyte[headerBytes], headerBytes, bodyBytes).code == Status.ok);
    scope (exit)
        reader.close();
    assert(reader.begin());
    size_t consumed;
    return reader.feed(cast(const(ubyte)[]) input, arena, consumed) == ReadOutcome.rejected ? reader.responseStatus : 0;
}

@("request framing rejects ambiguous syntax and declared or received capacity exhaustion")
unittest
{
    assert(rejected("GET / HTTP/1.1\r\n\r\n") == 400);
    assert(rejected("GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n") == 400);
    assert(rejected("GET / HTTP/1.1\r\nHost: x\r\nBad Field: y\r\n\r\n") == 400);
    assert(rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx") == 400);
    assert(rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n") == 400);
    assert(rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n") == 400);
    assert(rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n") == 413);
    assert(rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n") == 413);
    assert(rejected("GET / HTTP/1.1\r\nHost: x\r\n\r\n", 20) == 431);
    auto longHead = "GET / HTTP/1.1\r\nHost: x\r\n";
    foreach (index; 0 .. 65)
        longHead ~= "x: y\r\n";
    assert(rejected(longHead ~ "\r\n", 512) == 431);
}

@("HTTP/1 header tables reject overflow and stale handles survive storage retirement")
unittest
{
    HeaderRecord[] headers;
    ubyte[] payload;
    assert(reserveH1(size_t.max, headers, payload) is null && headers is null && payload is null);

    ubyte[2048] requestBytes;
    scope arena = RequestArena(requestBytes[]);
    Http1Reader reader;
    auto owned = reserveH1(512, reader.metadata.headers, payload);
    assert(owned !is null);
    scope (exit)
        releaseBytes(owned);
    assert(reader.open(91, payload, 512, 64).code == Status.ok);
    assert(reader.begin());
    size_t consumed;
    auto first = "GET / HTTP/1.1\r\nHost: x\r\nX-Old: yes\r\n";
    foreach (_; 2 .. maximumFields)
        first ~= "x: y\r\n";
    first ~= "\r\n";
    assert(reader.feed(cast(const(ubyte)[]) first, arena, consumed) == ReadOutcome.request);
    assert(reader.metadata.fieldCount == maximumFields);
    scope stale = Request.fromMetadata(&reader.metadata);
    assert(stale.header("X-Old").ok());
    reader.close();
    reader.metadata.headers = null;
    releaseBytes(owned);
    assert(stale.header("X-Old").error.code == Status.invalidArgument);

    owned = reserveH1(256, reader.metadata.headers, payload);
    assert(owned !is null);
    assert(reader.open(92, payload, 256, 64).code == Status.ok);
    scope (exit)
        reader.close();
    assert(arena.reset() == Status.ok && reader.begin());
    enum second = "GET / HTTP/1.1\r\nHost: y\r\n\r\n";
    assert(reader.feed(cast(const(ubyte)[]) second, arena, consumed) == ReadOutcome.request);
    assert(stale.header("Host").error.code == Status.invalidArgument);
    scope current = Request.fromMetadata(&reader.metadata);
    assert(current.header("Host").ok() && current.header("X-Old").error.code == Status.notFound);
}
