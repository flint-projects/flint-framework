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

private long[16] recordedWaits;

private Error recordingWait(ref Context context, long end) nothrow @nogc
{
    assert(end >= synthetic && waits < recordedWaits.length);
    recordedWaits[waits++] = end - synthetic;
    synthetic = end;
    return context.check();
}

private bool conflictIsReplayable(Error outcome) nothrow @nogc
{
    return outcome.code == Status.conflict;
}

@("retry_budget: maxAttempts includes the first call and only unavailable or timedOut retry by default")
unittest
{
    synthetic = 0;
    Context context;
    const timer = RetryClock(&now, &recordingWait, 7);
    int attempts;
    Status reply;
    ScheduledTask operation = (ref Context) @safe nothrow @nogc { ++attempts; return Error(reply); };
    foreach (retried; [Status.unavailable, Status.timedOut])
    {
        attempts = 0;
        waits = 0;
        reply = retried;
        assert(withRetry(context, RetryPolicy(3, 10, 40, true), operation, timer).code == retried);
        assert(attempts == 3 && waits == 2);
    }
    foreach (terminal; [
        Status.invalidArgument, Status.permissionDenied, Status.conflict, Status.notFound,
        Status.cancelled, Status.ioError
    ])
    {
        attempts = 0;
        waits = 0;
        reply = terminal;
        assert(withRetry(context, RetryPolicy(5, 10, 40, true), operation, timer).code == terminal);
        assert(attempts == 1 && waits == 0);
    }
    attempts = 0;
    reply = Status.conflict;
    auto predicate = RetryPolicy(4, 10, 40, true);
    predicate.retryOn = &conflictIsReplayable;
    assert(withRetry(context, predicate, operation, timer).code == Status.conflict && attempts == 4);
    attempts = 0;
    predicate.idempotent = false;
    assert(withRetry(context, predicate, operation, timer).code == Status.conflict && attempts == 1);
    attempts = 0;
    reply = Status.ok;
    assert(withRetry(context, RetryPolicy(5, 10, 40, true), operation, timer).code == Status.ok && attempts == 1);
    assert(withRetry(context, RetryPolicy(0), operation, timer).code == Status.invalidArgument);
    assert(withRetry(context, RetryPolicy(3, 50, 10, true), operation, timer).code == Status.invalidArgument);
    assert(withRetry(context, RetryPolicy(3, -1, 10, true), operation, timer).code == Status.invalidArgument);
    assert(withRetry(context, RetryPolicy.init, null, timer).code == Status.invalidArgument);
    assert(withRetry(context, RetryPolicy.init, operation, RetryClock(&now, null, 1)).code == Status.invalidArgument);
}

@("retry_budget: full jitter stays under a doubling bound clipped at maxDelay and is reproducible per seed")
unittest
{
    Context context;
    int attempts;
    ScheduledTask operation = (ref Context) @safe nothrow @nogc {
        ++attempts;
        return Error(Status.unavailable);
    };
    long[16] first;
    foreach (round; 0 .. 2)
    {
        synthetic = 0;
        waits = 0;
        attempts = 0;
        assert(withRetry(context, RetryPolicy(10, 100_000_000, 2_000_000_000, true), operation,
                RetryClock(&now, &recordingWait, 99)).code == Status.unavailable);
        assert(attempts == 10 && waits == 9);
        long bound = 100_000_000;
        foreach (index; 0 .. waits)
        {
            assert(recordedWaits[index] >= 0 && recordedWaits[index] <= bound);
            bound = bound * 2 > 2_000_000_000 ? 2_000_000_000 : bound * 2;
        }
        if (round == 0)
            first = recordedWaits;
        else
            assert(first[0 .. 9] == recordedWaits[0 .. 9]);
    }
    synthetic = 0;
    waits = 0;
    assert(withRetry(context, RetryPolicy(10, 100_000_000, 2_000_000_000, true), operation,
            RetryClock(&now, &recordingWait, 100)).code == Status.unavailable);
    assert(first[0 .. 9] != recordedWaits[0 .. 9]);
}

@("retry_budget: the production wait observes cancellation instead of sleeping the backoff")
unittest
{
    auto owned = CancelSource.create(Context.init, Deadline.none());
    assert(owned.ok);
    auto context = owned.value.context();
    int attempts;
    ScheduledTask operation = (ref Context) @safe nothrow @nogc {
        ++attempts;
        owned.value.cancel();
        return Error(Status.unavailable);
    };
    const started = Deadline.afterMillis(0).monotonicNanoseconds;
    const policy = RetryPolicy(5, 10_000_000_000, 10_000_000_000, true);
    assert(withRetry(context, policy, operation).code == Status.cancelled);
    assert(attempts == 1);
    assert(Deadline.afterMillis(0).monotonicNanoseconds - started < 1_000_000_000);
}

