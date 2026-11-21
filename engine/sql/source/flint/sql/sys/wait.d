/// Cooperative deadline and native descriptor waits.
module flint.sql.sys.wait;

import flint.arena : Error, Status;
import flint.conc : Context, Deadline;
import flint.reactor : NativeInterest, Reactor;
import flint.sql.ffi.shim : Interest, waitOffReactor;

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

package(flint.sql) Error admit() nothrow @nogc
{
    auto owner = Reactor.current();
    if (owner.currentCore() != uint.max && !owner.currentTask().ok())
        return Error(Status.conflict, "SQL calls on a reactor require a task fiber");
    return Error.init;
}

package(flint.sql) Error pause() nothrow @nogc
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

package(flint.sql) Error waitFor(Interest interest, ref const Context context, Deadline cleanup) nothrow @nogc
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
