/// Cooperative deadline and native descriptor waits.
module flint.engine.sql.sys.wait;

import core.atomic : atomicLoad, atomicOp;
import flint.arena : Error, Status;
import flint.conc : Context, Deadline;
import flint.engine.reactor : NativeInterest, Reactor;
import flint.engine.sql.ffi.shim : Interest, waitOffReactor;

@safe:

private struct Signal
{
    int descriptor = -1;
    bool ready;

    void receive(int fd, NativeInterest events) nothrow @nogc
    {
        if (descriptor == fd && events != NativeInterest.none)
            ready = true;
    }
}

private Signal[256] signals;

private size_t reserveSignal(int fd) nothrow @nogc
{
    foreach (index, ref signal; signals)
    {
        if (signal.descriptor != -1)
            continue;
        signal = Signal(fd);
        return index;
    }
    return size_t.max;
}

package(flint.engine.sql) Error admit() nothrow @nogc
{
    auto owner = Reactor.current();
    if (owner.currentCore() != uint.max && !owner.currentTask().ok())
        return Error(Status.conflict, "SQL calls on a reactor require a task fiber");
    return Error.init;
}

package(flint.engine.sql) Error admitStartup() nothrow @nogc
{
    auto owner = Reactor.current();
    return owner.currentCore() == uint.max ? Error.init : Error(Status.conflict,
            "whole SQL programs require startup outside the reactor");
}

// Per-pool generation of lease-queue changes. Off-reactor waiters sleep on it instead of polling,
// because the FIFO head would otherwise hold every released lease until its next poll.
private shared uint[64] leaseEpochs;
private shared uint[64] leaseSleepers;

/// Register a waiter before the acquisition attempt whose failure it may sleep on.
package(flint.engine.sql) void joinLeaseQueue(ulong pool) nothrow @nogc
{
    atomicOp!"+="(leaseSleepers[pool % leaseSleepers.length], 1U);
}

/// Remove a waiter registered by joinLeaseQueue.
package(flint.engine.sql) void leaveLeaseQueue(ulong pool) nothrow @nogc
{
    atomicOp!"-="(leaseSleepers[pool % leaseSleepers.length], 1U);
}

/// Observe the pool's lease generation before an acquisition attempt.
package(flint.engine.sql) uint leaseMark(ulong pool) nothrow @nogc
{
    return atomicLoad(leaseEpochs[pool % leaseEpochs.length]);
}

/// Announce a returned lease or a changed queue head to registered waiters. A waiter registers
/// before its failed attempt, so a change ordered after that attempt always observes it.
package(flint.engine.sql) void leaseChanged(ulong pool) nothrow @nogc
{
    const index = pool % leaseEpochs.length;
    if (atomicLoad(leaseSleepers[index]) == 0)
        return;
    atomicOp!"+="(leaseEpochs[index], 1U);
    wakeAll(leaseEpochs[index]);
}

/// Wait for a lease-queue change after mark, bounded so asynchronous replacement is still observed.
package(flint.engine.sql) Error pauseForLease(ulong pool, uint mark) nothrow @nogc
{
    auto owner = Reactor.current();
    if (owner.currentCore() != uint.max)
        return owner.yieldUntil(Deadline.afterMillis(1));
    park(leaseEpochs[pool % leaseEpochs.length], mark, 2_000_000);
    return Error.init;
}

version (linux)
{
    version (X86_64)
        private enum futexCall = 202;
    else version (AArch64)
        private enum futexCall = 98;
    else version (RISCV64)
        private enum futexCall = 98;
}
else version (OSX)
{
    // <os/os_sync_wait_on_address.h>, libSystem since macOS 14.4 (ADR-024). Flags 0 keeps the wait
    // process private, as FUTEX_PRIVATE_FLAG does.
    private enum osClockMachAbsoluteTime = 32; // OS_CLOCK_MACH_ABSOLUTE_TIME
    private extern (C) @system nothrow @nogc
    {
        int os_sync_wait_on_address_with_timeout(void* address, ulong value, size_t size, uint flags,
                uint clock, ulong timeoutNanos);
        int os_sync_wake_by_address_all(void* address, size_t size, uint flags);
    }
}

