module flint.reactor.sys.fibers;

import core.thread : Fiber;
import flint.reactor.types : TaskFn;

@safe:

version (linux)
{
    private extern (C) int madvise(void* address, size_t length, int advice) @system nothrow @nogc;
    private enum int adviseDontNeed = 4; // MADV_DONTNEED
}

/// A preallocated pool fiber whose initial stack frame is written when its slot is first used.
///
/// druntime writes a new fiber's initial frame into the top page of its stack during construction.
/// Preallocating a large pool therefore made one page per fiber resident before any work ran.
/// `park` returns those pages to the kernel; `prime` rewrites the frame before the first resume.
/// The stack mapping, its guard page, its GC registration and the pool capacity are unchanged.
final class PoolFiber : Fiber
{
    private bool parked;

    /// Allocate a guarded stack of `stackBytes` for `entry`.
    // SAFETY: The base constructor allocates and registers the stack this object owns; the entry is safe and nothrow.
    @trusted this(TaskFn entry, size_t stackBytes) nothrow
    {
        super(entry, stackBytes);
    }

    // park discards this fiber's own anonymous mapping above the guard page, [m_pmem + page, m_pmem + m_size).
    /// Return the stack pages dirtied by construction to the kernel until the first resume.
    // SAFETY: HOLD state, never resumed, own mapping only; `prime` rewrites the frame before the first resume.
    @trusted void park() nothrow @nogc
    {
        version (linux)
        {
            import core.memory : pageSize;

            if (parked || state != Fiber.State.HOLD || m_pmem is null || m_size <= pageSize)
                return;
            if (madvise(m_pmem + pageSize, m_size - pageSize, adviseDontNeed) == 0)
                parked = true;
        }
    }

    /// Rewrite the initial frame of a parked fiber before its first resume.
    // SAFETY: Only the owning loop primes a parked HOLD fiber right before its first resume; reset() rewrites its frame.
    @trusted void prime() nothrow @nogc
    {
        if (!parked)
            return;
        reset();
        parked = false;
    }

    /// True while the initial frame has been released and not yet rewritten.
    bool isParked() const pure nothrow @nogc
    {
        return parked;
    }
}

// SAFETY: The new fiber owns its stack. Its entry is an immutable function with safe, nonthrowing behavior.
@trusted package(flint.reactor) PoolFiber createFiber(TaskFn entry, size_t stackBytes)
{
    auto fiber = new PoolFiber(entry, stackBytes);
    fiber.park();
    return fiber;
}

// SAFETY: Only its owning loop resumes a paused fiber. The Rethrow.no specialization returns any failure
// to the loop. No conversion changes the attributes of the callback or druntime.
@trusted package(flint.reactor) Throwable resumeFiber(PoolFiber fiber) nothrow @nogc
{
    fiber.prime();
    return fiber.call!(Fiber.Rethrow.no)();
}

// SAFETY: Only a running owned fiber suspends and its owning loop is the only possible resumer.
package(flint.reactor) void yieldFiber() @trusted nothrow @nogc
{
    Fiber.yield();
}

// SAFETY: Only the owner resets a terminated fiber. No application stack remains attached.
package(flint.reactor) void resetFiber(PoolFiber fiber) @trusted nothrow @nogc
{
    assert(fiber.state == Fiber.State.TERM);
    fiber.reset();
}

// SAFETY: On shutdown, each fiber has never entered or has already terminated and reset on its owner loop.
@trusted package(flint.reactor) void releaseFiber(ref PoolFiber fiber)
{
    if (fiber !is null)
        destroy(fiber);
    fiber = null;
}
