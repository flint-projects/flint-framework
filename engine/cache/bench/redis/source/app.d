/// Exercise the public Redis cache backend against the verified TLS fixture.
module app;

import flint.arena : RequestArena, Status;
import flint.engine.cache : Cache, CacheBackend, CacheOptions;
import flint.conc : Context;
import redis_workload : Observation, fixture, run;
import std.exception : enforce;

@safe:

/// Run the two Redis value sizes with a single warmed cache.
int main()
{
    CacheOptions options;
    options.backend = CacheBackend.redis;
    options.redisUrl = fixture("REAL_TLS");
    options.redisCaBundle = fixture("CA");
    options.redisNamespace = "probe";
    Cache cache;
    enforce(cache.open(options).code == Status.ok, "native Redis cache provider unavailable");
    scope (exit)
        enforce(cache.close().code == Status.ok, "Redis cache shutdown failed");

    Context context;
    ubyte[4352] storage;
    auto arena = RequestArena(storage[]);
    return run((scope const(ubyte)[] key, scope const(ubyte)[] value) {
        return cycle(cache, key, value, arena, context);
    });
}

private Observation cycle(ref Cache cache, scope const(ubyte)[] key, scope const(ubyte)[] value,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    if (arena.reset() != Status.ok || cache.put(key, value, context).code != Status.ok)
        return Observation.init;
    const first = cache.get(key, arena, context);
    if (!first.ok())
        return Observation.init;
    Observation result;
    const viewed = arena.read(first.value, (scope const(ubyte)[] bytes) {
        result.ok = bytes == value;
        foreach (item; bytes)
            result.checksum += item;
    });
    result.ok = result.ok && viewed == Status.ok && cache.evict(key, context).code == Status.ok
        && cache.get(key, arena, context).error.code == Status.notFound;
    return result;
}
