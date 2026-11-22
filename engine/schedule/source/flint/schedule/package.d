module flint.schedule;

import core.atomic : atomicLoad, cas;
import core.lifetime : move;
import core.thread.fiber : Fiber;
import core.thread.osthread : Thread;
import flint.arena : Error, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : Reactor;
import flint.schedule.cron : Cron, firstSecond, lastSecond, parseCron;
import flint.schedule.resilience : currentNanoseconds, saturatingAdd, waitUntil;
import std.traits : getUDAs;

public import flint.schedule.resilience : CircuitBreaker, CircuitState, MonotonicClock, RateLimiter,
    Retryable, RetryClock, RetryPolicy, RetryPredicate, ScheduledTask, withRetry;

@safe:

/// Configuration for exactly one recurring schedule.
struct Scheduled
{
    /// Six numeric cron fields in UTC.
    string cron;
    /// Interval measured from the original monotonic anchor.
    long fixedRateNanos;
    /// Interval measured from the last completion.
    long fixedDelayNanos;
    /// Permit overlapping fixed-rate or cron invocations within the configured active limit.
    bool concurrent;
}

/// The scheduler runs on its owning thread and dispatches only when polled.
struct Scheduler
{
    private State control;

    /// Preallocate the job table, deadline queues, and invocation slots on the owner thread.
    Error open(uint capacity = 1024)
    {
        return open(capacity, capacity < 32 ? capacity : 32, &currentNanoseconds);
    }

    /// Set a separate in-flight capacity and clock for completion time accounting.
    Error open(uint capacity, uint maxActive, MonotonicClock clock)
    {
        if (control !is null && !control.closed)
            return Error(Status.conflict, "scheduler already open");
        if (capacity == 0 || capacity > 65_536 || maxActive == 0 || maxActive > capacity || clock is null)
            return Error(Status.invalidArgument, "invalid scheduler limits");
        control = new State(capacity, maxActive, clock);
        return Error.init;
    }

    /// Install a validated job and return its lifetime identity.
    Result!ulong add(string name, Scheduled schedule, ScheduledTask task)
    {
        if (control is null || !control.onOwner || control.closing || name.length == 0 || task is null
                || !validMode(schedule))
            return Result!ulong(0, Error(Status.invalidArgument, "invalid scheduled job or owner"));
        Cron cron;
        if (schedule.cron.length != 0)
        {
            const parsed = parseCron(schedule.cron);
            if (!parsed.ok)
                return Result!ulong(0, parsed.error);
            cron = parsed.value;
        }
        return control.add(schedule, cron, task);
    }

    /// Remove pending delivery and cancel any active invocations for this job.
    Error cancel(ulong taskId) nothrow @nogc
    {
        if (control is null || !control.onOwner)
            return Error(Status.invalidArgument, "invalid scheduler owner");
        control.cancel(taskId);
        return Error.init;
    }

    /// Admit due invocations using UTC seconds and a process monotonic timestamp.
    Error poll(long utcSeconds, long monotonicNanos) nothrow @nogc
    {
        if (control is null || !control.onOwner || monotonicNanos < 0 || utcSeconds < firstSecond
                || utcSeconds > lastSecond)
            return Error(Status.invalidArgument, "invalid scheduler owner or clock");
        return control.poll(utcSeconds, monotonicNanos);
    }

    /// Cancel active invocations and retire the scheduler within the caller's deadline.
    Error close(ref Context context) nothrow @nogc
    {
        if (control is null)
            return Error.init;
        if (!control.onOwner)
            return Error(Status.invalidArgument, "invalid scheduler owner");
        const outcome = control.close(context);
        if (outcome.code == Status.ok)
            control = null;
        return outcome;
    }
}

private bool validMode(Scheduled schedule) pure nothrow @nogc
{
    const modes = cast(uint)(schedule.cron.length != 0) + (schedule.fixedRateNanos != 0) + (
            schedule.fixedDelayNanos != 0);
    return modes == 1 && schedule.fixedRateNanos >= 0 && schedule.fixedDelayNanos >= 0;
}

