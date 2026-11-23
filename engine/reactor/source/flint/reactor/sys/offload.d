module flint.reactor.sys.offload;

import core.atomic : atomicLoad, atomicStore, cas;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread.osthread : Thread;
import flint.arena : Status;
import flint.reactor.sys.workers : joinWorker, startWorker;
import flint.reactor.types : OffloadWork, TaskWaker;

@safe:

version (Posix)
{
    import core.sys.posix.fcntl : F_GETFL, F_SETFD, F_SETFL, FD_CLOEXEC, O_NONBLOCK, fcntl;
    import core.sys.posix.unistd : close, pipe, read, write;
}

private enum JobState : uint
{
    free,
    /// Admitted and waiting for a thread. The owner may still abandon it.
    queued,
    /// A thread is calling the work. Only that thread finishes it.
    running,
    /// The work returned. Only the owner loop retires it.
    done,
    /// Abandoned before it started. The thread that dequeues it frees it without calling the work.
    abandoned
}

private struct Job
{
    shared uint state;
    /// Worker whose loop retires this job, published before the job is queued.
    shared uint owner;
    /// Borrowed from the submitting fiber's frame, which stays suspended until the job leaves `running`.
    OffloadWork work;
    TaskWaker waker;
    bool failed;
    uint nextFree;
}

private enum noJob = uint.max;

/// A bounded set of threads that run blocking calls for suspended task fibers. Each worker loop has a
/// signal descriptor that becomes readable when one of its jobs finishes.
package(flint.reactor) final class OffloadPool
{
    private Mutex lock;
    private Condition ready;
    private Job[] jobs;
    private uint[] ring;
    private uint head;
    private uint queued;
    private uint freeJob;
    private Thread[] threads;
    private uint threadCount;
    private bool closing;
    private int[] signalRead;
    private int[] signalWrite;

    /// Reserve `capacity` jobs and one signal per worker. Threads start with `start`.
    this(uint threadCount, uint capacity, uint workers)
    {
        lock = new Mutex;
        ready = new Condition(lock);
        jobs = new Job[capacity];
        ring = new uint[capacity];
        foreach (index, ref job; jobs)
            job.nextFree = index + 1 == capacity ? noJob : cast(uint)(index + 1);
        this.threadCount = threadCount;
        signalRead = new int[workers];
        signalWrite = new int[workers];
        signalRead[] = -1;
        signalWrite[] = -1;
    }

    /// Open every worker's signal. A failure leaves the pool closable.
    Status open() nothrow @nogc
    {
        foreach (index; 0 .. signalRead.length)
            if (!openSignal(signalRead[index], signalWrite[index]))
                return Status.ioError;
        return Status.ok;
    }

    /// Start the threads. Called once by the run owner before any worker runs.
    void start()
    {
        threads = new Thread[threadCount];
        foreach (ref thread; threads)
            thread = startWorker(&serve);
    }

    /// After every worker joined, so no job is queued or running, stop and join the threads.
    void stop()
    {
        lock.lock_nothrow();
        closing = true;
        notifyAll(ready);
        lock.unlock_nothrow();
        foreach (thread; threads)
            if (thread !is null)
                joinWorker(thread);
        threads = null;
    }

    /// Close the signals once no thread runs. Repeated calls do nothing.
    void closeSignals() nothrow @nogc
    {
        assert(threads is null);
        foreach (index; 0 .. signalRead.length)
        {
            closeSignal(signalRead[index]);
            closeSignal(signalWrite[index]);
        }
    }

    /// The descriptor a worker loop watches for finished jobs, or -1 where signals are unsupported.
    int signal(uint worker) const nothrow @nogc
    {
        return signalRead[worker];
    }

    /// Admit `work` for the task `waker` names. Returns a ticket, or zero when every job is taken.
    uint submit(scope OffloadWork work, TaskWaker waker) nothrow @nogc
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        if (closing || freeJob == noJob)
            return 0;
        const slot = freeJob;
        auto job = &jobs[slot];
        freeJob = job.nextFree;
        lend(*job, work);
        job.waker = waker;
        job.failed = false;
        atomicStore(job.owner, waker.ownerCore);
        atomicStore(job.state, cast(uint) JobState.queued);
        ring[(head + queued) % ring.length] = slot;
        ++queued;
        notifyOne(ready);
        return slot + 1;
    }

    /// Withdraw a job no thread has started. Its work will never run and the ticket is spent.
    bool abandon(uint ticket) nothrow @nogc
    {
        return cas(&jobs[ticket - 1].state, cast(uint) JobState.queued, cast(uint) JobState.abandoned);
    }

    /// Whether the work of `ticket` returned.
    bool finished(uint ticket) const nothrow @nogc
    {
        return atomicLoad(jobs[ticket - 1].state) == cast(uint) JobState.done;
    }

    /// Block the calling thread until `ticket` finishes. Only for shutdown, when no fiber may run.
    void waitFinished(uint ticket) const nothrow @nogc
    {
        import core.time : usecs;

        while (!finished(ticket))
            Thread.sleep(usecs(200));
    }

    /// Release a finished job. Returns false when its work ended with a throwable.
    bool retire(uint ticket) nothrow @nogc
    {
        auto job = &jobs[ticket - 1];
        assert(atomicLoad(job.state) == cast(uint) JobState.done);
        const failed = job.failed;
        recycle(ticket - 1);
        return !failed;
    }

    /// Number of job slots.
    size_t capacity() const nothrow @nogc
    {
        return jobs.length;
    }

    /// The waker of job `slot` when `worker` owns it and its work returned, else an empty waker.
    TaskWaker finishedWaker(uint worker, size_t slot) const nothrow @nogc
    {
        const job = &jobs[slot];
        // Only `worker` publishes jobs it owns, so the waker cannot change under this read.
        if (atomicLoad(job.owner) == worker && atomicLoad(job.state) == cast(uint) JobState.done)
            return job.waker;
        return TaskWaker.init;
    }

    /// Consume every pending wakeup byte of `worker`'s signal.
    void drain(uint worker) nothrow @nogc
    {
        drainSignal(signalRead[worker]);
    }

    private void recycle(uint slot) nothrow @nogc
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        auto job = &jobs[slot];
        job.work = null;
        job.waker = TaskWaker.init;
        atomicStore(job.owner, uint.max);
        atomicStore(job.state, cast(uint) JobState.free);
        job.nextFree = freeJob;
        freeJob = slot;
    }

    private void serve() nothrow
    {
        for (;;)
        {
            lock.lock_nothrow();
            while (queued == 0 && !closing)
                waitOn(ready);
            if (queued == 0)
            {
                lock.unlock_nothrow();
                return;
            }
            const slot = ring[head];
            head = cast(uint)((head + 1) % ring.length);
            --queued;
            lock.unlock_nothrow();

            auto job = &jobs[slot];
            if (!cas(&job.state, cast(uint) JobState.queued, cast(uint) JobState.running))
            {
                recycle(slot);
                continue;
            }
            job.failed = !invoke(job.work);
            const owner = atomicLoad(job.owner);
            // The owner may retire the job as soon as it reads `done`; nothing below touches it.
            atomicStore(job.state, cast(uint) JobState.done);
            raiseSignal(signalWrite[owner]);
        }
    }
}

