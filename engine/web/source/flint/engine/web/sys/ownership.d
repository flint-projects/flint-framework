/// Bounded native byte storage and startup-only event loop driver.
module flint.engine.web.sys.ownership;

import core.memory : GC;
import core.stdc.stdlib : free, malloc;
import core.thread.osthread : Thread;
import flint.arena : Error, Status;
import flint.engine.web.types : HeaderRecord, maximumFields;

@safe:

// Lazily zero-filled anonymous mappings on Linux and macOS (ADR-024).
version (Posix)
{
    import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;
}

/// The first chunk of a worker's slots that becomes a GC root holds this many; each later chunk doubles the total.
package(flint.engine.web) enum firstRootedSlots = 64;

/++
The slot count a worker registers as GC roots once it uses `slot`, when `rooted` slots are registered: 64, then 128,
256 and so on, at most `perWorker`. The collector reads every registered word on every collection, so the 4,096
slots a worker reserves (2.4 MB at 600 bytes each) are registered only as the reactor reaches them. It hands out
the lowest free slot first, so a worker serving 64 connections registers one chunk.
+/
package(flint.engine.web) size_t nextRootedSlots(size_t rooted, size_t perWorker) pure nothrow @nogc
{
    const next = rooted == 0 ? firstRootedSlots : rooted * 2;
    return next < perWorker ? next : perWorker;
}

