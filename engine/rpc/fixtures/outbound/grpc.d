/// Outbound interoperability against the pinned grpc-go fixture.
module grpc_fixture;

import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.http : ClientOptions, HttpClient, HttpStreamField;
import flint.engine.reactor : Backend, Reactor, ReactorOptions;
import flint.engine.rpc : GrpcCall, GrpcCallOptions, GrpcService, RpcCode, beginGrpc;
import std.stdio : writeln;
import std.string : indexOf;

@safe:

int main(string[] arguments)
{
    if (arguments.length < 2 || arguments.length > 3)
        return 2;
    HttpClient client;
    ClientOptions settings;
    settings.maxConnections = settings.maxConnectionsPerOrigin = 1;
    const rejectUntrusted = arguments.length == 3 && arguments[2] == "--reject-untrusted";
    if (arguments.length == 3 && !rejectUntrusted)
        settings.caBundle = arguments[2];
    check(client.open(settings));
    ubyte[1024 * 1024] storage;
    auto arena = RequestArena(storage[]);
    auto caller = Context.init.withDeadline(Deadline.afterMillis(20_000));
    GrpcCallOptions options;
    options.origin = arguments[1];
    options.service = GrpcService("flint.rpc.fixture.Echo");
    options.allowLoopbackCleartext = arguments.length == 2;
    const fields = [HttpStreamField("x-flint-probe", "duplex")];
    options.metadata = fields;
    if (rejectUntrusted)
    {
        options.method = "Unary";
        auto opened = beginGrpc(client, options, caller);
        check(opened.error);
        auto call = move(opened.value);
        const response = call.head(arena, caller);
        assert(!response.ok() && response.error.code != Status.timedOut);
        check(call.close());
        check(client.close());
        writeln("untrusted TLS peer rejected");
        return 0;
    }

    const ubyte[5] first = [74, 3, 'o', 'n', 'e'];
    const ubyte[5] second = [74, 3, 't', 'w', 'o'];
    const one = arena.copyIn(first[]);
    const two = arena.copyIn(second[]);
    check(one.error);
    check(two.error);
    simple(client, options, arena, caller, "Unary", one.value, Buffer.init, first[], 1);
    simple(client, options, arena, caller, "ClientStream", one.value, two.value, second[], 1);
    simple(client, options, arena, caller, "ServerStream", one.value, Buffer.init, first[], 3);
    fullDuplex(client, options, arena, caller, two.value, second[]);
    terminal(client, options, arena, caller, one.value);
    cancelled(client, options, arena, false);
    cancelled(client, options, arena, true);
    deadline(client, options, arena, one.value);
    check(client.close());
    runDuplexFibers(options, settings);
    writeln("grpc-go all four shapes, early echo, metadata, terminal status, cancellation and deadline passed");
    return 0;
}

private void runDuplexFibers(GrpcCallOptions options, ClientOptions clientOptions)
{
    ReactorOptions config;
    config.cores = 1;
    config.backend = Backend.epoll;
    config.fiberPoolSize = 3;
    config.fiberStackBytes = 512 * 1024;
    config.maxConnectionsPerCore = 4;
    auto started = Reactor.create(config);
    check(started.error);
    auto job = new DuplexJob(options);
    check(job.client.open(clientOptions));
    check(started.value.postStartup(0, &job.begin));
    check(started.value.run());
    assert(job.completed == 2 && job.received == DuplexJob.messages);
    writeln("simultaneous owner fibers exchanged ", job.received, " 64 KiB messages in each direction");
}

private final class DuplexJob
{
    enum messages = 12;
    HttpClient client;
    GrpcCallOptions options;
    GrpcCall call;
    Context lifetime;
    uint received;
    uint completed;

    this(GrpcCallOptions options)
    {
        this.options = options;
        this.options.method = "Bidi";
    }

    void begin() nothrow @nogc
    {
        lifetime = Context.init.withDeadline(Deadline.afterMillis(12_000));
        auto invoked = beginGrpc(client, options, lifetime);
        assert(invoked.ok(), invoked.error.message);
        move(invoked.value, call);
        auto reactor = Reactor.current();
        assert(reactor.postWith(0, &upload).code == Status.ok);
        assert(reactor.postWith(0, &download).code == Status.ok);
    }

    void upload() nothrow @nogc
    {
        ubyte[65_600] memory;
        auto arena = RequestArena(memory[]);
        const payload = arena.allocate(65_540, 1);
        assert(payload.ok());
        foreach (ubyte index; 0 .. messages)
        {
            assert(arena.write(payload.value, (scope ubyte[] wire) @safe nothrow @nogc {
                    static immutable ubyte[4] prefix = [74, 128, 128, 4];
                    wire[0 .. 4] = prefix[];
                    wire[4 .. $] = index;
                }) == Status.ok);
            const sent = call.send(payload.value, arena, lifetime);
            assert(sent.code == Status.ok, sent.message);
        }
        const halfClosed = call.finishSend(lifetime);
        assert(halfClosed.code == Status.ok, halfClosed.message);
        finished();
    }

    void download() nothrow @nogc
    {
        ubyte[72 * 1024] memory;
        auto arena = RequestArena(memory[]);
        foreach (ubyte index; 0 .. messages)
        {
            const result = call.receive(arena, lifetime);
            assert(result.ok(), result.error.message);
            assert(arena.read(result.value, (scope const(ubyte)[] wire) @safe nothrow @nogc {
                    assert(wire.length == 65_540 && wire[4] == index && wire[$ - 1] == index);
                }) == Status.ok);
            ++received;
            assert(arena.reset() == Status.ok);
        }
        const eof = call.receive(arena, lifetime);
        assert(eof.error.code == Status.notFound, eof.error.message);
        assert(call.status(arena).value.code == RpcCode.ok);
        finished();
    }

