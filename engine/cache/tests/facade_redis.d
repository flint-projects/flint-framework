module flint.cache.facade_redis_test;

version (FlintNativeHiredis)
{
    import flint.arena : RequestArena, Status;
    import flint.cache : Cache, CacheBackend, CacheLoader, CacheOptions, getOrLoad;
    import flint.conc : Context, Deadline;
    import std.process : environment;

@safe:

    @("the public Redis cache facade coalesces loader publication with eviction")
    unittest
    {
        const address = environment.get("FLINT_CACHE_REDIS_REAL", "");
        if (address.length == 0)
            return;
        CacheOptions options;
        options.backend = CacheBackend.redis;
        options.redisUrl = address;
        options.redisNamespace = "flint-facade";
        Cache cache;
        assert(cache.open(options).code == Status.ok);
        scope (exit)
            assert(cache.close().code == Status.ok);
        auto context = Context.init.withDeadline(Deadline.afterMillis(6000));
        assert(cache.clear(context).code == Status.ok);
        ubyte[2048] scratch;
        scope RequestArena arena = RequestArena(scratch[]);
        ubyte[3] key = ['x', 0, 'y'];
        uint calls;
        CacheLoader loader = (ref scope RequestArena destination, ref Context) @safe nothrow @nogc {
            ++calls;
            return destination.copyIn(cast(const(ubyte)[]) "payload");
        };
        const loaded = getOrLoad(cache, key[], 30_000_000_000L, arena, context, loader);
        assert(loaded.ok && loaded.value.length == 7 && calls == 1);
        assert(getOrLoad(cache, key[], 30_000_000_000L, arena, context, loader).ok && calls == 1);
        assert(cache.evict(key[], context).code == Status.ok);
        assert(cache.get(key[], arena, context).error.code == Status.notFound);
        assert(getOrLoad(cache, key[], 0, arena, context, loader).ok && calls == 2);
        assert(cache.get(key[], arena, context).error.code == Status.notFound);
        assert(cache.clear(context).code == Status.ok);
    }
}
