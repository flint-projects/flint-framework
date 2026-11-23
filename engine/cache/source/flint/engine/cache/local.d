module flint.engine.cache.local;

import core.atomic : atomicLoad, atomicOp, cas;
import core.sync.mutex : Mutex;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.engine.cache.sys.bytes : OwnedBytes;
import flint.conc : Context, Deadline;

import flint.engine.cache.types : Bytes, CacheStats;

@safe:

package(flint.engine.cache) ulong hashBytes(scope const(ubyte)[] key) pure nothrow @nogc
{
    ulong hash = 14_695_981_039_346_656_037UL;
    foreach (value; key)
        hash = (hash ^ value) * 1_099_511_628_211UL;
    return hash ^ (hash >> 32);
}

private struct ByteBudget
{
    size_t limit;
    private shared size_t used;

    bool acquire(size_t extra) nothrow @nogc
    {
        for (;;)
        {
            const previous = atomicLoad(used);
            if (extra > limit - previous)
                return false;
            if (extra == 0 || cas(&used, previous, previous + extra))
                return true;
        }
    }

    void release(size_t bytes) nothrow @nogc
    {
        if (bytes != 0)
            atomicOp!"-="(used, bytes);
    }
}

private struct Item
{
    OwnedBytes data;
    long expires;
    ulong epoch;
    ulong hash;
    uint chain;
    uint older;
    uint newer;
}

private struct Stripe
{
    Mutex gate;
    Item[] items;
    uint[] buckets;
    uint firstFree;
    uint leastRecent;
    uint mostRecent;
    uint sweepAt = 1;
    bool track;
    CacheStats observed;

    void initialize(uint capacity, bool measure)
    {
        track = measure;
        gate = new Mutex;
        items = new Item[capacity + 1];
        buckets = new uint[capacity * 2];
        firstFree = 1;
        foreach (i; 1 .. capacity)
            items[i].chain = i + 1;
    }

    void lock() nothrow @nogc
    {
        if (!track)
        {
            gate.lock_nothrow();
            return;
        }
        const before = Deadline.afterMillis(0).monotonicNanoseconds;
        gate.lock_nothrow();
        const after = Deadline.afterMillis(0).monotonicNanoseconds;
        ++observed.lockAcquisitions;
        if (after > before)
            observed.lockWaitNanos += cast(ulong)(after - before);
    }

    uint find(ulong hash, scope const(ubyte)[] key) const nothrow @nogc
    {
        for (uint index = buckets[hash % buckets.length]; index != 0; index = items[index].chain)
        {
            if (items[index].hash == hash && items[index].data.matches(key))
                return index;
        }
        return 0;
    }

    bool reserve(ref ByteBudget budget, size_t extra, uint preserve) nothrow @nogc
    {
        while (!budget.acquire(extra))
        {
            const victim = leastRecent == preserve ? items[leastRecent].newer : leastRecent;
            if (victim == 0)
                return false;
            remove(victim, budget);
        }
        return true;
    }

    uint insert(ulong hash) nothrow @nogc
    {
        const index = firstFree;
        firstFree = items[index].chain;
        const bucket = hash % buckets.length;
        items[index].hash = hash;
        items[index].chain = buckets[bucket];
        buckets[bucket] = index;
        linkRecent(index);
        return index;
    }

    void touch(uint index) nothrow @nogc
    {
        if (index == mostRecent)
            return;
        unlink(index);
        linkRecent(index);
    }

    void remove(uint index, ref ByteBudget budget) nothrow @nogc
    {
        auto item = &items[index];
        const bucket = item.hash % buckets.length;
        auto next = &buckets[bucket];
        while (*next != index)
            next = &items[*next].chain;
        *next = item.chain;
        unlink(index);
        const occupied = item.data.bytes;
        item.data.release();
        budget.release(occupied);
        item.epoch = 0;
        item.chain = firstFree;
        firstFree = index;
    }

    void sweep(long now, ulong epoch, uint count, ref ByteBudget budget) nothrow @nogc
    {
        foreach (_; 0 .. count)
        {
            const item = &items[sweepAt];
            if (item.epoch != 0 && (item.epoch != epoch || item.expires <= now))
                remove(sweepAt, budget);
            if (++sweepAt == items.length)
                sweepAt = 1;
        }
    }

    void purge(ulong current, ref ByteBudget budget) nothrow @nogc
    {
        auto index = leastRecent;
        while (index != 0)
        {
            const following = items[index].newer;
            if (current == 0 || items[index].epoch < current)
                remove(index, budget);
            index = following;
        }
    }

    private void unlink(uint index) nothrow @nogc
    {
        auto entry = &items[index];
        if (entry.older != 0)
            items[entry.older].newer = entry.newer;
        else
            leastRecent = entry.newer;
        if (entry.newer != 0)
            items[entry.newer].older = entry.older;
        else
            mostRecent = entry.older;
    }

    private void linkRecent(uint index) nothrow @nogc
    {
        auto entry = &items[index];
        entry.older = mostRecent;
        entry.newer = 0;
        if (mostRecent != 0)
            items[mostRecent].newer = index;
        else
            leastRecent = index;
        mostRecent = index;
    }
}

