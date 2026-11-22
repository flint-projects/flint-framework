module flint.cache.local_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.lifetime : move;
import core.thread : Thread;
import core.time : msecs;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.cache : Cache, CacheLoader, CacheOptions, getOrLoad;
import flint.conc : CancelSource, Context, Deadline;

@safe:

private long simulated;

private long clock() nothrow @nogc
{
    return simulated;
}

private CacheOptions settings(size_t bytes, uint entries) nothrow @nogc
{
    auto options = CacheOptions.init;
    options.byteCapacity = bytes;
    options.entryCapacity = entries;
    options.stripes = 1;
    options.clock = &clock;
    return options;
}

@("binary keys and output are copied by length across TTL and generation boundaries")
unittest
{
    Cache cache;
    Context context;
    ubyte[64] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    simulated = 20;
    assert(cache.open(settings(128, 8)).code == Status.ok);
    scope (exit)
        cache.close();
    ubyte[3] key = [1, 0, 2];
    ubyte[4] value = [0, 4, 255, 2];
    assert(cache.put(key[], value[], 10, context).code == Status.ok);
    assert(cache.put(null, null, 50, context).code == Status.ok);
    value[] = 9;
    auto found = cache.get(key[], arena, context);
    assert(found.ok);
    assert(arena.read(found.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == [0, 4, 255, 2]);
        }) == Status.ok);
    assert(cache.get(key[0 .. 2], arena, context).error.code == Status.notFound);
    assert(cache.get(null, arena, context).ok);
    simulated = 29;
    assert(cache.get(key[], arena, context).ok);
    simulated = 30;
    assert(cache.get(key[], arena, context).error.code == Status.notFound);
    simulated = 22;
    assert(cache.get(key[], arena, context).error.code == Status.notFound);
    assert(cache.put(null, null, 0, context).code == Status.ok);
    assert(cache.get(null, arena, context).error.code == Status.notFound);
    assert(cache.put(key[], value[], -1, context).code == Status.invalidArgument);
}

@("entry and byte pressure evict the least recently touched item in one stripe")
unittest
{
    Cache cache;
    Context context;
    ubyte[64] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    simulated = 0;
    assert(cache.open(settings(8, 2)).code == Status.ok);
    scope (exit)
        cache.close();
    assert(cache.put(cast(const(ubyte)[]) "a", cast(const(ubyte)[]) "aaa", 99, context).code == Status.ok);
    assert(cache.put(cast(const(ubyte)[]) "b", cast(const(ubyte)[]) "bbb", 99, context).code == Status.ok);
    assert(cache.get(cast(const(ubyte)[]) "a", arena, context).ok);
    assert(cache.put(cast(const(ubyte)[]) "c", cast(const(ubyte)[]) "ccc", 99, context).code == Status.ok);
    assert(cache.get(cast(const(ubyte)[]) "b", arena, context).error.code == Status.notFound);
    assert(cache.put(cast(const(ubyte)[]) "d", cast(const(ubyte)[]) "too large", 99, context).code
            == Status.resourceExhausted);
    assert(cache.get(cast(const(ubyte)[]) "a", arena, context).ok);
    assert(cache.put(cast(const(ubyte)[]) "a", cast(const(ubyte)[]) "12345", 99, context).code == Status.ok);
    assert(cache.get(cast(const(ubyte)[]) "c", arena, context).error.code == Status.notFound);
    assert(cache.clear(context).code == Status.ok);
    assert(cache.get(cast(const(ubyte)[]) "a", arena, context).error.code == Status.notFound);
}

private final class PausedLoad
{
    shared uint calls;
    shared bool finish;

    Result!Buffer invoke(ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        atomicOp!"+="(calls, 1U);
        const timeout = Deadline.afterMillis(3000);
        while (!atomicLoad(finish))
        {
            const outcome = context.check();
            if (outcome.code != Status.ok)
                return Result!Buffer(Buffer.init, outcome);
            if (Deadline.afterMillis(0).monotonicNanoseconds >= timeout.monotonicNanoseconds)
                return Result!Buffer(Buffer.init, Error(Status.timedOut, "fixture exceeded wait"));
            Thread.sleep(1.msecs);
        }
        return arena.copyIn(cast(const(ubyte)[]) "value");
    }
}

