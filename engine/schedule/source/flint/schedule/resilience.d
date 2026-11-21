module flint.schedule.resilience;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : nsecs;
import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.reactor : Reactor;

@safe:

/// Register a retrying invoker for a scheduled, idempotent method.
struct Retryable
{
    /// Total attempts, including the initial invocation.
    uint maxAttempts = 3;
    /// Initial upper bound for jitter in nanoseconds.
    long initialDelayNanos = 100_000_000L;
    /// Maximum upper bound for exponential backoff.
    long maxDelayNanos = 2_000_000_000L;
}

alias RetryPredicate = bool function(Error outcome) @safe nothrow @nogc;

/// Retry configuration for one explicitly replayable operation.
struct RetryPolicy
{
    /// Total attempts, including the first one.
    uint maxAttempts = 3;
    /// Initial backoff bound.
    long initialDelayNanos = 100_000_000L;
    /// Maximum backoff bound.
    long maxDelayNanos = 2_000_000_000L;
    /// The caller guarantees replay preserves externally visible behavior.
    bool idempotent;
    /// Optional predicate for explicitly known replayable outcomes.
    RetryPredicate retryOn;
}

alias ScheduledTask = Error delegate(ref Context context) @safe nothrow @nogc;
alias MonotonicClock = long function() @safe nothrow @nogc;
alias RetryWait = Error function(ref Context context, long until) @safe nothrow @nogc;

/// An explicit clock and wait adapter, useful for reproducible retry schedules.
struct RetryClock
{
    /// Sample the adapter's monotonic clock.
    MonotonicClock now;
    /// Wait for a monotonic instant or return the context's terminal status.
    RetryWait waitUntil;
    /// Seed used by the per-invocation jitter generator.
    ulong seed;
}

/// Current admission phase of a circuit breaker.
enum CircuitState : ubyte
{
    closed,
    open,
    halfOpen
}

/// A rolling circuit breaker. Pair every successful permit with exactly one completion.
struct CircuitBreaker
{
    private Circuit control;

    /// Reserve a rolling window and set failure and recovery thresholds.
    Error open(uint window = 100, uint failurePercent = 50, long openNanos = 30_000_000_000L)
    {
        if (control !is null)
            return Error(Status.conflict, "circuit breaker already open");
        if (window == 0 || window > 1_048_576 || failurePercent == 0 || failurePercent > 100 || openNanos <= 0)
            return Error(Status.invalidArgument, "invalid circuit breaker settings");
        control = new Circuit(window, failurePercent, openNanos);
        return Error.init;
    }

    /// Admit an operation or return unavailable during a recovery window.
    Result!bool permit(long nowNanos) nothrow @nogc
    {
        if (control is null || nowNanos < 0)
            return Result!bool(false, Error(Status.invalidArgument, "invalid circuit or time"));
        return control.permit(nowNanos);
    }

    /// Record the outcome of one completed call and advance the circuit state.
    void record(bool success, long nowNanos) nothrow @nogc
    {
        if (control !is null && nowNanos >= 0)
            control.record(success, nowNanos);
    }

    /// Sample the phase published by the most recent transition.
    CircuitState state() const nothrow @nogc
    {
        return control is null ? CircuitState.closed : atomicLoad(control.phase);
    }
}

private final class Circuit
{
    private Mutex gate;
    private shared CircuitState phase;
    private bool[] failed;
    private uint threshold;
    private uint samples;
    private uint failures;
    private uint position;
    private ulong workInFlight;
    private uint minimum;
    private long openNanos;
    private long retryAt;
    private long watermark;

    this(uint window, uint failurePercent, long delay)
    {
        gate = new Mutex;
        failed = new bool[window];
        minimum = window < 20 ? window : 20;
        threshold = failurePercent;
        openNanos = delay;
    }

    Result!bool permit(long now) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        now = observeTime(now);
        const phase = atomicLoad(this.phase);
        if (phase == CircuitState.closed && workInFlight != ulong.max)
        {
            ++workInFlight;
            return Result!bool(true);
        }
        // Finish requests admitted before the circuit opened so a late result cannot be mistaken for the probe.
        if (phase == CircuitState.open && workInFlight == 0 && now >= retryAt)
        {
            atomicStore(this.phase, CircuitState.halfOpen);
            return Result!bool(true);
        }
        return Result!bool(false, Error(Status.unavailable, "circuit is open"));
    }

    void record(bool success, long now) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        now = observeTime(now);
        final switch (atomicLoad(phase))
        {
        case CircuitState.open:
            if (workInFlight != 0)
                --workInFlight;
            break;
        case CircuitState.halfOpen:
            if (success)
            {
                samples = 0;
                failures = 0;
                position = 0;
                atomicStore(phase, CircuitState.closed);
            }
            else
                trip(now);
            break;
        case CircuitState.closed:
            if (workInFlight != 0)
                --workInFlight;
            if (samples < failed.length)
                ++samples;
            else if (failed[position])
                --failures;
            failed[position] = !success;
            if (!success)
                ++failures;
            if (++position == failed.length)
                position = 0;
            if (samples >= minimum && cast(ulong) failures * 100 >= cast(ulong) samples * threshold)
                trip(now);
            break;
        }
    }

    private long observeTime(long now) nothrow @nogc
    {
        if (now > watermark)
            watermark = now;
        return watermark;
    }

    private void trip(long now) nothrow @nogc
    {
        retryAt = saturatingAdd(now, openNanos);
        atomicStore(phase, CircuitState.open);
    }
}

