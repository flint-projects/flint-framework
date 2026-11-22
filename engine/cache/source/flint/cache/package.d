module flint.cache;

import core.atomic : atomicLoad, cas;
import core.thread : Thread;
import core.time : msecs;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.cache.flight : Admission, Flights;
import flint.cache.local : LocalStore, hashBytes;
import flint.cache.remote : RemoteStore;
import flint.conc : Context, Deadline;
import flint.reactor : Reactor;

public import flint.cache.types : CacheBackend, Cacheable, CacheClock, CacheEvict, CacheLoader,
    CacheOptions, CacheStats;
public import flint.cache.invocation : CachedCall, evictCommitted, registerCachedCall;

import flint.cache.types : Bytes;

@safe:

/// A cache handle whose copies share the same capacity and shutdown state.
struct Cache
{
    private State control;

    /// Prepare bounded storage and load-coalescing state for this instance.
    Error open(CacheOptions options)
    {
        if (control !is null && control.isOpen)
            return Error(Status.conflict, "cache already open");
        if (options.backend > CacheBackend.redis)
            return Error(Status.invalidArgument, "unknown cache provider");
        if (options.byteCapacity == 0 || options.byteCapacity > 64 * 1024 * 1024
                || options.entryCapacity == 0 || options.entryCapacity > 65_536
                || options.stripes == 0 || options.stripes > 1024 || options.defaultTtlNanos < 0)
            return Error(Status.invalidArgument, "invalid cache limits");
        auto created = new State(options);
        if (options.backend == CacheBackend.redis)
        {
            auto remote = RemoteStore.open(options);
            if (!remote.ok)
                return remote.error;
            created.remote = remote.value;
        }
        const ready = created.flights.start();
        if (ready.code != Status.ok)
        {
            created.remote.close();
            return ready;
        }
        control = created;
        return Error.init;
    }

    /// Copy an unexpired value into the supplied arena.
    Result!Buffer get(scope const(ubyte)[] key, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        if (control is null)
            return Result!Buffer(Buffer.init, inactive());
        return control.read(hashBytes(key), key, arena, context);
    }

    /// Store owned copies with the explicitly supplied lifetime in nanoseconds.
    Error put(scope const(ubyte)[] key, scope const(ubyte)[] value, long ttlNanos, ref Context context) nothrow @nogc
    {
        if (control is null)
            return inactive();
        if (ttlNanos == 0)
            return evict(key, context);
        return control.write(hashBytes(key), key, value, ttlNanos, context);
    }

    /// Store owned copies for the cache's configured default lifetime.
    Error put(scope const(ubyte)[] key, scope const(ubyte)[] value, ref Context context) nothrow @nogc
    {
        return control is null ? inactive() : put(key, value, control.defaultTtl, context);
    }

    /// Remove a key and invalidate any load already running for it.
    Error evict(scope const(ubyte)[] key, ref Context context) nothrow @nogc
    {
        if (control is null)
            return inactive();
        return control.evict(hashBytes(key), key, context);
    }

    /// Invalidate all stored values and pending loads.
    Error clear(ref Context context) nothrow @nogc
    {
        if (control is null)
            return inactive();
        return control.clear(context);
    }

    /// Sweep at most 64 local metadata slots on this maintenance tick.
    Error sweep(ref Context context) nothrow @nogc
    {
        if (control is null || !control.isOpen)
            return inactive();
        const ready = context.check();
        if (ready.code == Status.ok && control.local !is null)
            control.local.sweep(control.now());
        return ready;
    }

    /// Cancel pending loads and stop future operations on all copies of the handle.
    Error close() nothrow @nogc
    {
        return control is null ? Error.init : control.close();
    }

    /// Snapshot the optional local lock counters.
    CacheStats stats() nothrow @nogc
    {
        return control is null || control.local is null ? CacheStats.init : control.local.stats();
    }

    version (unittest) package(flint.cache) uint testParticipants() nothrow @nogc
    {
        return control.flights.participants();
    }
}

private Error inactive() pure nothrow @nogc
{
    return Error(Status.unavailable, "cache is closed");
}

private long realClock() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

private final class State
{
    LocalStore local;
    RemoteStore remote;
    Flights flights;
    long defaultTtl;
    CacheClock clock;
    private shared bool closed;
    private shared long watermark;