@("circuit_states: fewer than 20 samples never open and the 20th failure opens immediately")
unittest
{
    CircuitBreaker circuit;
    assert(circuit.open().code == Status.ok);
    assert(circuit.open().code == Status.conflict);
    foreach (index; 0 .. 19)
    {
        assert(circuit.permit(index).ok);
        circuit.record(false, index);
        assert(circuit.state == CircuitState.closed);
    }
    assert(circuit.permit(19).ok);
    circuit.record(false, 19);
    assert(circuit.state == CircuitState.open);
    const rejected = circuit.permit(20);
    assert(!rejected.value && rejected.error.code == Status.unavailable);
    assert(circuit.permit(19 + 30_000_000_000L - 1).error.code == Status.unavailable);
    assert(circuit.permit(19 + 30_000_000_000L).ok && circuit.state == CircuitState.halfOpen);
    CircuitBreaker invalid;
    assert(invalid.open(0).code == Status.invalidArgument);
    assert(invalid.open(100, 0).code == Status.invalidArgument);
    assert(invalid.open(100, 101).code == Status.invalidArgument);
    assert(invalid.open(100, 50, 0).code == Status.invalidArgument);
    assert(invalid.permit(0).error.code == Status.invalidArgument);
    assert(invalid.state == CircuitState.closed);
}

@("circuit_states: the rolling window evicts old outcomes and a half-open success resets it")
unittest
{
    CircuitBreaker circuit;
    assert(circuit.open(100, 50, 1000).code == Status.ok);
    long time;
    foreach (_; 0 .. 100)
    {
        assert(circuit.permit(time).ok);
        circuit.record(true, time++);
    }
    foreach (failure; 0 .. 50)
    {
        assert(circuit.state == CircuitState.closed);
        assert(circuit.permit(time).ok);
        circuit.record(false, time++);
    }
    assert(circuit.state == CircuitState.open);
    time += 1000;
    assert(circuit.permit(time).ok && circuit.state == CircuitState.halfOpen);
    circuit.record(true, time);
    assert(circuit.state == CircuitState.closed);
    foreach (_; 0 .. 19)
    {
        assert(circuit.permit(time).ok);
        circuit.record(false, time++);
    }
    assert(circuit.state == CircuitState.closed);
}

@("circuit_states: calls admitted before tripping retire before the half-open probe")
unittest
{
    CircuitBreaker circuit;
    assert(circuit.open(20, 50, 100).code == Status.ok);
    assert(circuit.permit(0).ok);
    foreach (index; 0 .. 20)
    {
        assert(circuit.permit(index).ok);
        circuit.record(false, index);
    }
    assert(circuit.state == CircuitState.open);
    assert(circuit.permit(500).error.code == Status.unavailable);
    circuit.record(true, 500);
    assert(circuit.state == CircuitState.open);
    assert(circuit.permit(501).ok && circuit.state == CircuitState.halfOpen);
    assert(circuit.permit(501).error.code == Status.unavailable);
    circuit.record(false, 501);
    assert(circuit.state == CircuitState.open);
    assert(circuit.permit(560).error.code == Status.unavailable);
    assert(circuit.permit(601).ok);
}

@("rate_limits: integer refill preserves the long-term rate and rejects invalid requests")
unittest
{
    RateLimiter limiter;
    assert(limiter.open(2, 3).code == Status.ok);
    assert(limiter.open(2, 3).code == Status.conflict);
    uint granted;
    foreach (step; 0 .. 10_001)
    {
        while (limiter.acquire(1, step * 1_000_000L).value)
            ++granted;
    }
    assert(granted == 2 + 30);
    RateLimiter bursty;
    assert(bursty.open(5, 7).code == Status.ok);
    granted = 0;
    foreach (step; 0 .. 7_001)
    {
        while (bursty.acquire(1, step * 1_000_000L).value)
            ++granted;
    }
    assert(granted == 5 + 49);
    assert(!bursty.acquire(6, long.max).value && bursty.acquire(5, long.max).value);
    assert(!bursty.acquire(1, 1).value);
    assert(bursty.acquire(0, 0).error.code == Status.invalidArgument);
    assert(bursty.acquire(1, -1).error.code == Status.invalidArgument);
    RateLimiter closed;
    assert(closed.acquire(1, 0).error.code == Status.invalidArgument);
    assert(closed.open(0, 1).code == Status.invalidArgument && closed.open(1, 0).code == Status.invalidArgument);
}