    void finished() nothrow @nogc
    {
        if (++completed == 2)
        {
            assert(call.close().code == Status.ok);
            assert(client.close().code == Status.ok);
            auto reactor = Reactor.current();
            reactor.stop();
        }
    }
}

private void simple(ref HttpClient client, ref GrpcCallOptions options, ref scope RequestArena arena,
        ref Context caller, string method, Buffer first, Buffer second, scope const(ubyte)[] expected, uint count)
{
    writeln(method);
    options.method = method;
    auto opened = beginGrpc(client, options, caller);
    check(opened.error);
    auto call = move(opened.value);
    scope (exit)
        check(call.close());
    check(call.send(first, arena, caller));
    if (second != Buffer.init)
        check(call.send(second, arena, caller));
    check(call.finishSend(caller));
    foreach (_; 0 .. count)
        verifyMessage(call, arena, caller, expected);
    verifyEnd(call, arena, caller, RpcCode.ok);
    if (method == "Unary")
    {
        const trailers = call.trailers(arena, caller);
        check(trailers.error);
        assert(contains(arena, trailers.value, "x-reference-trailer: pinned-go"));
    }
}

private void fullDuplex(ref HttpClient client, ref GrpcCallOptions options, ref scope RequestArena arena,
        ref Context caller, Buffer second, scope const(ubyte)[] expected)
{
    writeln("Bidi");
    options.method = "Bidi";
    auto opened = beginGrpc(client, options, caller);
    check(opened.error);
    auto call = move(opened.value);
    scope (exit)
        check(call.close());
    ubyte[65_540] large;
    large[0 .. 4] = [cast(ubyte) 74, 128, 128, 4]; // 64 KiB protobuf bytes field.
    large[4 .. $] = cast(ubyte) 0xda;
    const framed = arena.copyIn(large[]);
    check(framed.error);
    const initial = call.head(arena, caller);
    check(initial.error);
    assert(contains(arena, initial.value.headers, "x-reference-header: pinned-go"));
    check(call.send(framed.value, arena, caller));
    verifyMessage(call, arena, caller, large[]);
    check(call.send(second, arena, caller));
    verifyMessage(call, arena, caller, expected);
    check(call.finishSend(caller));
    verifyEnd(call, arena, caller, RpcCode.ok);
}

private void terminal(ref HttpClient client, ref GrpcCallOptions options, ref scope RequestArena arena,
        ref Context caller, Buffer message)
{
    writeln("Terminal");
    options.method = "Terminal";
    auto opened = beginGrpc(client, options, caller);
    check(opened.error);
    auto call = move(opened.value);
    scope (exit)
        check(call.close());
    check(call.send(message, arena, caller));
    check(call.finishSend(caller));
    const status = verifyEnd(call, arena, caller, RpcCode.aborted);
    assert(contains(arena, status, "10% 🚀"));
}

private void cancelled(ref HttpClient client, ref GrpcCallOptions options, ref scope RequestArena arena, bool afterHead)
{
    writeln("Cancellation ", afterHead ? "after head" : "before first byte");
    options.method = "Bidi";
    auto created = CancelSource.create(Context.init, Deadline.none());
    check(created.error);
    auto source = move(created.value);
    auto caller = source.context();
    auto opened = beginGrpc(client, options, caller);
    check(opened.error);
    auto call = move(opened.value);
    if (afterHead)
        check(call.head(arena, caller).error);
    source.cancel();
    assert(call.receive(arena, caller).error.code == Status.cancelled);
    check(call.close());
}

private void deadline(ref HttpClient client, ref GrpcCallOptions options, ref scope RequestArena arena, Buffer message)
{
    writeln("Deadline");
    options.method = "Deadline";
    auto begin = Context.init.withDeadline(Deadline.afterMillis(500));
    Context observe;
    auto opened = beginGrpc(client, options, begin);
    check(opened.error);
    auto call = move(opened.value);
    scope (exit)
        check(call.close());
    check(call.send(message, arena, begin));
    check(call.finishSend(begin));
    verifyEnd(call, arena, observe, RpcCode.deadlineExceeded);
    check(call.close());

    options.method = "Bidi";
    auto expires = Context.init.withDeadline(Deadline.afterMillis(100));
    auto held = beginGrpc(client, options, expires);
    check(held.error);
    auto waiting = move(held.value);
    check(waiting.head(arena, expires).error);
    assert(waiting.receive(arena, observe).error.code == Status.timedOut);
    check(waiting.close());
}

private void verifyMessage(ref GrpcCall call, ref scope RequestArena arena, ref Context caller,
        scope const(ubyte)[] expected)
{
    const reply = call.receive(arena, caller);
    check(reply.error);
    bool equal;
    assert(arena.read(reply.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            equal = bytes == expected;
        }) == Status.ok);
    assert(equal);
}

private Buffer verifyEnd(ref GrpcCall call, ref scope RequestArena arena, ref Context caller, RpcCode expected)
{
    const eof = call.receive(arena, caller);
    if (eof.error.code != Status.notFound)
        check(eof.error);
    assert(eof.error.code == Status.notFound);
    const terminal = call.status(arena);
    check(terminal.error);
    assert(terminal.value.code == expected);
    return terminal.value.message;
}

private bool contains(ref scope RequestArena arena, Buffer buffer, string match)
{
    bool found;
    assert(arena.read(buffer, (scope const(ubyte)[] data) @safe nothrow @nogc {
            found = indexOf(cast(const(char)[]) data, match) >= 0;
        }) == Status.ok);
    return found;
}

private void check(Error status)
{
    if (status.code != Status.ok)
    {
        writeln(status.code, " ", status.message);
        assert(0);
    }
}