private struct Job
{
    ScheduledTask invoke;
    Cron calendar;
    long rate;
    long delay;
    long due;
    ulong id;
    uint active;
    uint heapPosition;
    bool usesWallTime;
    bool concurrent;
    bool cancelled;
}

private struct Invocation
{
    CancelSource cancelSource;
    Fiber fiber;
    ulong jobId;
}

private struct Queue
{
    private uint[] indices;
    private uint count;

    uint head() const pure nothrow @nogc
    {
        assert(count != 0);
        return indices[0];
    }

    void insert(scope Job[] jobs, uint job) nothrow @nogc
    {
        assert(count < indices.length && jobs[job].heapPosition == 0);
        place(jobs, count, job);
        siftUp(jobs, count++);
    }

    void remove(scope Job[] jobs, uint job) nothrow @nogc
    {
        const position = jobs[job].heapPosition;
        if (position == 0)
            return;
        jobs[job].heapPosition = 0;
        const index = position - 1;
        --count;
        if (index == count)
            return;
        place(jobs, index, indices[count]);
        if (index != 0 && earlier(jobs, indices[index], indices[(index - 1) / 2]))
            siftUp(jobs, index);
        else
            siftDown(jobs, index);
    }

    private void place(scope Job[] jobs, uint index, uint job) nothrow @nogc
    {
        indices[index] = job;
        jobs[job].heapPosition = index + 1;
    }

    private void swap(scope Job[] jobs, uint first, uint second) nothrow @nogc
    {
        const saved = indices[first];
        place(jobs, first, indices[second]);
        place(jobs, second, saved);
    }

    private void siftUp(scope Job[] jobs, uint index) nothrow @nogc
    {
        while (index != 0)
        {
            const parent = (index - 1) / 2;
            if (!earlier(jobs, indices[index], indices[parent]))
                return;
            swap(jobs, index, parent);
            index = parent;
        }
    }

    private void siftDown(scope Job[] jobs, uint index) nothrow @nogc
    {
        while (index * 2 + 1 < count)
        {
            auto child = index * 2 + 1;
            if (child + 1 < count && earlier(jobs, indices[child + 1], indices[child]))
                ++child;
            if (!earlier(jobs, indices[child], indices[index]))
                return;
            swap(jobs, index, child);
            index = child;
        }
    }

    private static bool earlier(scope const(Job)[] jobs, uint first, uint second) pure nothrow @nogc
    {
        return jobs[first].due < jobs[second].due || (jobs[first].due == jobs[second].due
                && jobs[first].id < jobs[second].id);
    }
}

@("scheduler_bench: deadline heap stays ordered with depth <= ceil(log2(capacity)) through slot reuse")
unittest
{
    enum uint capacity = 1_000;
    enum uint maximumDepth = 10; // ceil(log2(1000)); depth counts edges from the root.
    auto jobs = new Job[capacity];
    Queue heap;
    heap.indices = new uint[capacity];
    uint random = 0x5eed;
    uint next()
    {
        random = random * 1_664_525 + 1_013_904_223;
        return random >> 8;
    }

    void verify()
    {
        assert(heap.count <= capacity);
        foreach (position; 0 .. heap.count)
        {
            assert(jobs[heap.indices[position]].heapPosition == position + 1);
            uint depth;
            for (auto at = position; at != 0; at = (at - 1) / 2)
                ++depth;
            assert(depth <= maximumDepth);
            if (position != 0)
                assert(!Queue.earlier(jobs, heap.indices[position], heap.indices[(position - 1) / 2]));
        }
    }

    ulong id;
    foreach (round; 0 .. 200)
    {
        foreach (slot; 0 .. capacity)
        {
            if (jobs[slot].heapPosition == 0 && next() % 2 == 0)
            {
                jobs[slot].due = next() % 64;
                jobs[slot].id = ++id;
                heap.insert(jobs, slot);
            }
        }
        verify();
        foreach (_; 0 .. capacity / 3)
            heap.remove(jobs, next() % capacity);
        verify();
        while (heap.count != 0 && next() % 4 != 0)
        {
            const head = heap.head();
            heap.remove(jobs, head);
            foreach (position; 0 .. heap.count)
                assert(!Queue.earlier(jobs, heap.indices[position], head));
        }
        verify();
    }
}