// SAFETY: The unique native mapping is aligned and zero-filled for the full slot count. It is not a GC
// root yet: `rootConnectionSlots` registers each chunk before its owner first writes a slot in it.
package(flint.engine.web) T[] reserveConnectionSlots(T)(size_t count) @trusted nothrow
{
    if (count == 0 || count > size_t.max / T.sizeof)
        return null;
    version (Posix)
    {
        const bytes = count * T.sizeof;
        auto address = mmap(null, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (address == MAP_FAILED)
            return null;
        if (address is null)
        {
            munmap(address, bytes);
            return null;
        }
        return (cast(T*) address)[0 .. count];
    }
    else
        return new T[count];
}

// SAFETY: Bounds are checked against the reserved slots, which stay mapped until `releaseConnectionSlots`
// removes this chunk by its base. Callers register a chunk before the first write of a reference into it.
package(flint.engine.web) bool rootConnectionSlots(T)(T[] slots, size_t from, size_t to) @trusted nothrow @nogc
{
    if (from >= to || to > slots.length)
        return false;
    version (Posix)
        GC.addRange(&slots[from], (to - from) * T.sizeof);
    return true;
}

// SAFETY: The final driver drain or a startup failure owns this mapping; no borrower can retain it. Every
// chunk base `rootConnectionSlots` added (rooted[w] per worker) is removed before the address is unmapped.
package(flint.engine.web) @trusted nothrow @nogc void releaseConnectionSlots(T)(ref T[] slots,
        size_t perWorker, const(size_t)[] rooted)
{
    if (slots is null)
        return;
    version (Posix)
    {
        foreach (worker, count; rooted)
        {
            const base = worker * perWorker;
            for (size_t from = 0; from < count && base + from < slots.length; from = nextRootedSlots(from, perWorker))
                GC.removeRange(&slots[base + from]);
        }
        const released = munmap(slots.ptr, slots.length * T.sizeof);
        assert(released == 0);
    }
    slots = null;
}

// SAFETY: This allocates an exclusive, bounded payload-only region; runtime closes its views before release.
package(flint.engine.web) ubyte[] reserveBytes(size_t capacity) @trusted nothrow @nogc
{
    if (capacity == 0)
        return null;
    auto pointer = cast(ubyte*) malloc(capacity);
    return pointer is null ? null : pointer[0 .. capacity];
}

// SAFETY: malloc aligns the pointer-free HeaderRecord prefix. The returned slice owns the entire
// region, which keeps both views live until the final HTTP callback. Only initialized records are read.
package(flint.engine.web) @trusted nothrow @nogc ubyte[] reserveH1(size_t bytes, out HeaderRecord[] table,
        out ubyte[] data)
{
    enum prefix = maximumFields * HeaderRecord.sizeof;
    static assert(prefix % 8 == 0 && HeaderRecord.alignof <= 8);
    if (bytes == 0 || bytes > size_t.max - prefix)
        return null;
    auto owned = reserveBytes(prefix + bytes);
    if (owned is null)
        return null;
    table = (cast(HeaderRecord*) owned.ptr)[0 .. maximumFields];
    data = owned[prefix .. $];
    return owned;
}

// SAFETY: Only the owner releases this exact allocation after final completion; aliases are already retired.
package(flint.engine.web) void releaseBytes(ref ubyte[] storage) @trusted nothrow @nogc
{
    if (storage !is null)
    {
        free(storage.ptr);
        storage = null;
    }
}

// SAFETY: druntime roots the owned delegate until the dedicated driver returns; no request references cross.
@trusted package(flint.engine.web) Thread launchDriver(void delegate() @safe nothrow entry)
{
    return new Thread(entry).start();
}

// SAFETY: The driver joins its own previously launched worker after stopping admissions.
@trusted package(flint.engine.web) Error joinDriver(Thread thread) nothrow
{
    if (thread is null)
        return Error.init;
    try
        return thread.join(false) is null ? Error.init : Error(Status.ioError, "owned HTTP worker terminated");
    catch (Exception)
        return Error(Status.ioError, "unable to join owned HTTP worker");
}

version (Posix)
{
    version (unittest)
    {
        import core.gc.gcinterface : GCInterface = GC, Range;

        private extern (C) GCInterface gc_getProxy() nothrow @nogc;

        /// The GC roots registered inside `region`: how many ranges, and their bytes.
        // SAFETY: Test-only. Walks druntime's own range list under its lock, comparing addresses as integers; no
        // pointer leaves this function.
        private @trusted size_t[2] rootsWithin(const(void)[] region)
        {
            const low = cast(size_t) region.ptr, high = low + region.length;
            size_t[2] found;
            auto ranges = gc_getProxy().rangeIter;
            ranges((ref Range range) nothrow{
                const bottom = cast(size_t) range.pbot, top = cast(size_t) range.ptop;
                if (bottom >= low && top <= high)
                {
                    ++found[0];
                    found[1] += top - bottom;
                }
                return 0;
            });
            return found;
        }
    }

    @("unused slots stay zero and native range retains D objects across collection")
    unittest
    {
        import core.lifetime : emplace;

        struct TestSlot
        {
            int marker = 37;
            int* payload;
        }

        pragma(inline, false) void publish(ref TestSlot slot)
        {
            slot.payload = new int(81);
        }

        assert(reserveConnectionSlots!TestSlot(0) is null);
        assert(reserveConnectionSlots!TestSlot(size_t.max) is null);
        enum perWorker = 4_096;
        auto slots = reserveConnectionSlots!TestSlot(2 * perWorker);
        size_t[2] rooted;
        scope (exit)
            releaseConnectionSlots(slots, perWorker, rooted[]);
        assert(slots.length == 8_192 && slots[0].marker == 0 && slots[$ - 1].marker == 0);
        const(void)[] region = slots;
        assert(rootsWithin(region) == [0, 0], "a reservation registers nothing");

        // Worker 0 uses its first slot: one chunk of 64 becomes a root.
        assert(rootConnectionSlots(slots, 0, nextRootedSlots(0, perWorker)));
        rooted[0] = firstRootedSlots;
        emplace(&slots[0]);
        assert(slots[0].marker == 37);
        publish(slots[0]);

        // Worker 1 reaches slot 100, past its first chunk: chunks [0, 64) and [64, 128) of its half are roots.
        const base = perWorker;
        while (rooted[1] <= 100)
        {
            const next = nextRootedSlots(rooted[1], perWorker);
            assert(rootConnectionSlots(slots, base + rooted[1], base + next));
            rooted[1] = next;
        }
        assert(rooted[1] == 128);
        assert(rootsWithin(region) == [3, (64 + 128) * TestSlot.sizeof], "exactly the three chunks used");
        emplace(&slots[base + 100]);
        publish(slots[base + 100]);

        GC.collect();
        assert(*slots[0].payload == 81 && *slots[base + 100].payload == 81);
        releaseConnectionSlots(slots, perWorker, rooted[]);
        assert(slots is null);
        assert(rootsWithin(region) == [0, 0], "release removes every chunk it added");
        GC.collect();
    }

    @("connection slots become GC roots in doubling chunks, never past a worker's slots")
    unittest
    {
        assert(nextRootedSlots(0, 4_096) == 64);
        assert(nextRootedSlots(64, 4_096) == 128);
        assert(nextRootedSlots(2_048, 4_096) == 4_096);
        assert(nextRootedSlots(0, 16) == 16, "a worker smaller than one chunk registers all its slots");
        assert(nextRootedSlots(3_000, 4_000) == 4_000);

        auto slots = reserveConnectionSlots!(void*)(8);
        scope (exit)
            releaseConnectionSlots(slots, 8, [size_t(8)]);
        assert(!rootConnectionSlots(slots, 4, 4), "an empty chunk is refused");
        assert(!rootConnectionSlots(slots, 0, 9), "a chunk past the reservation is refused");
        assert(rootConnectionSlots(slots, 0, 8));
    }
}
