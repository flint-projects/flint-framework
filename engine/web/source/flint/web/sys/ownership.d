/// Bounded native byte storage and startup-only event loop driver.
module flint.web.sys.ownership;

import core.stdc.stdlib : free, malloc;
import core.thread : Thread;
import flint.arena : Error, Status;

@safe:

// SAFETY: This allocates an exclusive, bounded payload-only region; runtime closes its views before release.
package(flint.web) ubyte[] reserveBytes(size_t capacity) @trusted nothrow @nogc
{
    if (capacity == 0)
        return null;
    auto pointer = cast(ubyte*) malloc(capacity);
    return pointer is null ? null : pointer[0 .. capacity];
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