package(flint.engine.cache) final class LocalStore
{
    private Stripe[] stripes;
    private ByteBudget budget;
    private shared bool closed;
    private shared ulong epoch = 1;
    private shared ulong sweepIndex;

    this(size_t bytes, uint entries, uint count, bool measure)
    {
        budget.limit = bytes;
        stripes = new Stripe[count];
        foreach (i, ref stripe; stripes)
        {
            const portion = entries / count + (i < entries % count);
            stripe.initialize(portion, measure);
        }
    }

    Result!Buffer get(ulong hash, scope Bytes key, long at, ref scope RequestArena arena, ref Context ctx) nothrow @nogc
    {
        auto stripe = &stripes[hash % stripes.length];
        stripe.lock();
        scope (exit)
            stripe.gate.unlock_nothrow();
        const status = available(ctx);
        if (status.code != Status.ok)
            return Result!Buffer(Buffer.init, status);
        const index = stripe.find(hash, key);
        if (index == 0)
            return Result!Buffer(Buffer.init, Error(Status.notFound, "cache miss"));
        auto item = &stripe.items[index];
        if (item.epoch != atomicLoad(epoch) || item.expires <= at)
        {
            stripe.remove(index, budget);
            return Result!Buffer(Buffer.init, Error(Status.notFound, "cached value expired"));
        }
        stripe.touch(index);
        return item.data.copyValue(arena);
    }

    Error put(ulong hash, scope Bytes key, scope Bytes value, long expires, ref Context ctx) nothrow @nogc
    {
        if (key.length > budget.limit || value.length > budget.limit - key.length)
            return Error(Status.resourceExhausted, "cache record exceeds its byte capacity");
        auto stripe = &stripes[hash % stripes.length];
        stripe.lock();
        scope (exit)
            stripe.gate.unlock_nothrow();
        const status = available(ctx);
        if (status.code != Status.ok)
            return status;
        const current = atomicLoad(epoch);
        const index = stripe.find(hash, key);
        if (index != 0)
            return replace(*stripe, index, key, value, expires, current);
        if (stripe.firstFree == 0)
            stripe.remove(stripe.leastRecent, budget);
        const wanted = key.length + value.length;
        if (!stripe.reserve(budget, wanted, 0))
            return Error(Status.resourceExhausted, "cache byte capacity reached");
        auto item = &stripe.items[stripe.firstFree];
        const saved = item.data.replace(key, value);
        if (saved != Status.ok)
        {
            budget.release(wanted);
            return Error(saved, "could not allocate cached value");
        }
        item.expires = expires;
        item.epoch = current;
        stripe.insert(hash);
        return Error.init;
    }

    private Error replace(ref Stripe shard, uint id, scope Bytes key, scope Bytes val, long at, ulong gen) nothrow @nogc
    {
        const wanted = key.length + val.length;
        auto item = &shard.items[id];
        const prior = item.data.bytes;
        const extra = wanted > prior ? wanted - prior : 0;
        if (!shard.reserve(budget, extra, id))
            return Error(Status.resourceExhausted, "cache byte capacity reached");
        const replaced = item.data.replace(key, val);
        if (replaced != Status.ok)
        {
            budget.release(extra);
            return Error(replaced, "could not replace cached value");
        }
        if (wanted < prior)
            budget.release(prior - wanted);
        item.expires = at;
        item.epoch = gen;
        shard.touch(id);
        return Error.init;
    }

    Error evict(ulong hash, scope Bytes key, ref Context context) nothrow @nogc
    {
        auto stripe = &stripes[hash % stripes.length];
        stripe.lock();
        scope (exit)
            stripe.gate.unlock_nothrow();
        const status = available(context);
        if (status.code != Status.ok)
            return status;
        const index = stripe.find(hash, key);
        if (index != 0)
            stripe.remove(index, budget);
        return Error.init;
    }

    Error clear(ref Context context) nothrow @nogc
    {
        const status = available(context);
        if (status.code != Status.ok)
            return status;
        for (;;)
        {
            const previous = atomicLoad(epoch);
            if (previous == ulong.max)
                return Error(Status.resourceExhausted, "cache generations exhausted");
            if (!cas(&epoch, previous, previous + 1))
                continue;
            purge(previous + 1);
            return Error.init;
        }
    }

    void sweep(long now) nothrow @nogc
    {
        const next = atomicOp!"+="(sweepIndex, 1UL);
        auto stripe = &stripes[(next - 1) % stripes.length];
        stripe.lock();
        scope (exit)
            stripe.gate.unlock_nothrow();
        if (!atomicLoad(closed))
            stripe.sweep(now, atomicLoad(epoch), 64, budget);
    }

    void close() nothrow @nogc
    {
        if (cas(&closed, false, true))
            purge(0);
    }

    CacheStats stats() nothrow @nogc
    {
        CacheStats result;
        foreach (ref stripe; stripes)
        {
            stripe.gate.lock_nothrow();
            result.lockAcquisitions += stripe.observed.lockAcquisitions;
            result.lockWaitNanos += stripe.observed.lockWaitNanos;
            stripe.gate.unlock_nothrow();
        }
        return result;
    }

    private Error available(ref Context context) const nothrow @nogc
    {
        return atomicLoad(closed) ? Error(Status.unavailable, "cache is closed") : context.check();
    }

    private void purge(ulong current) nothrow @nogc
    {
        foreach (ref stripe; stripes)
        {
            stripe.lock();
            stripe.purge(current, budget);
            stripe.gate.unlock_nothrow();
        }
    }
}
