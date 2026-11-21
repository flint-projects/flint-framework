module flint.reactor.sys.fibers;

import core.thread : Fiber;
import flint.reactor.types : TaskFn;

@safe:

// SAFETY: The new fiber owns its stack. Its entry is an immutable function with safe, nonthrowing behavior.
@trusted package(flint.reactor) Fiber createFiber(TaskFn entry, size_t stackBytes)
{
    return new Fiber(entry, stackBytes);
}

// SAFETY: Only its owning loop resumes a paused fiber. The Rethrow.no specialization returns any failure
// to the loop. No conversion changes the attributes of the callback or druntime.
@trusted package(flint.reactor) Throwable resumeFiber(Fiber fiber) nothrow @nogc
{
    return fiber.call!(Fiber.Rethrow.no)();
}

// SAFETY: Only a running owned fiber suspends and its owning loop is the only possible resumer.
package(flint.reactor) void yieldFiber() @trusted nothrow @nogc
{
    Fiber.yield();
}

// SAFETY: Only the owner resets a terminated fiber. No application stack remains attached.
package(flint.reactor) void resetFiber(Fiber fiber) @trusted nothrow @nogc
{
    assert(fiber.state == Fiber.State.TERM);
    fiber.reset();
}

// SAFETY: On shutdown, each fiber has never entered or has already terminated and reset on its owner loop.
@trusted package(flint.reactor) void releaseFiber(ref Fiber fiber)
{
    if (fiber !is null)
        destroy(fiber);
    fiber = null;
}