private long nextRate(long due, long now, long period) pure nothrow @nogc
{
    return saturatingAdd(now, period - (now - due) % period);
}

private shared ulong sequence;

private ulong issueId(uint index) nothrow @nogc
{
    for (auto previous = atomicLoad(sequence); previous < ulong.max >> 16; previous = atomicLoad(sequence))
    {
        if (cas(&sequence, previous, previous + 1))
            return ((previous + 1) << 16) | index;
    }
    return 0;
}

private final class State
{
    private Job[] jobs;
    private Invocation[] invocations;
    private uint[] freeSlots;
    private uint[] freeRuns;
    private uint slotCount;
    private uint runCount;
    private Queue monotonicQueue;
    private Queue wallQueue;
    private Thread owner;
    private MonotonicClock clock;
    private long nowWall;
    private long nowMonotonic;
    private long suppliedMonotonic;
    private bool observedClocks;
    private bool closing;
    private bool closed;

    this(uint capacity, uint maxActive, MonotonicClock clock)
    {
        jobs = new Job[capacity];
        invocations = new Invocation[maxActive];
        freeSlots = new uint[capacity];
        freeRuns = new uint[maxActive];
        monotonicQueue.indices = new uint[capacity];
        wallQueue.indices = new uint[capacity];
        foreach (i; 0 .. capacity)
            freeSlots[i] = capacity - i - 1;
        foreach (i; 0 .. maxActive)
            freeRuns[i] = maxActive - i - 1;
        slotCount = capacity;
        runCount = maxActive;
        owner = Thread.getThis();
        this.clock = clock;
    }

    bool onOwner() const nothrow @nogc
    {
        return owner is Thread.getThis();
    }

    Result!ulong add(Scheduled schedule, Cron cron, ScheduledTask task) nothrow @nogc
    {
        if (slotCount == 0)
            return Result!ulong(0, Error(Status.resourceExhausted, "scheduled job capacity reached"));
        const index = freeSlots[slotCount - 1];
        const id = issueId(index);
        if (id == 0)
            return Result!ulong(0, Error(Status.resourceExhausted, "scheduled job IDs exhausted"));
        --slotCount;
        auto job = &jobs[index];
        job.id = id;
        job.invoke = task;
        job.calendar = cron;
        job.usesWallTime = schedule.cron.length != 0;
        job.rate = schedule.fixedRateNanos;
        job.delay = schedule.fixedDelayNanos;
        job.concurrent = schedule.concurrent && job.delay == 0;
        if (observedClocks)
            initializeDue(index);
        return Result!ulong(id);
    }

    void cancel(ulong id) nothrow @nogc
    {
        if (id == 0 || closed)
            return;
        const index = cast(uint)(id & 0xFFFF);
        if (index >= jobs.length)
            return;
        auto job = &jobs[index];
        if (job.id != id)
            return;
        job.cancelled = true;
        queue(*job).remove(jobs, index);
        if (job.active == 0)
            recycle(index);
        else
        {
            foreach (ref invocation; invocations)
            {
                if (invocation.jobId == id)
                    invocation.cancelSource.cancel();
            }
        }
    }

    Error poll(long utcSeconds, long monotonicNanos) nothrow @nogc
    {
        if (closing)
            return Error(Status.cancelled, "scheduler is closing");
        observeClocks(utcSeconds, monotonicNanos);
        const wallHorizon = nowWall;
        const monotonicHorizon = suppliedMonotonic;
        Error firstFailure;
        foreach (iteration; 0 .. jobs.length)
        {
            const index = ready(wallHorizon, monotonicHorizon, iteration % 2 == 0);
            if (index == uint.max || closing)
                break;
            if (runCount == 0)
                return Error(Status.unavailable, "scheduled invocations are at capacity");
            auto source = CancelSource.create(Context.init, Deadline.none());
            if (!source.ok)
                return source.error;
            const outcome = invoke(index, move(source.value));
            if (firstFailure.code == Status.ok && outcome.code != Status.ok)
                firstFailure = outcome;
        }
        return firstFailure;
    }