/// An integer token bucket that carries sub-token credit between admissions.
struct RateLimiter
{
    private Bucket control;

    /// Initialize a full bucket at the specified capacity and refill rate.
    Error open(uint burst, uint tokensPerSecond)
    {
        if (control !is null)
            return Error(Status.conflict, "rate limiter already open");
        if (burst == 0 || tokensPerSecond == 0)
            return Error(Status.invalidArgument, "invalid token bucket settings");
        control = new Bucket(burst, tokensPerSecond);
        return Error.init;
    }

    /// Refill using elapsed monotonic time and attempt to debit whole tokens.
    Result!bool acquire(uint tokens, long nowNanos) nothrow @nogc
    {
        if (control is null || tokens == 0 || nowNanos < 0)
            return Result!bool(false, Error(Status.invalidArgument, "invalid token bucket request"));
        return Result!bool(control.acquire(tokens, nowNanos));
    }
}

private final class Bucket
{
    private enum ulong creditsPerToken = 1_000_000_000;
    private Mutex gate;
    private immutable ulong capacity;
    private immutable uint rate;
    private ulong credit;
    private long last;

    this(uint burst, uint rate)
    {
        gate = new Mutex;
        capacity = cast(ulong) burst * creditsPerToken;
        credit = capacity;
        this.rate = rate;
    }

    bool acquire(uint tokens, long now) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        if (now > last)
        {
            const elapsed = cast(ulong)(now - last);
            const room = capacity - credit;
            credit += elapsed > room / rate ? room : elapsed * rate;
            last = now;
        }
        const needed = cast(ulong) tokens * creditsPerToken;
        if (needed > credit)
            return false;
        credit -= needed;
        return true;
    }
}

package(flint.schedule) long saturatingAdd(long time, long duration) pure nothrow @nogc
{
    return time > long.max - duration ? long.max : time + duration;
}

private ulong sample(ref ulong state) pure nothrow @nogc
{
    state ^= state >> 12;
    state ^= state << 25;
    state ^= state >> 27;
    return state * 2_685_821_657_736_338_717UL;
}

package(flint.schedule) long currentNanoseconds() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

package(flint.schedule) Error waitUntil(ref Context context, long until) nothrow @nogc
{
    for (;;)
    {
        const status = context.check();
        if (status.code != Status.ok)
            return status;
        const now = currentNanoseconds();
        if (now >= until)
            return Error.init;
        const next = until - now > 10_000_000 ? now + 10_000_000 : until;
        auto reactor = Reactor.current();
        const suspended = reactor.yieldUntil(Deadline(next));
        if (suspended.code == Status.notFound)
            Thread.sleep((next - now).nsecs);
        else if (suspended.code != Status.ok)
            return suspended;
    }
}

private Error checkDeadline(ref Context context, MonotonicClock now) nothrow @nogc
{
    const status = context.check();
    if (status.code != Status.ok)
        return status;
    const deadline = context.deadline().monotonicNanoseconds;
    if (deadline != long.max && now() >= deadline)
        return Error(Status.timedOut, "context deadline elapsed");
    return Error.init;
}

/// Invoke an operation with deadline-aware jitter on the current reactor or thread.
Error withRetry(ref Context context, RetryPolicy policy, scope ScheduledTask operation) nothrow @nogc
{
    return withRetry(context, policy, operation, RetryClock(&currentNanoseconds, &waitUntil,
            cast(ulong) currentNanoseconds()));
}

/// Invoke an operation with an explicit clock, wait adapter, and deterministic seed.
Error withRetry(ref Context context, RetryPolicy policy, scope ScheduledTask operation, RetryClock clock) nothrow @nogc
{
    if (operation is null || !validRetry(policy, clock))
        return Error(Status.invalidArgument, "invalid retry configuration");
    ulong random = clock.seed == 0 ? 0x240dac145f917ad5UL : clock.seed;
    auto delay = policy.initialDelayNanos;
    for (uint attempt; attempt < policy.maxAttempts; ++attempt)
    {
        const status = checkDeadline(context, clock.now);
        if (status.code != Status.ok)
            return status;
        const outcome = operation(context);
        if (attempt == policy.maxAttempts - 1 || !canRetry(outcome, policy))
            return outcome;
        const jitter = cast(long)(sample(random) % (cast(ulong) delay + 1));
        auto until = saturatingAdd(clock.now(), jitter);
        const deadline = context.deadline().monotonicNanoseconds;
        if (until > deadline)
            until = deadline;
        const waited = clock.waitUntil(context, until);
        if (waited.code != Status.ok)
            return waited;
        delay = delay > policy.maxDelayNanos / 2 ? policy.maxDelayNanos : delay * 2;
    }
    assert(0, "at least one retry attempt was validated");
}

private bool validRetry(RetryPolicy policy, RetryClock clock) pure nothrow @nogc
{
    return clock.now !is null && clock.waitUntil !is null && policy.maxAttempts != 0
        && policy.initialDelayNanos >= 0 && policy.maxDelayNanos >= policy.initialDelayNanos;
}

private bool canRetry(Error outcome, RetryPolicy policy) nothrow @nogc
{
    if (!policy.idempotent || outcome.code == Status.ok)
        return false;
    return outcome.code == Status.unavailable || outcome.code == Status.timedOut
        || (policy.retryOn !is null && policy.retryOn(outcome));
}