// SAFETY: The kernel compares the aligned 32-bit word with expected and sleeps at most nanos.
// It reads the word only during the call and retains neither address. Without a futex this sleeps.
private void park(ref shared uint word, uint expected, long nanos) @trusted nothrow @nogc
{
    version (OSX)
    {
        // EINTR, EFAULT and ETIMEDOUT all return to a caller that retries its acquisition.
        cast(void) os_sync_wait_on_address_with_timeout(cast(void*)&word, expected, uint.sizeof,
                0, osClockMachAbsoluteTime, nanos > 0 ? cast(ulong) nanos : 1);
    }
    else static if (is(typeof(futexCall)))
    {
        import core.sys.linux.unistd : syscall;
        import core.sys.posix.time : timespec;

        enum waitPrivate = 128; // FUTEX_WAIT | FUTEX_PRIVATE_FLAG
        timespec limit;
        limit.tv_sec = nanos / 1_000_000_000;
        limit.tv_nsec = nanos % 1_000_000_000;
        // EINTR, EAGAIN and ETIMEDOUT all return to a caller that retries its acquisition.
        syscall(futexCall, cast(void*)&word, waitPrivate, expected, &limit, null, 0);
    }
    else
        waitOffReactor(Interest.init, 2);
}

// SAFETY: The kernel uses the word address only as a key for waking its current waiters.
private void wakeAll(ref shared uint word) @trusted nothrow @nogc
{
    version (OSX)
        cast(void) os_sync_wake_by_address_all(cast(void*)&word, uint.sizeof, 0);
    else static if (is(typeof(futexCall)))
    {
        import core.sys.linux.unistd : syscall;

        enum wakePrivate = 129; // FUTEX_WAKE | FUTEX_PRIVATE_FLAG
        syscall(futexCall, cast(void*)&word, wakePrivate, int.max, null, null, 0);
    }
}

package(flint.engine.sql) Error pause() nothrow @nogc
{
    auto owner = Reactor.current();
    if (owner.currentCore() == uint.max)
        return Error(waitOffReactor(Interest.init, 2));
    return owner.yieldUntil(Deadline.afterMillis(1));
}

private bool continueWaiting(ref const Context context, Deadline cleanup) nothrow @nogc
{
    if (cleanup == Deadline.init)
        return context.check().code == Status.ok;
    return Deadline.afterMillis(0).monotonicNanoseconds < cleanup.monotonicNanoseconds;
}

package(flint.engine.sql) Error waitFor(Interest interest, ref const Context context, Deadline cleanup) nothrow @nogc
{
    auto owner = Reactor.current();
    if (owner.currentCore() == uint.max)
        return Error(waitOffReactor(interest, 2));
    if (interest.fd < 0)
        return owner.yieldUntil(Deadline.afterMillis(1));

    const index = reserveSignal(interest.fd);
    if (index == size_t.max)
        return owner.yieldUntil(Deadline.afterMillis(1));
    scope (exit)
        signals[index] = Signal.init;

    const ready = &signals[index].receive;
    const status = owner.watchNative(interest.fd, cast(NativeInterest) interest.events, ready);
    if (status.code == Status.resourceExhausted)
        return owner.yieldUntil(Deadline.afterMillis(1));
    if (status.code != Status.ok)
        return status;
    scope (exit)
        owner.unwatchNative(interest.fd);

    while (!signals[index].ready && continueWaiting(context, cleanup))
    {
        const yielded = owner.yieldUntil(Deadline.afterMillis(1));
        if (yielded.code != Status.ok)
            return yielded;
    }
    return Error.init;
}