    this(CacheOptions options)
    {
        const count = options.stripes < options.entryCapacity ? options.stripes : options.entryCapacity;
        if (options.backend == CacheBackend.local)
            local = new LocalStore(options.byteCapacity, options.entryCapacity, count, options.measureLockWait);
        flights = new Flights(options.byteCapacity);
        defaultTtl = options.defaultTtlNanos;
        clock = options.clock is null ? &realClock : options.clock;
    }

    bool isOpen() const nothrow @nogc
    {
        return !atomicLoad(closed);
    }

    long now() nothrow @nogc
    {
        const sampled = clock();
        for (;;)
        {
            const previous = atomicLoad(watermark);
            if (sampled <= previous)
                return previous;
            if (cas(&watermark, previous, sampled))
                return sampled;
        }
    }

    Result!Buffer read(ulong hash, scope Bytes key, ref scope RequestArena arena, ref Context ctx) nothrow @nogc
    {
        if (!isOpen)
            return Result!Buffer(Buffer.init, inactive());
        return local is null ? remote.get(key, arena, ctx) : local.get(hash, key, now(), arena, ctx);
    }

    Error write(ulong hash, scope Bytes key, scope Bytes value, long ttl, ref Context ctx) nothrow @nogc
    {
        if (ttl < 0)
            return Error(Status.invalidArgument, "negative cache TTL");
        if (!isOpen)
            return inactive();
        if (local is null)
        {
            const ready = remote.ready(ctx);
            if (ready.code != Status.ok)
                return ready;
        }
        // An explicit write supersedes a load already running for the key, as eviction does.
        if (local !is null)
        {
            const mark = flights.idleMark();
            if (mark != 0)
            {
                const stored = store(hash, key, value, ttl, ctx);
                if (stored.code != Status.ok || flights.stillIdle(mark))
                    return stored;
                // A load began meanwhile. Repeat the write in order with its publication.
                Context independent;
                return writeOrdered(hash, key, value, ttl, independent);
            }
        }
        return writeOrdered(hash, key, value, ttl, ctx);
    }

    private Error writeOrdered(ulong hash, scope Bytes key, scope Bytes value, long ttl, ref Context ctx) nothrow @nogc
    {
        Result!ulong queued;
        {
            flights.lock();
            scope (exit)
                flights.unlock();
            if (local is null)
                queued = remote.putCommand(key, value, ttl);
            else
                queued.error = store(hash, key, value, ttl, ctx);
            if (queued.ok)
                flights.invalidate(hash, key);
        }
        return local is null && queued.ok ? remote.complete(queued.value, ctx) : queued.error;
    }

    private Error store(ulong hash, scope Bytes key, scope Bytes value, long ttl, ref Context ctx) nothrow @nogc
    {
        const time = now();
        const expiry = ttl > long.max - time ? long.max : time + ttl;
        return local.put(hash, key, value, expiry, ctx);
    }

    Error evict(ulong hash, scope Bytes key, ref Context context) nothrow @nogc
    {
        if (!isOpen)
            return inactive();
        if (local is null)
        {
            const ready = remote.ready(context);
            if (ready.code != Status.ok)
                return ready;
        }
        else
        {
            const mark = flights.idleMark();
            if (mark != 0)
            {
                const removed = local.evict(hash, key, context);
                if (removed.code != Status.ok || flights.stillIdle(mark))
                    return removed;
                // A load began meanwhile. Repeat the removal in order with its publication.
                Context independent;
                return evictOrdered(hash, key, independent);
            }
        }
        return evictOrdered(hash, key, context);
    }

    private Error evictOrdered(ulong hash, scope Bytes key, ref Context context) nothrow @nogc
    {
        Result!ulong queued;
        {
            flights.lock();
            scope (exit)
                flights.unlock();
            const allowed = context.check();
            if (allowed.code != Status.ok)
                return allowed;
            if (local is null)
                queued = remote.evictCommand(key);
            else
                queued.error = local.evict(hash, key, context);
            if (queued.ok)
                flights.invalidate(hash, key);
        }
        return local is null && queued.ok ? remote.complete(queued.value, context) : queued.error;
    }

