module flint.schedule.resilience_test;

import flint.arena : Error, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.schedule : CircuitBreaker, CircuitState, RateLimiter, RetryClock, RetryPolicy, ScheduledTask, withRetry;

@safe:

private long synthetic;
private uint waits;

private long now() nothrow @nogc
{
    return synthetic;
}

private Error wait(ref Context context, long end) nothrow @nogc
{
    assert(end >= synthetic && end <= context.deadline().monotonicNanoseconds);
    synthetic = end;
    ++waits;
    return Error.init;
}

@("retry caps jitter at a deadline, checks cancellation and keeps nonreplayable operations single-shot")
unittest
{
    synthetic = Deadline.afterMillis(0).monotonicNanoseconds;
    const deadline = synthetic + 350_000_000;
    auto owned = CancelSource.create(Context.init, Deadline(deadline));
    assert(owned.ok);
    auto context = owned.value.context();
    int attempts;
    ScheduledTask operation = (ref Context) @safe nothrow @nogc {
        ++attempts;
        return Error(Status.unavailable);
    };
    const timer = RetryClock(&now, &wait, 345_678);
    assert(withRetry(context, RetryPolicy(100, 100_000_000, 200_000_000, false), operation, timer)
            .code == Status.unavailable && attempts == 1);
    attempts = 0;
    waits = 0;
    assert(withRetry(context, RetryPolicy(100, 100_000_000, 200_000_000, true), operation, timer)
            .code == Status.timedOut);
    assert(attempts >= 2 && attempts <= 12 && synthetic == deadline && waits == attempts);
    owned.value.cancel();
    attempts = 0;
    assert(withRetry(context, RetryPolicy.init, operation, timer).code == Status.cancelled && attempts == 0);
}

@("the circuit uses completed windows and admits a single half-open probe")
unittest
{
    CircuitBreaker circuit;
    assert(circuit.open(100, 50, 1000).code == Status.ok);
    foreach (index; 0 .. 20)
    {
        assert(circuit.permit(index).ok);
        circuit.record(index % 2 != 0, index);
        assert(circuit.state == (index == 19 ? CircuitState.open : CircuitState.closed));
    }
    assert(circuit.permit(1018).error.code == Status.unavailable);
    assert(circuit.permit(1019).ok && circuit.state == CircuitState.halfOpen);
    assert(circuit.permit(1020).error.code == Status.unavailable);
    circuit.record(false, 1020);
    assert(circuit.state == CircuitState.open);
    assert(circuit.permit(2020).ok);
    circuit.record(true, 2020);
    assert(circuit.state == CircuitState.closed);
}

@("token bucket keeps fractional intervals and saturates checked arithmetic")
unittest
{
    RateLimiter limiter;
    assert(limiter.open(2, 3).code == Status.ok);
    assert(limiter.acquire(2, 0).value);
    assert(!limiter.acquire(1, 333_333_333).value);
    assert(limiter.acquire(1, 333_333_334).value);
    assert(!limiter.acquire(1, 666_666_666).value);
    assert(limiter.acquire(1, 666_666_667).value);
    assert(limiter.acquire(2, long.max).value);
    assert(!limiter.acquire(1, 10).value);
    RateLimiter wide;
    assert(wide.open(uint.max, uint.max).code == Status.ok);
    assert(wide.acquire(uint.max, 0).value);
    assert(wide.acquire(uint.max, long.max).value);
}