    private void observeClocks(long utcSeconds, long monotonicNanos) nothrow @nogc
    {
        if (!observedClocks)
        {
            nowWall = utcSeconds;
            nowMonotonic = monotonicNanos;
            observedClocks = true;
            foreach (index, ref job; jobs)
            {
                if (job.id != 0)
                    initializeDue(cast(uint) index);
            }
        }
        if (utcSeconds > nowWall)
            nowWall = utcSeconds;
        if (monotonicNanos > nowMonotonic)
            nowMonotonic = monotonicNanos;
        if (monotonicNanos > suppliedMonotonic)
            suppliedMonotonic = monotonicNanos;
    }

    private Error invoke(uint index, CancelSource source) nothrow @nogc
    {
        const runIndex = freeRuns[--runCount];
        auto invocation = &invocations[runIndex];
        invocation.cancelSource = move(source);
        invocation.fiber = Fiber.getThis();
        auto job = &jobs[index];
        ++job.active;
        invocation.jobId = job.id;
        queue(*job).remove(jobs, index);
        if (job.concurrent)
            queueNext(index);
        const start = clock();
        const atAdmission = nowMonotonic;
        auto context = invocation.cancelSource.context();
        const outcome = job.invoke(context);
        const finish = clock();
        if (finish > start && start >= 0)
        {
            const observedEnd = saturatingAdd(atAdmission, finish - start);
            if (observedEnd > nowMonotonic)
                nowMonotonic = observedEnd;
        }
        retire(index, runIndex);
        return outcome;
    }

    Error close(ref Context context) nothrow @nogc
    {
        if (closed)
            return Error.init;
        if (!closing)
        {
            closing = true;
            foreach (ref active; invocations)
            {
                if (active.jobId != 0)
                    active.cancelSource.cancel();
            }
        }
        while (runCount != invocations.length)
        {
            if (executingOnCurrentFiber() || !Reactor.current().currentTask().ok)
                return Error(Status.unavailable, "scheduler join requires a separate owner reactor task");
            const status = waitUntil(context, saturatingAdd(currentNanoseconds(), 1_000_000));
            if (status.code != Status.ok)
                return status;
        }
        closed = true;
        jobs = null;
        invocations = null;
        monotonicQueue = Queue.init;
        wallQueue = Queue.init;
        freeSlots = null;
        freeRuns = null;
        return Error.init;
    }

    private bool executingOnCurrentFiber() const nothrow @nogc
    {
        const current = Fiber.getThis();
        foreach (ref active; invocations)
        {
            if (active.jobId != 0 && active.fiber is current)
                return true;
        }
        return false;
    }

    private ref Queue queue(ref const Job job) return scope nothrow @nogc
    {
        return job.usesWallTime ? wallQueue : monotonicQueue;
    }

    private void initializeDue(uint index) nothrow @nogc
    {
        auto job = &jobs[index];
        job.due = job.usesWallTime ? job.calendar.nextAfter(nowWall) : saturatingAdd(nowMonotonic,
                job.rate != 0 ? job.rate : job.delay);
        if (job.due != long.max)
            queue(*job).insert(jobs, index);
    }

    private uint ready(long wallHorizon, long monotonicHorizon, bool preferWall) const nothrow @nogc
    {
        const wallReady = wallQueue.count != 0 && jobs[wallQueue.head()].due <= wallHorizon;
        const monoReady = monotonicQueue.count != 0 && jobs[monotonicQueue.head()].due <= monotonicHorizon;
        if (wallReady && (preferWall || !monoReady))
            return wallQueue.head();
        return monoReady ? monotonicQueue.head() : uint.max;
    }