    Error clear(ref Context context) nothrow @nogc
    {
        if (!isOpen)
            return inactive();
        if (local is null)
        {
            const ready = remote.ready(context);
            if (ready.code != Status.ok)
                return ready;
        }
        Result!ulong queued;
        {
            flights.lock();
            scope (exit)
                flights.unlock();
            const allowed = context.check();
            if (allowed.code != Status.ok)
                return allowed;
            if (local is null)
                queued = remote.clearCommand();
            else
                queued.error = local.clear(context);
            if (queued.ok)
                flights.invalidateAll();
        }
        return local is null && queued.ok ? remote.complete(queued.value, context) : queued.error;
    }

    Error close() nothrow @nogc
    {
        if (cas(&closed, false, true))
        {
            flights.close();
            if (local !is null)
                local.close();
        }
        return remote.close();
    }

    ulong settle(Admission ticket, ulong hash, scope Bytes key, scope Bytes value, long ttl, Error status) nothrow @nogc
    {
        // Order publication with explicit invalidation. The loader and transport wait run outside the lock.
        flights.lock();
        scope (exit)
            flights.unlock();
        ulong remoteTicket;
        if (status.code == Status.ok && ttl > 0 && flights.canPublish(ticket))
        {
            if (local is null)
            {
                const queued = remote.putCommand(key, value, ttl);
                if (queued.ok)
                    remoteTicket = queued.value;
            }
            else
            {
                Context independent;
                store(hash, key, value, ttl, independent);
            }
        }
        flights.settle(ticket, key, value, status);
        return remoteTicket;
    }
}

/// Lookup a key or coalesce a single explicit loader with independently cancellable waiters.
Result!Buffer getOrLoad(ref Cache cache, scope Bytes key, long ttlNanos, ref scope RequestArena arena,
        ref Context context, scope CacheLoader load) nothrow @nogc
{
    if (ttlNanos < 0 || load is null)
        return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid cache loader or TTL"));
    auto state = cache.control;
    if (state is null)
        return Result!Buffer(Buffer.init, inactive());
    const hash = hashBytes(key);
    const found = state.read(hash, key, arena, context);
    if (found.error.code != Status.notFound)
        return found;
    const admitted = state.flights.enter(hash, key, context);
    if (!admitted.ok)
        return Result!Buffer(Buffer.init, admitted.error);
    const admission = admitted.value;
    scope (exit)
        state.flights.leave(admission);
    if (!admission.leader)
        return waitForLoad(state.flights, admission, arena);
    return loadFirst(state, admission, hash, key, ttlNanos, arena, context, load);
}

private Result!Buffer waitForLoad(Flights flights, Admission admission, ref scope RequestArena arena) nothrow @nogc
{
    Result!Buffer result;
    while (!flights.get(admission, arena, result))
    {
        auto reactor = Reactor.current();
        const ready = reactor.yieldUntil(Deadline.afterMillis(1));
        if (ready.code == Status.notFound)
            Thread.sleep(1.msecs);
        else if (ready.code != Status.ok)
            return Result!Buffer(Buffer.init, ready);
    }
    return result;
}

private Result!Buffer loadFirst(State state, Admission admission, ulong hash, scope Bytes key, long ttl,
        ref scope RequestArena arena, ref Context waiter, scope CacheLoader load) nothrow @nogc
{
    auto context = state.flights.loadContext(admission);
    auto result = state.read(hash, key, arena, context);
    const missed = result.error.code == Status.notFound;
    if (missed)
        result = load(arena, context);
    ulong publish;
    if (!result.ok)
        state.settle(admission, hash, key, null, 0, result.error);
    else
    {
        const read = arena.read(result.value, (scope Bytes bytes) @safe nothrow @nogc {
            publish = state.settle(admission, hash, key, bytes, missed ? ttl : 0, Error.init);
        });
        if (read != Status.ok)
        {
            result.error = Error(read, "cache loader returned an invalid buffer");
            state.settle(admission, hash, key, null, 0, result.error);
        }
    }
    if (publish != 0)
    {
        auto budget = Context.init.withDeadline(Deadline.afterMillis(5000));
        state.remote.complete(publish, budget);
    }
    const ownStatus = waiter.check();
    if (ownStatus.code != Status.ok)
        return Result!Buffer(Buffer.init, ownStatus);
    return result;
}
