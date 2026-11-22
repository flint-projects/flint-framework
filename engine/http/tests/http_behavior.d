module flint.http.http_behavior_test;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : CancelSource, Context, Deadline;
import flint.http : ChunkConsumer, ClientOptions, GetExchange, Header, HeaderParam, HttpClient,
    HttpExchange, HttpMethod,
    HttpRequest, HttpRequestView, HttpResponse, HttpStreamField, HttpVersion, PostExchange, bindHttpClient;

@safe:

private Result!HttpResponse send(ref HttpClient client, HttpRequest request,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    return client.send(request, arena, context);
}

private Result!ushort stream(ref HttpClient client, HttpRequest request, ref scope RequestArena arena,
        ref Context context, scope ChunkConsumer consumer) nothrow @nogc
{
    return client.stream(request, arena, context, consumer);
}

@("invalid TLS and bounded-pool policies fail before allocation")
unittest
{
    HttpClient client;
    ClientOptions options;
    options.verifyPeer = false;
    assert(client.open(options).code == Status.invalidArgument);
    options = ClientOptions.init;
    options.followRedirects = true;
    assert(client.open(options).code == Status.invalidArgument);
    options = ClientOptions.init;
    options.maxConnections = 129;
    assert(client.open(options).code == Status.invalidArgument);

    ubyte[1] storage;
    auto arena = RequestArena(storage[]);
    Context context;
    assert(send(client, HttpRequest.init, arena, context).error.code == Status.conflict);
    assert(client.close().code == Status.ok);
}

private struct Payload
{
    Text name;
}

@HttpExchange("http://127.0.0.1:43719")
private interface Echo
{
@safe nothrow @nogc:

    @GetExchange("/exchange/{segment}")
    Result!HttpResponse get(ref scope RequestArena arena, ref Context context, string segment,
            @HeaderParam("X-Trace") string trace);

    @PostExchange("/echo")
    Result!Payload post(ref scope RequestArena arena, ref Context context, scope const ref Payload value);
}

