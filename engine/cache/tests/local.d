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