private Thread spawn(Cache cache, CancelSource* source, PausedLoad load, Status* outcome) @system
{
    return new Thread({
        Context context = source.context();
        ubyte[32] scratch;
        scope RequestArena arena = RequestArena(scratch[]);
        *outcome = getOrLoad(cache, cast(const(ubyte)[]) "load", 10_000_000_000, arena, context, &load.invoke)
            .error.code;
    }).start();
}

private void waitForParticipants(ref Cache cache, uint count)
{
    foreach (_; 0 .. 3000)
    {
        if (cache.testParticipants() == count)
            return;
        Thread.sleep(1.msecs);
    }
    assert(0, "fixture participants did not join the same flight");
}

@("100 callers share one load and 99 can cancel independently")
@system unittest
{
    Cache cache;
    assert(cache.open(settings(256, 8)).code == Status.ok);
    scope (exit)
        cache.close();
    auto load = new PausedLoad;
    auto owners = new CancelSource[100];
    auto outcomes = new Status[100];
    Thread[100] threads;
    foreach (index; 0 .. threads.length)
    {
        auto created = CancelSource.create(Context.init, Deadline.none());
        assert(created.ok);
        owners[index] = move(created.value);
        threads[index] = spawn(cache, &owners[index], load, &outcomes[index]);
    }
    waitForParticipants(cache, 100);
    foreach (ref source; owners[0 .. 99])
        source.cancel();
    atomicStore(load.finish, true);
    foreach (index, thread; threads)
    {
        thread.join();
        assert(outcomes[index] == (index < 99 ? Status.cancelled : Status.ok));
    }
    assert(atomicLoad(load.calls) == 1);
}

@("explicit eviction during a load prevents late publication")
@system unittest
{
    Cache cache;
    assert(cache.open(settings(256, 8)).code == Status.ok);
    scope (exit)
        cache.close();
    auto load = new PausedLoad;
    auto source = CancelSource.create(Context.init, Deadline.none());
    Status status;
    auto worker = spawn(cache, &source.value, load, &status);
    waitForParticipants(cache, 1);
    Context context;
    ubyte[32] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    assert(cache.evict(cast(const(ubyte)[]) "load", context).code == Status.ok);
    atomicStore(load.finish, true);
    worker.join();
    assert(status == Status.ok);
    assert(cache.get(cast(const(ubyte)[]) "load", arena, context).error.code == Status.notFound);
}

@("the monitor cancels a shared loader after its last caller leaves")
@system unittest
{
    Cache cache;
    assert(cache.open(settings(256, 8)).code == Status.ok);
    scope (exit)
        cache.close();
    auto load = new PausedLoad;
    auto source = CancelSource.create(Context.init, Deadline.none());
    Status status;
    auto worker = spawn(cache, &source.value, load, &status);
    waitForParticipants(cache, 1);
    source.value.cancel();
    worker.join();
    assert(status == Status.cancelled);
    assert(atomicLoad(load.calls) == 1 && !atomicLoad(load.finish));
}

@("an explicit put during a load is not overwritten by the late loader result")
@system unittest
{
    Cache cache;
    assert(cache.open(settings(256, 8)).code == Status.ok);
    scope (exit)
        cache.close();
    auto load = new PausedLoad;
    auto source = CancelSource.create(Context.init, Deadline.none());
    Status status;
    auto worker = spawn(cache, &source.value, load, &status);
    waitForParticipants(cache, 1);
    Context context;
    ubyte[32] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    assert(cache.put(cast(const(ubyte)[]) "load", cast(const(ubyte)[]) "fresh", 10_000_000_000, context).code
            == Status.ok);
    atomicStore(load.finish, true);
    worker.join();
    assert(status == Status.ok);
    const found = cache.get(cast(const(ubyte)[]) "load", arena, context);
    assert(found.ok);
    bool fresh;
    assert(arena.read(found.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            fresh = bytes == cast(const(ubyte)[]) "fresh";
        }) == Status.ok);
    assert(fresh, "a stale loader result replaced a newer put");
}