// The submitting fiber stays suspended until its job is abandoned while queued or returns from running,
// then retires it, which clears the delegate. No thread calls the delegate after that.
// SAFETY: The borrowed frame outlives every call of the delegate, as described above.
private void lend(ref Job job, scope OffloadWork work) @trusted nothrow @nogc
{
    job.work = work;
}

// An Error ending a pool thread would strand its fiber forever, so it is collected and reported as a
// failed job, the way a task fiber's throwable is returned to its loop instead of unwinding it.
// SAFETY: Only calls the borrowed work; the throwable is dropped, not retained or rethrown.
private bool invoke(OffloadWork work) @trusted nothrow
{
    import std.exception : collectException;

    return collectException!Throwable(work()) is null;
}

// SAFETY: A pthread condition wait on the pool's own condition while the caller holds its mutex.
private void waitOn(Condition condition) @trusted nothrow
{
    try
        condition.wait();
    catch (Exception)
    {
        // Only the accessor of the condition's own mutex is declared throwing; treat it as a wakeup.
    }
}

// SAFETY: Signals the pool's own live condition; the call retains nothing.
private void notifyOne(Condition condition) @trusted nothrow @nogc
{
    condition.notify(true);
}

// SAFETY: Signals the pool's own live condition; the call retains nothing.
private void notifyAll(Condition condition) @trusted nothrow @nogc
{
    condition.notifyAll(true);
}

// SAFETY: pipe writes two descriptors into a local array; fcntl only changes flags of those descriptors.
private bool openSignal(ref int reader, ref int writer) @trusted nothrow @nogc
{
    version (Posix)
    {
        int[2] ends;
        if (pipe(ends) != 0)
            return false;
        reader = ends[0];
        writer = ends[1];
        foreach (end; ends)
        {
            const flags = fcntl(end, F_GETFL);
            if (flags < 0 || fcntl(end, F_SETFL, flags | O_NONBLOCK) != 0 || fcntl(end, F_SETFD, FD_CLOEXEC) != 0)
                return false;
        }
        return true;
    }
    else
        return true;
}

// SAFETY: Closes a descriptor this pool opened and marks it closed so it is never closed twice.
private void closeSignal(ref int descriptor) @trusted nothrow @nogc
{
    version (Posix)
        if (descriptor >= 0)
            close(descriptor);
    descriptor = -1;
}

// SAFETY: Writes one byte from a local to the pool's nonblocking pipe. A full pipe already signals.
private void raiseSignal(int descriptor) @trusted nothrow @nogc
{
    version (Posix)
    {
        if (descriptor < 0)
            return;
        ubyte one = 1;
        cast(void) write(descriptor, &one, 1);
    }
}

// SAFETY: Reads into a bounded local buffer from the pool's nonblocking pipe until it is empty.
private void drainSignal(int descriptor) @trusted nothrow @nogc
{
    version (Posix)
    {
        if (descriptor < 0)
            return;
        ubyte[64] sink;
        while (read(descriptor, sink.ptr, sink.length) > 0)
        {
        }
    }
}
