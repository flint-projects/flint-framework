/// Bounded native byte storage and startup-only event loop driver.
module flint.web.sys.ownership;

import core.memory : GC;
import core.stdc.stdlib : free, malloc;
import core.thread.osthread : Thread;
import flint.arena : Error, Status;
import flint.web.types : HeaderRecord, maximumFields;

@safe:

version (linux)
{
    import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;
}

// SAFETY: The unique native mapping is aligned and zero-filled for the full slot count. The GC range
// sees references before any owner publishes a slot. The caller initializes a slot before its first use.
package(flint.web) T[] reserveConnectionSlots(T)(size_t count) @trusted nothrow
{
    if (count == 0 || count > size_t.max / T.sizeof)
        return null;
    version (linux)
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
        GC.addRange(address, bytes);
        return (cast(T*) address)[0 .. count];
    }
    else
        return new T[count];
}

// SAFETY: Startup failure or the final completed driver drain owns this exact mapping. No callback or
// scoped borrower can retain it. Deregistration completes before the address stops being readable.
package(flint.web) void releaseConnectionSlots(T)(ref T[] slots) @trusted nothrow @nogc
{
    if (slots is null)
        return;
    version (linux)
    {
        GC.removeRange(slots.ptr);
        const released = munmap(slots.ptr, slots.length * T.sizeof);
        assert(released == 0);
    }
    slots = null;
}

// SAFETY: This allocates an exclusive, bounded payload-only region; runtime closes its views before release.
package(flint.web) ubyte[] reserveBytes(size_t capacity) @trusted nothrow @nogc
{
    if (capacity == 0)
        return null;
    auto pointer = cast(ubyte*) malloc(capacity);
    return pointer is null ? null : pointer[0 .. capacity];
}

// SAFETY: malloc aligns the pointer-free HeaderRecord prefix. The returned slice owns the entire
// region, which keeps both views live until the final HTTP callback. Only initialized records are read.
package(flint.web) ubyte[] reserveH1(size_t bytes, out HeaderRecord[] table, out ubyte[] data) @trusted nothrow @nogc
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
package(flint.web) void releaseBytes(ref ubyte[] storage) @trusted nothrow @nogc
{
    if (storage !is null)
    {
        free(storage.ptr);
        storage = null;
    }
}

// SAFETY: druntime roots the owned delegate until the dedicated driver returns; no request references cross.
@trusted package(flint.web) Thread launchDriver(void delegate() @safe nothrow entry)
{
    return new Thread(entry).start();
}

// SAFETY: The driver joins its own previously launched worker after stopping admissions.
@trusted package(flint.web) Error joinDriver(Thread thread) nothrow
{
    if (thread is null)
        return Error.init;
    try
        return thread.join(false) is null ? Error.init : Error(Status.ioError, "owned HTTP worker terminated");
    catch (Exception)
        return Error(Status.ioError, "unable to join owned HTTP worker");
}

version (linux)
{
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
        auto slots = reserveConnectionSlots!TestSlot(8_192);
        scope (exit)
            releaseConnectionSlots(slots);
        assert(slots.length == 8_192 && slots[0].marker == 0 && slots[$ - 1].marker == 0);
        emplace(&slots[0]);
        assert(slots[0].marker == 37);
        publish(slots[0]);
        GC.collect();
        assert(*slots[0].payload == 81);
        releaseConnectionSlots(slots);
        assert(slots is null);
        GC.collect();
    }
}