    private void queueNext(uint index) nothrow @nogc
    {
        auto job = &jobs[index];
        if (job.usesWallTime)
            job.due = job.calendar.nextAfter(nowWall);
        else if (job.rate != 0)
            job.due = nextRate(job.due, nowMonotonic, job.rate);
        else
            job.due = saturatingAdd(nowMonotonic, job.delay);
        if (job.due != long.max)
            queue(*job).insert(jobs, index);
    }

    private void retire(uint index, uint runIndex) nothrow @nogc
    {
        auto invocation = &invocations[runIndex];
        invocation.cancelSource.close();
        invocation.jobId = 0;
        invocation.fiber = null;
        freeRuns[runCount++] = runIndex;
        auto job = &jobs[index];
        --job.active;
        if (job.cancelled && job.active == 0)
            recycle(index);
        else if (!closing && !job.concurrent)
            queueNext(index);
    }

    private void recycle(uint index) nothrow @nogc
    {
        jobs[index] = Job.init;
        freeSlots[slotCount++] = index;
    }
}

private ScheduledTask retrying(ScheduledTask invoke, RetryPolicy policy)
{
    return (ref Context context) @safe nothrow @nogc => withRetry(context, policy, invoke);
}

/// Register annotated methods. Class instances retain their identity. Struct values are copied into owned storage.
Error registerScheduled(T)(ref Scheduler scheduler, ref T component)
{
    static if (is(T == class) || is(T == interface))
    {
        if (component is null)
            return Error(Status.invalidArgument, "null scheduled component");
        return registerMethods!(T, T)(scheduler, component);
    }
    else static if (is(T == S*, S) && is(S == struct))
        return registerScheduled!S(scheduler, component);
    else
    {
        // An array literal copies through the struct's own copy semantics; `new T(component)` would
        // be read as field-wise construction and fails for any struct whose first field is not a T.
        T[] owned = [component];
        return registerMethods!(T, T*)(scheduler, &owned[0]);
    }
}

/// Register methods on a managed struct instance supplied by the caller.
Error registerScheduled(T)(ref Scheduler scheduler, T* instance) if (is(T == struct))
{
    if (instance is null)
        return Error(Status.invalidArgument, "null scheduled component");
    return registerMethods!(T, T*)(scheduler, instance);
}

private Error registerMethods(T, I)(ref Scheduler scheduler, I instance)
{
    ulong[] enrolled;
    bool complete;
    scope (exit)
    {
        if (!complete)
        {
            foreach (id; enrolled)
                scheduler.cancel(id);
        }
    }
    static foreach (member; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getOverloads, T, member)))
        {
            static foreach (method; __traits(getOverloads, T, member))
            {
                {
                    alias schedule = getUDAs!(method, Scheduled);
                    alias retry = getUDAs!(method, Retryable);
                    static if (schedule.length != 0)
                    {
                        static assert(schedule.length == 1 && validMode(schedule[0]),
                                "scheduled method requires exactly one scheduling mode");
                        static if (schedule[0].cron.length != 0)
                            static assert(parseCron(schedule[0].cron).ok, "invalid scheduled cron expression");
                        static assert(retry.length <= 1, "scheduled method accepts at most one retry policy");
                        alias Member = typeof(&__traits(getMember, instance, member));
                        static assert(is(Member : ScheduledTask), "scheduled method must match ScheduledTask");
                        ScheduledTask invoke = &__traits(getMember, instance, member);
                        static if (retry.length == 1)
                        {
                            enum Retryable spec = retry[0];
                            static assert(spec.maxAttempts != 0 && spec.initialDelayNanos >= 0
                                    && spec.maxDelayNanos >= spec.initialDelayNanos, "invalid scheduled retry policy");
                            invoke = retrying(invoke, RetryPolicy(spec.maxAttempts,
                                    spec.initialDelayNanos, spec.maxDelayNanos, true));
                        }
                        const added = scheduler.add(T.stringof ~ "." ~ member, schedule[0], invoke);
                        if (!added.ok)
                            return added.error;
                        enrolled ~= added.value;
                    }
                }
            }
        }
    }
    complete = true;
    return Error.init;
}
