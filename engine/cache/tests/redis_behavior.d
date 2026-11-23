module flint.engine.cache.redis_behavior_test;

version (FlintNativeHiredis)
{
    import core.memory : GC;
    import core.thread.osthread : Thread;
    import core.time : msecs;
    import flint.arena : Buffer, RequestArena, Result, Status;
    import flint.engine.cache : Cache, CacheBackend, getOrLoad;
    import flint.engine.cache.remote : RemoteStore;
    import flint.engine.cache.types : CacheOptions;
    import flint.conc : CancelSource, Context, Deadline;
    import flint.engine.reactor : Backend, Reactor, ReactorOptions;
    import std.file : exists, readText;
    import std.process : environment;

@safe:

    private enum ttl = 90_000_000_000L;

    private string peer(string name)
    {
        return environment.get("FLINT_CACHE_REDIS_" ~ name, "");
    }

    private CacheOptions settings(string url, string name = "checks")
    {
        CacheOptions options;
        options.redisUrl = url;
        options.redisNamespace = name;
        return options;
    }

    private bool matches(ref scope RequestArena arena, Buffer data, scope const(ubyte)[] expected) nothrow @nogc
    {
        bool equal;
        const status = arena.read(data, (scope const(ubyte)[] bytes) { equal = bytes == expected; });
        return status == Status.ok && equal;
    }

    @("plaintext loopback admission and namespace validation")
    unittest
    {
        const publicAddress = RemoteStore.open(settings("redis://cache.example.invalid"));
        assert(publicAddress.error.code == Status.permissionDenied);
        const badNamespace = RemoteStore.open(settings("redis://localhost", "*"));
        assert(badNamespace.error.code == Status.invalidArgument);
        const badCredentials = RemoteStore.open(settings("rediss://user:broken%g0@localhost"));
        assert(badCredentials.error.code == Status.invalidArgument);
        const badPort = RemoteStore.open(settings("redis://127.0.0.1:99999"));
        assert(badPort.error.code == Status.invalidArgument);
    }

    @("Valkey RESP3 AUTH, binary values, TTL and ordered namespace clear")
    unittest
    {
        const address = peer("REAL");
        if (!address.length)
            return;
        auto first = RemoteStore.open(settings(address, "first"));
        auto second = RemoteStore.open(settings(address, "second"));
        assert(first.ok && second.ok);
        scope (exit)
        {
            assert(first.value.close().code == Status.ok);
            assert(second.value.close().code == Status.ok);
        }
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        const a = first.value.ready(context);
        assert(a.code == Status.ok, a.message);
        const b = second.value.ready(context);
        assert(b.code == Status.ok, b.message);

        const ubyte[3] key = ['q', 0, 'x'];
        const ubyte[2] beta = [0, 'B'];
        const ubyte[3] data = ['v', 0, 'u'];
        const before = GC.stats().allocatedInCurrentThread;
        auto put = first.value.putCommand(key[], data[], ttl);
        auto empty = first.value.putCommand(null, null, ttl);
        auto other = second.value.putCommand(key[], beta[], ttl);
        assert(put.ok && empty.ok && other.ok);
        assert(first.value.complete(put.value, context).code == Status.ok);
        assert(first.value.complete(empty.value, context).code == Status.ok);
        assert(second.value.complete(other.value, context).code == Status.ok);

        ubyte[2048] storage;
        auto arena = RequestArena(storage[]);
        auto got = first.value.get(key[], arena, context);
        assert(got.ok && matches(arena, got.value, data[]));
        got = first.value.get(null, arena, context);
        assert(got.ok && matches(arena, got.value, null));
        assert(GC.stats().allocatedInCurrentThread == before);
        assert(first.value.get(cast(const(ubyte)[]) "q", arena, context).error.code == Status.notFound);

        foreach (ubyte suffix; 1 .. 150)
        {
            const ubyte[2] varied = ['a', suffix];
            const added = first.value.putCommand(varied[], data[], ttl);
            assert(added.ok && first.value.complete(added.value, context).code == Status.ok);
        }

        const cleared = first.value.clearCommand();
        const later = first.value.putCommand(key[], beta[], ttl);
        assert(cleared.ok && later.ok && first.value.complete(later.value, context).code == Status.ok);
        assert(first.value.complete(cleared.value, context).code == Status.ok);
        got = first.value.get(key[], arena, context);
        assert(got.ok && matches(arena, got.value, beta[]));
        got = second.value.get(key[], arena, context);
        assert(got.ok && matches(arena, got.value, beta[]));
        assert(first.value.get(null, arena, context).error.code == Status.notFound);
        foreach (ubyte suffix; 1 .. 150)
        {
            const ubyte[2] varied = ['a', suffix];
            assert(first.value.get(varied[], arena, context).error.code == Status.notFound);
        }

        const expiry = first.value.putCommand(key[], data[], 30_000_000L);
        assert(expiry.ok && first.value.complete(expiry.value, context).code == Status.ok);
        Thread.sleep(80.msecs);
        assert(first.value.get(key[], arena, context).error.code == Status.notFound);
        const removed = second.value.evictCommand(key[]);
        assert(removed.ok && second.value.complete(removed.value, context).code == Status.ok);
        assert(second.value.get(key[], arena, context).error.code == Status.notFound);
    }

    @("TLS enforces endpoint identity and supports length-preserving HELLO AUTH")
    unittest
    {
        const address = peer("TLS");
        if (!address.length)
            return;
        auto options = settings(address);
        options.redisCaBundle = peer("CA");
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(deadline.ok);
        auto context = deadline.value.context();

        auto secure = RemoteStore.open(options);
        assert(secure.ok);
        scope (exit)
            assert(secure.value.close().code == Status.ok);
        const ready = secure.value.ready(context);
        assert(ready.code == Status.ok, ready.message);
        ubyte[32] storage;
        auto arena = RequestArena(storage[]);
        const found = secure.value.get(null, arena, context);
        assert(found.ok && matches(arena, found.value, cast(const(ubyte)[]) "verified"));

        foreach (url; [peer("MISMATCH"), peer("WRONGPASS")])
        {
            options.redisUrl = url;
            auto bad = RemoteStore.open(options);
            assert(bad.ok);
            const rejected = bad.value.ready(context);
            assert(rejected.code == Status.permissionDenied, rejected.message);
            assert(bad.value.close().code == Status.ok);
        }
        options.redisUrl = address;
        options.redisCaBundle = null;
        auto untrusted = RemoteStore.open(options);
        assert(untrusted.ok);
        assert(untrusted.value.ready(context).code == Status.permissionDenied);
        assert(untrusted.value.close().code == Status.ok);
    }

    @("PUSH messages are retired independently and cluster replies are unsupported")
    unittest
    {
        const address = peer("PUSH");
        if (!address.length)
            return;
        auto store = RemoteStore.open(settings(address));
        assert(store.ok);
        scope (exit)
            assert(store.value.close().code == Status.ok);
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        ubyte[256] storage;
        auto arena = RequestArena(storage[]);
        const key = cast(const(ubyte)[]) "data";
        foreach (_; 0 .. 6)
        {
            const found = store.value.get(key, arena, context);
            assert(found.ok && matches(arena, found.value, cast(const(ubyte)[]) "flint:checks:data"));
        }
        assert(store.value.testPushes() == 12);
        foreach (keyName; ["moved", "ask"])
            assert(store.value.get(cast(const(ubyte)[]) keyName, arena, context).error.code == Status.unsupported);
        assert(store.value.get(key, arena, context).ok && store.value.testPushes() == 14);
    }

    @("disconnect settles an uncertain mutation once and never retries it")
    unittest
    {
        const address = peer("DROP");
        if (!address.length)
            return;
        auto store = RemoteStore.open(settings(address));
        assert(store.ok);
        scope (exit)
            assert(store.value.close().code == Status.ok);
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        assert(store.value.ready(context).code == Status.ok);
        const request = store.value.putCommand(null, null, ttl);
        assert(request.ok);
        assert(store.value.complete(request.value, context).code == Status.ioError);
        assert(store.value.complete(request.value, context).code == Status.notFound);
        assert(store.value.putCommand(null, null, ttl).error.code == Status.ioError);
        assert(readText(peer("DROPS")) == "1");
    }

    @("retains one bounded pending generation and detaches cancellation before reuse")
    unittest
    {
        const address = peer("STALL");
        if (!address.length)
            return;
        auto store = RemoteStore.open(settings(address));
        assert(store.ok);
        scope (exit)
            assert(store.value.close().code == Status.ok);
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(5_000));
        assert(source.ok);
        auto parent = source.value.context();
        assert(store.value.ready(parent).code == Status.ok);

        const first = store.value.putCommand(null, null, ttl);
        assert(first.ok);
        foreach (_; 1 .. 1024)
            assert(store.value.putCommand(null, null, ttl).ok);
        assert(store.value.putCommand(null, null, ttl).error.code == Status.resourceExhausted);
        auto stop = CancelSource.create(parent, Deadline.none());
        assert(stop.ok);
        auto context = stop.value.context();
        stop.value.cancel();
        assert(store.value.complete(first.value, context).code == Status.cancelled);
        assert(store.value.complete(first.value, parent).code == Status.notFound);
        assert(store.value.close().code == Status.ok);
    }

    @("oversized, deep, invalid and cross-namespace replies fail safely")
    unittest
    {
        if (!peer("DEPTH").length)
            return;
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(7_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        foreach (name; ["DEPTH", "OVERSIZE", "UNKNOWN", "TRUNCATED", "CROSS"])
        {
            auto store = RemoteStore.open(settings(peer(name)));
            assert(store.ok);
            scope (exit)
                assert(store.value.close().code == Status.ok);
            assert(store.value.ready(context).code == Status.ok);
            if (name == "CROSS")
            {
                const clear = store.value.clearCommand();
                assert(clear.ok);
                assert(store.value.complete(clear.value, context).code == Status.ioError);
                assert(!exists(peer("OUTSIDE_DELETES")));
            }
            else
            {
                ubyte[16] storage;
                auto arena = RequestArena(storage[]);
                const rejected = store.value.get(null, arena, context);
                const expected = name == "DEPTH" || name == "OVERSIZE" ? Status.resourceExhausted : Status.ioError;
                assert(rejected.error.code == expected, rejected.error.message);
                assert(arena.stats().used == 0);
            }
        }
    }

    private final class AppFibers
    {
        Cache cache;
        bool loading;
        bool evicted;
        uint done;
        static immutable ubyte[3] binary = ['m', 0, 'y'];

        void publish() nothrow @nogc
        {
            auto owner = Reactor.current();
            Context context;
            ubyte[256] storage;
            auto arena = RequestArena(storage[]);
            const loaded = getOrLoad(cache, binary, ttl, arena, context, (ref scope RequestArena scratch, ref Context) {
                loading = true;
                while (!evicted)
                {
                    const slept = owner.yieldUntil(Deadline.afterMillis(1));
                    if (slept.code != Status.ok)
                        return Result!Buffer(Buffer.init, slept);
                }
                return scratch.copyIn(cast(const(ubyte)[]) "new value");
            });
            assert(loaded.ok && matches(arena, loaded.value, cast(const(ubyte)[]) "new value"));
            assert(cache.get(binary, arena, context).error.code == Status.notFound);
            finished();
        }

        void remove() nothrow @nogc
        {
            auto owner = Reactor.current();
            while (!loading)
                assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
            Context context;
            assert(cache.evict(binary, context).code == Status.ok);
            evicted = true;
            finished();
        }

        private void finished() nothrow @nogc
        {
            if (++done != 2)
                return;
            assert(cache.close().code == Status.ok);
            auto owner = Reactor.current();
            owner.stop();
        }
    }

    @("public Redis cache composes with app fibers and preserves flight eviction order")
    unittest
    {
        const address = peer("REAL");
        if (!address.length)
            return;
        auto client = new AppFibers;
        auto options = settings(address, "app-fibers");
        options.backend = CacheBackend.redis;
        assert(client.cache.open(options).code == Status.ok);
        ReactorOptions reactors;
        version (OSX) // the readiness backend: kqueue on macOS, epoll on Linux (ADR-024)
            reactors.backend = Backend.kqueue;
        else version (Windows) // IOCP, the one Windows backend (ADR-026)
            reactors.backend = Backend.iocp;
        else
            reactors.backend = Backend.epoll;
        reactors.cores = 1;
        reactors.fiberPoolSize = 2;
        auto owner = Reactor.create(reactors);
        assert(owner.ok);
        assert(owner.value.postStartup(0, &client.publish).code == Status.ok);
        assert(owner.value.postStartup(0, &client.remove).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(client.done == 2);
        const observed = owner.value.workerStats(0);
        assert(observed.ok && observed.value.gcAllocated == 0);
    }

    private final class PutFibers
    {
        Cache cache;
        bool loading;
        bool written;
        bool fresh;
        uint done;
        static immutable ubyte[3] binary = ['p', 0, 'w'];

        void load() nothrow @nogc
        {
            auto owner = Reactor.current();
            Context context;
            ubyte[256] storage;
            auto arena = RequestArena(storage[]);
            const loaded = getOrLoad(cache, binary, ttl, arena, context, (ref scope RequestArena scratch, ref Context) {
                loading = true;
                while (!written)
                {
                    const slept = owner.yieldUntil(Deadline.afterMillis(1));
                    if (slept.code != Status.ok)
                        return Result!Buffer(Buffer.init, slept);
                }
                return scratch.copyIn(cast(const(ubyte)[]) "stale value");
            });
            assert(loaded.ok);
            const current = cache.get(binary, arena, context);
            fresh = current.ok && matches(arena, current.value, cast(const(ubyte)[]) "fresh value");
            finished();
        }

        void write() nothrow @nogc
        {
            auto owner = Reactor.current();
            while (!loading)
                assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
            Context context;
            assert(cache.put(binary, cast(const(ubyte)[]) "fresh value", ttl, context).code == Status.ok);
            written = true;
            finished();
        }

        private void finished() nothrow @nogc
        {
            if (++done != 2)
                return;
            Context context;
            assert(cache.evict(binary, context).code == Status.ok);
            assert(cache.close().code == Status.ok);
            auto owner = Reactor.current();
            owner.stop();
        }
    }

    @("a Redis put during a flight is not overwritten by the late loader result")
    unittest
    {
        const address = peer("REAL");
        if (!address.length)
            return;
        auto client = new PutFibers;
        auto options = settings(address, "put-fibers");
        options.backend = CacheBackend.redis;
        assert(client.cache.open(options).code == Status.ok);
        ReactorOptions reactors;
        version (OSX) // the readiness backend: kqueue on macOS, epoll on Linux (ADR-024)
            reactors.backend = Backend.kqueue;
        else version (Windows) // IOCP, the one Windows backend (ADR-026)
            reactors.backend = Backend.iocp;
        else
            reactors.backend = Backend.epoll;
        reactors.cores = 1;
        reactors.fiberPoolSize = 2;
        auto owner = Reactor.create(reactors);
        assert(owner.ok);
        assert(owner.value.postStartup(0, &client.load).code == Status.ok);
        assert(owner.value.postStartup(0, &client.write).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(client.done == 2);
        assert(client.fresh, "a stale Redis loader result replaced a newer put");
    }
}