version (FlintNativeCurl)
{
    import core.lifetime : move;
    import flint.reactor : Backend, Reactor, ReactorOptions, TaskContext;
    import std.conv : to;
    import std.process : environment;

    private enum entityLimit = 8 * 1024 * 1024;

    private bool equalBytes(ref scope RequestArena arena, Buffer handle, scope const(char)[] expected) nothrow @nogc
    {
        bool matches;
        const checked = arena.read(handle, (scope const(ubyte)[] raw) {
            matches = raw == cast(const(ubyte)[]) expected;
        });
        return checked == Status.ok && matches;
    }

    private bool contains(scope const(char)[] value, scope const(char)[] target) nothrow @nogc
    {
        if (target.length > value.length)
            return false;
        foreach (offset; 0 .. value.length - target.length + 1)
            if (value[offset .. offset + target.length] == target)
                return true;
        return false;
    }

    private bool headerContains(ref scope RequestArena arena, Buffer headers, scope const(char)[] key) nothrow @nogc
    {
        bool found;
        const checked = arena.read(headers, (scope const(ubyte)[] raw) {
            found = contains(cast(const(char)[]) raw, key);
        });
        return checked == Status.ok && found;
    }

    private ubyte fixtureByte(size_t index) pure nothrow @nogc
    {
        return cast(ubyte)((index * 17 + index / 11) % 251);
    }

    private string setting(string key)
    {
        return environment.get("FLINT_HTTP_" ~ key, "");
    }

    private void exercisePolicy(string clear, string tls)
    {
        ClientOptions options;
        options.caBundle = setting("CA");
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);

        ubyte[2048] scratch;
        auto arena = RequestArena(scratch[]);
        Context context;
        auto response = send(client, HttpRequest(HttpMethod.get, clear ~ "/zero"), arena, context);
        assert(response.ok && response.value.status == 204 && response.value.protocol == HttpVersion.http1);
        assert(response.value.body.length == 0 && equalBytes(arena, response.value.body, ""));
        response = send(client, HttpRequest(HttpMethod.get, tls ~ "/zero"), arena, context);
        assert(response.ok && response.value.status == 204
                && response.value.protocol == HttpVersion.http2, response.error.message);
        response = send(client, HttpRequest(HttpMethod.get, setting("MISMATCH") ~ "/zero"), arena, context);
        assert(response.error.code == Status.permissionDenied, response.error.message);
        response = send(client, HttpRequest(HttpMethod.get, setting("EXPIRED") ~ "/zero"), arena, context);
        assert(response.error.code == Status.permissionDenied);
        response = send(client, HttpRequest(HttpMethod.get, clear ~ "/location"), arena, context);
        assert(response.ok && response.value.status == 302);
        response = send(client, HttpRequest(HttpMethod.get, "file:///etc/hosts"), arena, context);
        assert(response.error.code == Status.unsupported || response.error.code == Status.invalidArgument);
        response = send(client, HttpRequest(HttpMethod.get, "http://user:pass@localhost/"), arena, context);
        assert(response.error.code == Status.invalidArgument);

        auto transportCopy = client;
        assert(client.close().code == Status.ok);
        assert(send(transportCopy, HttpRequest.init, arena, context).error.code == Status.conflict);
        assert(transportCopy.close().code == Status.ok);

        assert(client.open(ClientOptions.init).code == Status.ok);
        response = send(client, HttpRequest(HttpMethod.get, tls ~ "/zero"), arena, context);
        assert(response.error.code == Status.permissionDenied);

        HttpRequest request;
        request.url = clear ~ "/zero";
        request.headers = [Header("X-Value", "first\r\nOther: second")];
        assert(client.send(request, arena, context).error.code == Status.invalidArgument);
        request.headers = [Header("Content-Length", "123")];
        assert(client.send(request, arena, context).error.code == Status.invalidArgument);
        request.headers = null;

        auto original = arena.copyIn(cast(const(ubyte)[]) "borrowed");
        assert(original.ok && arena.reset() == Status.ok);
        request.body = original.value;
        assert(client.send(request, arena, context).error.code == Status.invalidArgument);
        request.body = Buffer.init;
        ubyte[1] tiny;
        auto small = RequestArena(tiny[]);
        assert(client.send(request, small, context).error.code == Status.outOfMemory);
        assert(small.stats().used == 0);

        auto cancelled = CancelSource.create(Context.init, Deadline.none());
        assert(cancelled.ok);
        auto explicitlyCancelled = cancelled.value.context();
        cancelled.value.cancel();
        assert(client.send(request, arena, explicitlyCancelled).error.code == Status.cancelled);
        assert(client.close().code == Status.ok);
        ClientOptions headerLimit;
        headerLimit.maxHeaderBytes = 16;
        assert(client.open(headerLimit).code == Status.ok);
        assert(client.send(request, arena, context).error.code == Status.resourceExhausted);
        assert(arena.stats().used == 0);
    }

    private void exerciseRedirects(string clear, string tls)
    {
        ClientOptions options;
        options.caBundle = setting("CA");
        options.followRedirects = true;
        uint policyCalls;
        options.destinationPolicy = (scope const(char)[] url) {
            ++policyCalls;
            return !contains(url, "/banned");
        };
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        Header[] fields = [
            Header("Authorization", "opaque-token"), Header("Cookie", "id=internal"),
            Header("X-Probe", "retained")
        ];
        ubyte[8192] scratch;
        auto arena = RequestArena(scratch[]);
        Context context;
        auto result = send(client, HttpRequest(HttpMethod.get, clear ~ "/location", fields), arena, context);
        assert(result.ok && result.value.status == 200, result.error.message);
        assert(equalBytes(arena, result.value.body, "retained"));
        assert(policyCalls == 2);

        result = send(client, HttpRequest(HttpMethod.get, clear ~ "/same", fields), arena, context);
        assert(result.ok && result.value.status == 200);
        assert(equalBytes(arena, result.value.body, "opaque-token;id=internal"));
        assert(headerContains(arena, result.value.headers, "X-Final: checked"));
        assert(policyCalls == 4);
        result = send(client, HttpRequest(HttpMethod.get, clear ~ "/blocked-target", fields), arena, context);
        assert(result.error.code == Status.permissionDenied && policyCalls == 6);
        result = send(client, HttpRequest(HttpMethod.get, tls ~ "/location", fields), arena, context);
        assert(result.error.code == Status.permissionDenied);
        result = send(client, HttpRequest(HttpMethod.get, clear ~ "/again?n=5"), arena, context);
        assert(result.ok && result.value.status == 204);
        result = send(client, HttpRequest(HttpMethod.get, clear ~ "/again?n=6"), arena, context);
        assert(result.error.code == Status.resourceExhausted);

        const upload = arena.copyIn(cast(const(ubyte)[]) `{"ok":true}`);
        assert(upload.ok);
        Header[] mediaType = [Header("Content-Type", "application/json")];
        HttpRequest replay = HttpRequest(HttpMethod.post, clear ~ "/repeat-upload", mediaType, upload.value);
        result = client.send(replay, arena, context);
        assert(result.ok && result.value.status == 200 && equalBytes(arena, result.value.body, `{"ok":true}`));
        replay.url = clear ~ "/drop-upload";
        result = client.send(replay, arena, context);
        assert(result.ok && result.value.status == 204);
    }

    private void exerciseScopedRequests(string origin)
    {
        HttpClient client;
        ClientOptions options;
        options.followRedirects = true;
        options.destinationPolicy = (scope const(char)[]) @safe nothrow @nogc => true;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);

        ubyte[8192] scratch;
        auto arena = RequestArena(scratch[]);
        Context context;
        const target = origin ~ "/view-signed/leaf/../%E2%98%83?mode=a%2Fb";
        const HttpStreamField[1] fields = [HttpStreamField("X-Probe", "scoped")];
        const ubyte[7] input = [13, 10, 0, 128, 1, 50, 230];
        scope request = HttpRequestView(HttpMethod.put, target, fields[], input[], true);
        const response = client.sendView(request, arena, context);
        assert(response.ok && response.value.status == 200);
        assert(arena.read(response.value.body, (scope const(ubyte)[] received) @safe nothrow @nogc {
                assert(received == input[]);
            }) == Status.ok);

        const redirect = origin ~ "/repeat-upload";
        const limited = origin ~ "/stream-rejected";
        const echo = origin ~ "/echo";
        const HttpStreamField[1] media = [HttpStreamField("Content-Type", "application/json")];
        scope stream = HttpRequestView(HttpMethod.post, redirect, media[], input[], false, true);
        size_t consumed;
        scope ChunkConsumer receive = (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            consumed += bytes.length;
            return Error(Status.cancelled, "test consumer retired the request");
        };
        auto status = client.streamView(stream, arena, context, receive);
        assert(status.ok && status.value == 307 && consumed == 0);
        stream.url = limited;
        status = client.streamView(stream, arena, context, receive);
        assert(status.ok && status.value == 429 && consumed == 0);
        stream.url = echo;
        status = client.streamView(stream, arena, context, receive);
        assert(status.error.code == Status.cancelled && consumed > 0);
        assert(client.sendView(stream, arena, context).value.status == 200);
    }

    private void exerciseStreams(string origin)
    {
        HttpClient client;
        assert(client.open(ClientOptions.init).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        auto storage = new ubyte[entityLimit + 1024];
        auto arena = RequestArena(storage);
        Context context;
        auto response = send(client, HttpRequest(HttpMethod.get, origin ~ "/bytes?n=8388608"), arena, context);
        assert(response.ok && response.value.body.length == entityLimit, response.error.message);
        assert(arena.read(response.value.body, (scope const(ubyte)[] bytes) {
                foreach (offset, byteValue; bytes)
                    assert(byteValue == fixtureByte(offset));
            }) == Status.ok);
        assert(arena.reset() == Status.ok);
        response = send(client, HttpRequest(HttpMethod.get, origin ~ "/bytes?n=8388609"), arena, context);
        assert(response.error.code == Status.resourceExhausted);
        assert(arena.stats().used == 0);

        foreach (split; 0 .. 3)
        {
            ubyte[2] combined;
            size_t used;
            const url = origin ~ "/utf?split=" ~ split.to!string;
            const result = stream(client, HttpRequest(HttpMethod.get, url), arena, context,
                    (scope const(ubyte)[] bytes) {
                assert(bytes.length <= combined.length - used);
                combined[used .. used + bytes.length] = bytes[];
                used += bytes.length;
                return Error.init;
            });
            assert(result.ok && result.value == 200);
            assert(used == 2 && combined == [0xC3, 0xA9]);
        }
        foreach (range; [[1, 2048], [2049, 4096]])
        {
            size_t total;
            const size = (range[0] + range[1]) * (range[1] - range[0] + 1) / 2;
            const url = origin ~ "/chunks?min=" ~ range[0].to!string ~ "&max=" ~ range[1].to!string;
            const result = stream(client, HttpRequest(HttpMethod.get, url), arena, context,
                    (scope const(ubyte)[] bytes) {
                foreach (byteValue; bytes)
                    assert(byteValue == fixtureByte(total++));
                return Error.init;
            });
            assert(result.ok && result.value == 200 && total == size, result.error.message);
        }
        size_t calls;
        const stopped = stream(client, HttpRequest(HttpMethod.get, origin ~ "/bytes?n=65536"),
                arena, context, (scope const(ubyte)[]) {
            ++calls;
            return Error(Status.cancelled, "consumer chose to stop");
        });
        assert(stopped.error.code == Status.cancelled && calls == 1);
        assert(arena.reset() == Status.ok);
    }

    private void exerciseCancellation(string origin)
    {
        ClientOptions options;
        options.caBundle = setting("CA");
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        ubyte[4096] scratch;
        auto arena = RequestArena(scratch[]);
        auto time = CancelSource.create(Context.init, Deadline.afterMillis(80));
        assert(time.ok);
        auto deadline = time.value.context();
        auto result = send(client, HttpRequest(HttpMethod.get,
                setting("CONNECTING") ~ "/unreachable"), arena, deadline);
        assert(result.error.code == Status.timedOut, result.error.message);
        Context general;
        result = send(client, HttpRequest(HttpMethod.get, origin ~ "/handshakes"), arena, general);
        assert(result.ok && !equalBytes(arena, result.value.body, "0"));

        auto cancellation = CancelSource.create(Context.init, Deadline.none());
        assert(cancellation.ok);
        auto cancelled = cancellation.value.context();
        uint prefixCalls;
        const received = stream(client, HttpRequest(HttpMethod.get, origin ~ "/late"), arena,
                cancelled, (scope const(ubyte)[] bytes) {
            assert(bytes == ['!']);
            ++prefixCalls;
            cancellation.value.cancel();
            return Error.init;
        });
        assert(received.error.code == Status.cancelled && prefixCalls == 1);
        assert(arena.reset() == Status.ok);
        result = send(client, HttpRequest(HttpMethod.get, origin ~ "/zero"), arena, general);
        assert(result.ok && result.value.status == 204);

        assert(client.close().code == Status.ok);
        options.connectTimeoutNanos = 35_000_000;
        assert(client.open(options).code == Status.ok);
        result = send(client, HttpRequest(HttpMethod.get, setting("CONNECTING") ~ "/timeout"), arena, general);
        assert(result.error.code == Status.timedOut && result.error.message == "HTTP connection deadline elapsed");
    }

    private void exerciseExchange()
    {
        HttpClient client;
        assert(client.open(ClientOptions.init).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        auto exchange = bindHttpClient!Echo(client);
        ubyte[4096] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        auto get = exchange.get(arena, context, "a/λ?%#", "typed");
        assert(get.ok && get.value.status == 200);
        assert(equalBytes(arena, get.value.body, "/exchange/a%2F%CE%BB%3F%25%23;typed"));
        get = exchange.get(arena, context, "..", "dot");
        assert(get.error.code == Status.invalidArgument);
        auto name = arena.copyIn(cast(const(ubyte)[]) "decoded by serde");
        assert(name.ok);
        const dto = Payload(Text(name.value));
        auto returned = exchange.post(arena, context, dto);
        assert(returned.ok, returned.error.message);
        assert(equalBytes(arena, returned.value.name.bytes, "decoded by serde"));
    }

    @("Linux pinned HTTP transport, TLS policy, redirects, limits and typed bindings")
    unittest
    {
        const origin = setting("HTTP");
        if (origin.length)
        {
            exercisePolicy(origin, setting("HTTPS"));
            exerciseRedirects(origin, setting("HTTPS"));
            exerciseScopedRequests(origin);
            exerciseStreams(origin);
            exerciseCancellation(origin);
            exerciseExchange();
        }
        else
        {
            HttpClient client;
            assert(client.open(ClientOptions.init).code == Status.ok);
            assert(client.close().code == Status.ok);
        }
    }

    private final class Multiplex
    {
        HttpClient transport;
        HttpRequest[64] requests;
        string[64] replies;
        string[64] headers;
        size_t completed;
        uint connection;
    }

    private shared Multiplex activeMultiplex;

    // SAFETY: The harness publishes one live fixture before starting the sole worker; the
    // worker has exclusive access until the main thread joins it and withdraws publication.
    private Multiplex multiplexFixture() @trusted nothrow @nogc
    {
        return cast(Multiplex) activeMultiplex;
    }

    private void multiply() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto info = owner.currentTask();
        assert(info.ok && info.value.requestId < 64);
        const index = cast(size_t) info.value.requestId;

        auto fixture = multiplexFixture();
        ubyte[1024] memory;
        auto arena = RequestArena(memory[]);
        auto deadline = CancelSource.create(info.value.cancellation, Deadline.afterMillis(5_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        auto response = fixture.transport.send(fixture.requests[index], arena, context);
        assert(response.ok && response.value.status == 200
                && response.value.protocol == HttpVersion.http2, response.error.message);
        assert(equalBytes(arena, response.value.body, fixture.replies[index]));
        assert(headerContains(arena, response.value.headers, fixture.headers[index]));
        const didRead = arena.read(response.value.headers, (scope const(ubyte)[] raw) {
            enum key = "x-connection: ";
            const headers = cast(const(char)[]) raw;
            uint number;
            foreach (i; 0 .. headers.length - key.length + 1)
            {
                if (headers[i .. i + key.length] != key)
                    continue;
                foreach (digit; headers[i + key.length .. $])
                {
                    if (digit < '0' || digit > '9')
                        break;
                    number = number * 10 + digit - '0';
                }
                break;
            }
            assert(number != 0);
            if (fixture.connection == 0)
                fixture.connection = number;
            assert(number == fixture.connection);
        });
        assert(didRead == Status.ok);
        if (++fixture.completed == 64)
        {
            assert(fixture.transport.close().code == Status.ok);
            owner.stop();
        }
    }

    private void exerciseMultiplex(Backend backend, string group) @system
    {
        ReactorOptions reactors;
        reactors.backend = backend;
        reactors.cores = 1;
        reactors.fiberPoolSize = 64;
        auto loop = Reactor.create(reactors);
        assert(loop.ok, loop.error.message);
        auto fixture = new Multiplex;
        ClientOptions options;
        options.caBundle = setting("CA");
        options.maxConnections = 32;
        options.maxConnectionsPerOrigin = 1;
        assert(fixture.transport.open(options).code == Status.ok);
        activeMultiplex = cast(shared) fixture;
        scope (exit)
            activeMultiplex = null;
        const origin = setting("HTTPS");
        foreach (index; 0 .. 64)
        {
            const id = index.to!string;
            fixture.requests[index] = HttpRequest(HttpMethod.get,
                    origin ~ "/h2/" ~ id ~ "?group=" ~ group, [Header("X-Id", id)]);
            fixture.replies[index] = "reply-" ~ id;
            fixture.headers[index] = "x-id: " ~ id ~ "\r\n";
            assert(loop.value.post(0, &multiply, TaskContext(index)).code == Status.ok);
        }
        const ended = loop.value.run();
        assert(ended.code == Status.ok, ended.message);
        assert(fixture.completed == 64 && fixture.connection != 0);
        const stats = loop.value.workerStats(0);
        assert(stats.ok && stats.value.gcAllocated == 0);
    }

    @("64 pinned reactor fibers multiplex over one negotiated and verified HTTP/2 connection")
    @system unittest
    {
        if (setting("HTTP").length)
        {
            exerciseMultiplex(Backend.epoll, "epoll");
            version (FlintNativeLiburing)
                exerciseMultiplex(Backend.ioUring, "io-uring");
        }
    }

    private final class Sequential
    {
        HttpClient transport;
        HttpRequest request;
        long elapsedNanos;
        uint completed;
    }

    private shared Sequential activeSequential;

    // SAFETY: The harness publishes one live fixture before starting the sole worker; the
    // worker has exclusive access until the main thread joins it and withdraws publication.
    private Sequential sequentialFixture() @trusted nothrow @nogc
    {
        return cast(Sequential) activeSequential;
    }

    private void sequential() nothrow @nogc
    {
        import core.time : MonoTime;

        auto owner = Reactor.current();
        auto fixture = sequentialFixture();
        ubyte[4096] memory;
        auto arena = RequestArena(memory[]);
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(10_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        // The first exchange opens the reused connection; only later exchanges are timed.
        foreach (round; 0 .. 101)
        {
            const started = MonoTime.currTime;
            const response = fixture.transport.send(fixture.request, arena, context);
            assert(response.ok && response.value.status == 204, response.error.message);
            assert(arena.reset() == Status.ok);
            if (round != 0)
                fixture.elapsedNanos += (MonoTime.currTime - started).total!"nsecs";
            ++fixture.completed;
        }
        assert(fixture.transport.close().code == Status.ok);
        owner.stop();
    }

    @("sequential reactor-fiber exchanges on a reused connection are not paced by a millisecond poll")
    @system unittest
    {
        if (!setting("HTTP").length)
            return;
        ReactorOptions reactors;
        reactors.cores = 1;
        reactors.fiberPoolSize = 4;
        auto loop = Reactor.create(reactors);
        assert(loop.ok, loop.error.message);
        auto fixture = new Sequential;
        assert(fixture.transport.open(ClientOptions.init).code == Status.ok);
        fixture.request = HttpRequest(HttpMethod.get, setting("HTTP") ~ "/zero");
        activeSequential = cast(shared) fixture;
        scope (exit)
            activeSequential = null;
        assert(loop.value.post(0, &sequential, TaskContext(1)).code == Status.ok);
        const ended = loop.value.run();
        assert(ended.code == Status.ok, ended.message);
        assert(fixture.completed == 101);
        // A loopback HTTP/1.1 exchange takes tens of microseconds; 1 ms polls cost several per exchange.
        const average = fixture.elapsedNanos / 100;
        assert(average < 1_000_000, average.to!string ~ " ns per exchange");
    }

    private final class Stages
    {
        HttpClient transport;
        CancelSource stopSlow;
        HttpRequest slow;
        HttpRequest fast;
        bool sawPrefix;
        bool secondStarted;
        bool otherCompleted;
        bool paused;
        uint completed;
        uint expected;
    }

    private shared Stages activeStages;

    // SAFETY: The harness publishes one live fixture across the lifetime of one joined worker.
    // Only tasks on that worker access it while the event loop is running.
    private Stages stageFixture() @trusted nothrow @nogc
    {
        return cast(Stages) activeStages;
    }

    private void stageFinished(Stages fixture) nothrow @nogc
    {
        if (++fixture.completed == fixture.expected)
        {
            assert(fixture.transport.close().code == Status.ok);
            auto owner = Reactor.current();
            owner.stop();
        }
    }

    private void holdTransfer() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto fixture = stageFixture();
        auto context = fixture.stopSlow.context();
        ubyte[1] memory;
        auto arena = RequestArena(memory[]);
        size_t callbacks;
        const outcome = fixture.transport.stream(fixture.slow, arena, context, (scope const(ubyte)[] bytes) {
            assert(bytes.length != 0);
            ++callbacks;
            fixture.sawPrefix = true;
            if (fixture.paused)
            {
                assert(owner.yieldUntil(Deadline.afterMillis(80)).code == Status.ok);
                assert(fixture.otherCompleted);
            }
            return Error.init;
        });
        assert(outcome.error.code == Status.cancelled && callbacks == 1, outcome.error.message);
        assert(arena.reset() == Status.ok);
        stageFinished(fixture);
    }

    private void secondTransfer() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto fixture = stageFixture();
        while (!fixture.sawPrefix)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        assert(fixture.transport.close().code == Status.conflict);
        auto limit = CancelSource.create(Context.init, Deadline.afterMillis(fixture.paused ? 5_000 : 80));
        assert(limit.ok);
        auto context = limit.value.context();
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        fixture.secondStarted = true;
        const outcome = fixture.transport.send(fixture.fast, arena, context);
        if (fixture.paused)
            assert(outcome.ok && outcome.value.status == 200, outcome.error.message);
        else
            assert(outcome.error.code == Status.timedOut, outcome.error.message);

        fixture.otherCompleted = true;
        fixture.stopSlow.cancel();
        stageFinished(fixture);
    }

    private void queueFull() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto fixture = stageFixture();
        while (!fixture.secondStarted)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        Context context;
        const outcome = fixture.transport.send(fixture.fast, arena, context);
        assert(outcome.error.code == Status.resourceExhausted && arena.stats().used == 0);
        stageFinished(fixture);
    }

    private void exerciseStages(bool paused) @system
    {
        ReactorOptions reactors;
        reactors.backend = Backend.epoll;
        reactors.cores = 1;
        reactors.fiberPoolSize = 3;
        auto loop = Reactor.create(reactors);
        assert(loop.ok, loop.error.message);

        auto fixture = new Stages;
        fixture.paused = paused;
        fixture.expected = paused ? 2 : 3;
        fixture.slow.url = setting("HTTP") ~ (paused ? "/bytes?n=8388608" : "/late");
        fixture.fast.url = paused ? setting("OTHER") ~ "/" : setting("HTTP") ~ "/zero";
        auto stop = CancelSource.create(Context.init, Deadline.none());
        assert(stop.ok);
        move(stop.value, fixture.stopSlow);
        ClientOptions options;
        options.maxConnections = paused ? 2 : 1;
        options.maxConnectionsPerOrigin = 1;
        assert(fixture.transport.open(options).code == Status.ok);
        activeStages = cast(shared) fixture;
        scope (exit)
            activeStages = null;
        assert(loop.value.post(0, &holdTransfer).code == Status.ok);
        assert(loop.value.post(0, &secondTransfer).code == Status.ok);
        if (!paused)
            assert(loop.value.post(0, &queueFull).code == Status.ok);
        const ended = loop.value.run();
        assert(ended.code == Status.ok, ended.message);
        assert(fixture.completed == fixture.expected);
        const stats = loop.value.workerStats(0);
        assert(stats.ok && stats.value.gcAllocated == 0);
    }

    @("bounded queue, paused consumer backpressure and cancellation preserve owner progress")
    @system unittest
    {
        if (setting("HTTP").length)
        {
            exerciseStages(false);
            exerciseStages(true);
        }
    }
}
