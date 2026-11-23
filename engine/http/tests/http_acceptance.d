module flint.engine.http.http_acceptance_test;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.http : ChunkConsumer, ClientOptions, Header, HttpClient, HttpMethod, HttpRequest, HttpResponse;

@safe:

// Acceptance cases from handoff/specs/tier-2/http.md section 7 that http_behavior.d does not isolate.
// Network cases run only under tests/fixture/run.py, which publishes the FLINT_HTTP_* peer settings.
version (FlintNativeCurl)
{
    import core.lifetime : move;
    import flint.engine.reactor : Backend, Reactor, ReactorOptions;
    import std.conv : to;
    import std.process : environment;

    private enum entityLimit = 8 * 1024 * 1024;
    // The peer writes 256 MiB unless the client stops it. Loopback socket buffers and the HTTP/2
    // stream window can hold some MiB beyond the limit, but never a significant part of the entity.
    private enum upstreamCeiling = 64L * 1024 * 1024;

    private string setting(string key)
    {
        return environment.get("FLINT_HTTP_" ~ key, "");
    }

    private ubyte fixtureByte(size_t index) pure nothrow @nogc
    {
        return cast(ubyte)((index * 17 + index / 11) % 251);
    }

    private Result!HttpResponse send(ref HttpClient client, HttpRequest request,
            ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return client.send(request, arena, context);
    }

    private Result!ushort stream(ref HttpClient client, HttpRequest request,
            ref scope RequestArena arena, ref Context context, scope ChunkConsumer consumer) nothrow @nogc
    {
        return client.stream(request, arena, context, consumer);
    }

    private bool bodyIs(ref scope RequestArena arena, Buffer handle, scope const(char)[] expected) nothrow @nogc
    {
        bool matches;
        const checked = arena.read(handle, (scope const(ubyte)[] raw) {
            matches = raw == cast(const(ubyte)[]) expected;
        });
        return checked == Status.ok && matches;
    }

    private struct Upstream
    {
        long written;
        bool aborted;
    }

    /// Ask the peer how many bytes of an endless entity it wrote and whether the client stopped it.
    private Upstream upstreamWritten(ref HttpClient client, string origin, string id)
    {
        ubyte[256] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        const response = send(client, HttpRequest(HttpMethod.get, origin ~ "/written?id=" ~ id), arena, context);
        assert(response.ok && response.value.status == 200, response.error.message);
        char[64] text;
        size_t length;
        assert(arena.read(response.value.body, (scope const(ubyte)[] raw) {
                assert(raw.length <= text.length);
                text[0 .. raw.length] = cast(const(char)[]) raw;
                length = raw.length;
            }) == Status.ok);
        size_t space;
        while (space < length && text[space] != ' ')
            ++space;
        assert(space < length);
        return Upstream(text[0 .. space].to!long, text[space + 1 .. length] == "true");
    }

    @("curl_thread_owner: a second thread cannot drive or close a client bound to its first caller")
    @system unittest
    {
        import core.thread.osthread : Thread;

        HttpClient client;
        assert(client.open(ClientOptions.init).code == Status.ok);
        HttpRequest empty;
        ubyte[64] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        // The first operation binds this thread; the owner's native loop then rejects the empty URL.
        assert(client.send(empty, arena, context).error.code == Status.invalidArgument);

        Status[4] foreign;
        auto worker = new Thread({
            ubyte[64] local;
            auto scratch = RequestArena(local[]);
            Context unrelated;
            scope ChunkConsumer ignore = (scope const(ubyte)[]) @safe nothrow @nogc => Error.init;
            foreign[0] = client.send(empty, scratch, unrelated).error.code;
            foreign[1] = client.stream(empty, scratch, unrelated, ignore).error.code;
            foreign[2] = client.close().code;
            foreign[3] = scratch.stats().used == 0 ? Status.ok : Status.conflict;
        });
        worker.start();
        worker.join();
        assert(foreign == [Status.conflict, Status.conflict, Status.conflict, Status.ok]);
        // The rejected calls did not rebind or close the pool.
        assert(client.send(empty, arena, context).error.code == Status.invalidArgument);
        assert(client.close().code == Status.ok);
    }

    private void exerciseMissingTrust(string clear, string tls)
    {
        ClientOptions options;
        options.caBundle = "/nonexistent/flint-http-acceptance/ca.pem";
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        ubyte[1024] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        // An unreadable CA bundle never falls back to unverified TLS.
        auto response = send(client, HttpRequest(HttpMethod.get, tls ~ "/zero"), arena, context);
        assert(response.error.code == Status.permissionDenied, response.error.message);
        assert(arena.stats().used == 0);
        response = send(client, HttpRequest(HttpMethod.get, clear ~ "/zero"), arena, context);
        assert(response.ok && response.value.status == 204, response.error.message);
    }

    private void exerciseCredentialStripping(string clear)
    {
        ClientOptions options;
        options.followRedirects = true;
        options.destinationPolicy = (scope const(char)[]) @safe nothrow @nogc => true;
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        ubyte[1024] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        // The cross-origin peer answers 409 if any credential field survives the origin change.
        Header[] fields = [
            Header("Authorization", "Bearer opaque"), Header("Proxy-Authorization", "Basic b3BhcXVl"),
            Header("Cookie", "session=internal"), Header("Cookie2", "$Version=1"),
            Header("X-Probe", "kept")
        ];
        const response = send(client, HttpRequest(HttpMethod.get, clear ~ "/location", fields), arena, context);
        assert(response.ok && response.value.status == 200, response.error.message);
        assert(bodyIs(arena, response.value.body, "kept"));
    }

    private void exerciseFlushedChunks(string origin, string ca)
    {
        ClientOptions options;
        options.caBundle = ca;
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        ubyte[1] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        // Every write size from 1 through 4096 bytes is flushed as its own wire chunk or DATA frame.
        foreach (range; [[1, 2048], [2049, 4096]])
        {
            size_t total;
            size_t calls;
            const size = (range[0] + range[1]) * (range[1] - range[0] + 1) / 2;
            const url = origin ~ "/chunks?flush=1&min=" ~ range[0].to!string ~ "&max=" ~ range[1].to!string;
            const result = stream(client, HttpRequest(HttpMethod.get, url), arena, context,
                    (scope const(ubyte)[] bytes) {
                ++calls;
                foreach (byteValue; bytes)
                    assert(byteValue == fixtureByte(total++));
                return Error.init;
            });
            assert(result.ok && result.value == 200 && total == size, result.error.message);
            assert(calls > 1);
        }
        assert(arena.stats().used == 0);
    }

    private void exerciseUpstreamStop(string origin, string label, string ca)
    {
        ClientOptions options;
        options.caBundle = ca;
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        auto storage = new ubyte[entityLimit + 4096];
        auto arena = RequestArena(storage);
        Context context;

        // Buffered: the byte after the limit fails the request and the peer observes the stop.
        const buffered = label ~ "-buffered";
        const response = send(client, HttpRequest(HttpMethod.get, origin ~ "/endless?id=" ~ buffered), arena, context);
        assert(response.error.code == Status.resourceExhausted, response.error.message);
        assert(arena.stats().used == 0);
        auto upstream = upstreamWritten(client, origin, buffered);
        assert(upstream.aborted && upstream.written > entityLimit
                && upstream.written < upstreamCeiling, upstream.written.to!string);

        // Streaming transfers observe the same decoded-byte limit.
        const limitedId = label ~ "-limited";
        size_t delivered;
        const limited = stream(client, HttpRequest(HttpMethod.get,
                origin ~ "/endless?id=" ~ limitedId), arena, context, (scope const(ubyte)[] bytes) {
            foreach (byteValue; bytes)
                assert(byteValue == fixtureByte(delivered++));
            return Error.init;
        });
        assert(limited.error.code == Status.resourceExhausted && delivered <= entityLimit, limited.error.message);
        upstream = upstreamWritten(client, origin, limitedId);
        assert(upstream.aborted && upstream.written > entityLimit
                && upstream.written < upstreamCeiling, upstream.written.to!string);

        delivered = 0;
        const exact = stream(client, HttpRequest(HttpMethod.get, origin ~ "/bytes?n=8388608"),
                arena, context, (scope const(ubyte)[] bytes) {
            delivered += bytes.length;
            return Error.init;
        });
        assert(exact.ok && exact.value == 200 && delivered == entityLimit, exact.error.message);

        // A consumer that stops after its first chunk ends the upstream transfer as well.
        const stoppedId = label ~ "-stopped";
        size_t calls;
        const stopped = stream(client, HttpRequest(HttpMethod.get,
                origin ~ "/endless?id=" ~ stoppedId), arena, context, (scope const(ubyte)[]) {
            ++calls;
            return Error(Status.cancelled, "consumer stopped the endless entity");
        });
        assert(stopped.error.code == Status.cancelled && calls == 1);
        upstream = upstreamWritten(client, origin, stoppedId);
        assert(upstream.aborted && upstream.written < upstreamCeiling, upstream.written.to!string);
        assert(arena.stats().used == 0);
    }

    @("tls_policy, stream_chunks and body_limit acceptance against the local protocol peers")
    unittest
    {
        const clear = setting("HTTP");
        if (!clear.length)
            return;
        const tls = setting("HTTPS");
        const ca = setting("CA");
        exerciseMissingTrust(clear, tls);
        exerciseCredentialStripping(clear);
        exerciseFlushedChunks(clear, ca);
        exerciseFlushedChunks(tls, ca);
        exerciseUpstreamStop(clear, "h1", ca);
        exerciseUpstreamStop(tls, "h2", ca);
    }

    private final class Queued
    {
        HttpClient transport;
        CancelSource stopHolder;
        CancelSource stopQueued;
        HttpRequest holder;
        HttpRequest queued;
        HttpRequest after;
        bool holding;
        bool queuedStarted;
        bool queuedFinished;
        size_t holderCallbacks;
        size_t queuedArenaUsed;
        Status queuedOutcome;
        uint completions;
        bool reused;
    }

    private shared Queued activeQueued;

    // SAFETY: The harness publishes one live fixture across the lifetime of one joined worker.
    // Only tasks on that worker access it while the event loop is running.
    private Queued queuedFixture() @trusted nothrow @nogc
    {
        return cast(Queued) activeQueued;
    }

    private void holdConnection() nothrow @nogc
    {
        auto fixture = queuedFixture();
        auto context = fixture.stopHolder.context();
        ubyte[1] memory;
        auto arena = RequestArena(memory[]);
        const outcome = fixture.transport.stream(fixture.holder, arena, context, (scope const(ubyte)[]) {
            ++fixture.holderCallbacks;
            fixture.holding = true;
            return Error.init;
        });
        assert(outcome.error.code == Status.cancelled && fixture.holderCallbacks == 1, outcome.error.message);
        assert(arena.stats().used == 0 && arena.reset() == Status.ok);
        ++fixture.completions;
    }

    private void queueBehindHolder() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto fixture = queuedFixture();
        while (!fixture.holding)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        auto context = fixture.stopQueued.context();
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        fixture.queuedStarted = true;
        const outcome = fixture.transport.send(fixture.queued, arena, context);
        fixture.queuedOutcome = outcome.error.code;
        fixture.queuedArenaUsed = arena.stats().used;
        fixture.queuedFinished = true;
        ++fixture.completions;
    }

    private void cancelQueued() nothrow @nogc
    {
        auto owner = Reactor.current();
        auto fixture = queuedFixture();
        while (!fixture.queuedStarted)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        // The only connection is held, so the second transfer waits in libcurl's pending queue.
        assert(owner.yieldUntil(Deadline.afterMillis(30)).code == Status.ok);
        assert(!fixture.queuedFinished && fixture.completions == 0);
        fixture.stopQueued.cancel();
        while (!fixture.queuedFinished)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        assert(fixture.queuedOutcome == Status.cancelled && fixture.queuedArenaUsed == 0);
        // Exactly one completion was delivered, and the held transfer is still live.
        assert(fixture.completions == 1 && fixture.holderCallbacks == 1);
        fixture.stopHolder.cancel();
        while (fixture.completions != 2)
            assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);

        // Both retired generations released their slots, so the one-connection pool is usable again.
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        auto limit = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(limit.ok);
        auto context = limit.value.context();
        const next = fixture.transport.send(fixture.after, arena, context);
        assert(next.ok && next.value.status == 204, next.error.message);
        fixture.reused = true;
        assert(fixture.transport.close().code == Status.ok);
        owner.stop();
    }

    @("cancel_stages: explicit cancellation of a queued transfer delivers one completion and frees its slot")
    @system unittest
    {
        const origin = setting("HTTP");
        if (!origin.length)
            return;
        ReactorOptions reactors;
        version (OSX) // the readiness backend: kqueue on macOS, epoll on Linux (ADR-024)
            reactors.backend = Backend.kqueue;
        else version (Windows) // IOCP, the one Windows backend (ADR-026)
            reactors.backend = Backend.iocp;
        else
            reactors.backend = Backend.epoll;
        reactors.cores = 1;
        reactors.fiberPoolSize = 3;
        auto loop = Reactor.create(reactors);
        assert(loop.ok, loop.error.message);

        auto fixture = new Queued;
        fixture.holder.url = origin ~ "/late";
        fixture.queued.url = origin ~ "/zero";
        fixture.after.url = origin ~ "/zero";
        auto holder = CancelSource.create(Context.init, Deadline.none());
        auto queued = CancelSource.create(Context.init, Deadline.none());
        assert(holder.ok && queued.ok);
        move(holder.value, fixture.stopHolder);
        move(queued.value, fixture.stopQueued);
        ClientOptions options;
        options.maxConnections = 1;
        options.maxConnectionsPerOrigin = 1;
        assert(fixture.transport.open(options).code == Status.ok);
        activeQueued = cast(shared) fixture;
        scope (exit)
            activeQueued = null;
        assert(loop.value.post(0, &holdConnection).code == Status.ok);
        assert(loop.value.post(0, &queueBehindHolder).code == Status.ok);
        assert(loop.value.post(0, &cancelQueued).code == Status.ok);
        const ended = loop.value.run();
        assert(ended.code == Status.ok, ended.message);
        assert(fixture.completions == 2 && fixture.reused);
        const stats = loop.value.workerStats(0);
        assert(stats.ok && stats.value.gcAllocated == 0);
    }
}