private ubyte[2] numbered(uint index) nothrow @nogc
{
    return [cast(ubyte)(index >> 8), cast(ubyte) index];
}

private uint present(ref Cache cache, uint keys, ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    uint found;
    foreach (index; 0 .. keys)
    {
        const key = numbered(index);
        if (cache.get(key[], arena, context).ok)
            ++found;
        assert(arena.reset() == Status.ok);
    }
    return found;
}

@("capacity_bound: an entry capacity below the stripe count stays bounded across every stripe")
unittest
{
    Cache cache;
    Context context;
    ubyte[64] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    simulated = 0;
    auto options = settings(1 << 20, 10);
    options.stripes = 64;
    assert(cache.open(options).code == Status.ok);
    scope (exit)
        cache.close();
    // 256 distinct keys reach every stripe, including stripes that own no entry slot.
    foreach (index; 0 .. 256)
    {
        const key = numbered(index);
        assert(cache.put(key[], cast(const(ubyte)[]) "v", 99, context).code == Status.ok);
    }
    const kept = present(cache, 256, arena, context);
    assert(kept > 0 && kept <= 10);
    foreach (_; 0 .. 128)
        assert(cache.sweep(context).code == Status.ok);
}

@("capacity_bound: entry and byte caps hold across 64 stripes under 8x entry and 16x byte pressure")
unittest
{
    Cache cache;
    Context context;
    ubyte[64] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    simulated = 0;
    auto options = settings(1 << 20, 128);
    options.stripes = 64;
    assert(cache.open(options).code == Status.ok);
    scope (exit)
        cache.close();
    foreach (index; 0 .. 1024)
    {
        const key = numbered(index);
        assert(cache.put(key[], cast(const(ubyte)[]) "value", 99, context).code == Status.ok);
    }
    const kept = present(cache, 1024, arena, context);
    assert(kept > 0 && kept <= 128);

    // Byte cap: 32 records of 2 + 30 bytes fill 1 KiB exactly; any further record evicts.
    Cache bytes;
    auto tight = settings(1024, 4096);
    tight.stripes = 64;
    assert(bytes.open(tight).code == Status.ok);
    scope (exit)
        bytes.close();
    ubyte[30] payload = 7;
    foreach (index; 0 .. 32)
    {
        const key = numbered(index);
        assert(bytes.put(key[], payload[], 99, context).code == Status.ok);
    }
    assert(present(bytes, 32, arena, context) == 32);
    foreach (index; 32 .. 512)
    {
        const key = numbered(index);
        const stored = bytes.put(key[], payload[], 99, context);
        // A stripe whose own list cannot free enough bytes reports exhaustion instead of evicting elsewhere.
        assert(stored.code == Status.ok || stored.code == Status.resourceExhausted);
    }
    assert(present(bytes, 512, arena, context) <= 32);
}

@("binary_keys: empty, NUL-prefixed and NUL-suffixed keys and values never alias across 64 stripes")
unittest
{
    Cache cache;
    Context context;
    ubyte[256] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    simulated = 0;
    auto options = settings(4096, 64);
    options.stripes = 64;
    assert(cache.open(options).code == Status.ok);
    scope (exit)
        cache.close();
    static immutable string[8] keys = ["", "\0", "\0\0", "a", "a\0", "\0a", "a\0b", "a\0c"];
    static immutable string[8] values = ["k0", "", "\0", "\0\0\0", "a", "x\0y", "\0", "zz\0"];
    foreach (index, key; keys)
        assert(cache.put(cast(const(ubyte)[]) key, cast(const(ubyte)[]) values[index], 99, context).code == Status.ok);
    foreach (index, key; keys)
    {
        const found = cache.get(cast(const(ubyte)[]) key, arena, context);
        assert(found.ok);
        assert(found.value.length() == values[index].length);
        bool equal;
        assert(arena.read(found.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                equal = bytes == cast(const(ubyte)[]) values[index];
            }) == Status.ok);
        assert(equal);
    }
    assert(cache.get(cast(const(ubyte)[]) "\0\0\0", arena, context).error.code == Status.notFound);
    assert(cache.get(cast(const(ubyte)[]) "a\0bc", arena, context).error.code == Status.notFound);
}
