module app;

import cache_probe : inspect, measure, payload;
import flint.arena : RequestArena, Status;
import flint.engine.cache : Cache, CacheOptions;
import flint.conc : Context;

@safe:

private final class Workload
{
    Cache cache;

    uint operation(uint worker, uint action, size_t bytes) nothrow @nogc
    {
        Context context;
        ubyte[4096] scratch;
        scope RequestArena arena = RequestArena(scratch[]);
        const sharedKey = cast(const(ubyte)[])(bytes == 64 ? "hit64" : "hit4096");
        const missing = cast(const(ubyte)[]) "miss";
        const ubyte[2] key = [0, cast(ubyte) worker];
        final switch (action)
        {
        case 0:
            return inspect(cache.get(sharedKey, arena, context), arena);
        case 1:
            return cache.get(missing, arena, context).error.code == Status.notFound ? 2 : 0;
        case 2:
            return cache.put(key[], payload[0 .. bytes], context).code == Status.ok ? 3 : 0;
        case 3:
            return cache.evict(key[], context).code == Status.ok ? 4 : 0;
        }
    }

    ulong[2] locks() nothrow @nogc
    {
        const stats = cache.stats();
        return [stats.lockAcquisitions, stats.lockWaitNanos];
    }
}

@system int main()
{
    auto work = new Workload;
    CacheOptions options;
    options.byteCapacity = 4 * 1024 * 1024;
    options.entryCapacity = 4096;
    options.measureLockWait = true;
    if (work.cache.open(options).code != Status.ok)
        return 1;
    scope (exit)
        work.cache.close();
    Context context;
    if (work.cache.put(cast(const(ubyte)[]) "hit64", payload[0 .. 64], context).code != Status.ok
            || work.cache.put(cast(const(ubyte)[]) "hit4096", payload[], context).code != Status.ok)
        return 1;
    return measure(&work.operation, &work.locks);
}
