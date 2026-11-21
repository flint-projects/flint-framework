module flint.reactor;

import core.atomic : atomicLoad, atomicStore, cas;
import core.lifetime : move;
import core.memory : GC;
import core.thread : Fiber, Thread;
import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.reactor.internal.operations : OperationId, OperationTable;
import flint.reactor.internal.queues : Mailbox, Message, Timers;
import flint.reactor.sys.fibers : createFiber, releaseFiber, resetFiber, resumeFiber, yieldFiber;
import flint.reactor.sys.workers : availableCpus, joinWorker, pinWorker, startWorker, workerUsage, yieldWorker;

public import flint.reactor.types : AcceptDelegate, AcceptFn, Backend, Completion, CompletionDelegate, CompletionFn,
    ConnectionId, IoId, ListenOptions, NativeInterest, NativeReadyFn, ReadDelegate, ReactorOptions,
    ReadFn, TaskContext, TaskDelegate, TaskFn, TimerId, WorkerStats;

@safe:

version (Posix)
{
    import flint.reactor.sys.sockets : Socket, acceptConnection, bindListener, closeSocket, receive,
        socketPort, transmit;
    import flint.reactor.sys.readiness : Interest, Readiness, ReadyEvent, destroyReadiness,
        directions, openReadiness, poll, setInterest;
}
version (linux)
{
    import flint.reactor.sys.completion : CompletionPort, KernelEvent, cancelKernel, closeCompletionPort,
        openCompletionPort, pollCompletion, submitAccept, submitRead, submitReadable, submitWrite;
    import flint.reactor.sys.nativewatch : NativeWatches;
}
else version (OSX)
    version = ReactorReadinessOnly;
else version (Windows)
    import flint.reactor.sys.windows : CompletionPort, KernelEvent, Socket, bindListener,
        cancelKernel, closeCompletionPort,
        closeSocket, openCompletionPort, pollCompletion, socketPort, submitAccept, submitRead, submitWrite;

private enum State : ubyte
{
    configured,
    starting,
    running,
    stopping,
    stopped
}

private shared ulong lastIdentity;
private Runtime* currentRuntime;
private uint currentWorkerIndex = uint.max;
private enum noSlot = uint.max;
private enum listenToken = 1UL;
private enum nativeWatchToken = 2UL;
private enum waitBudgetMillis = 5;
private enum maxIdentity = ulong.max >> 16;

private ulong nextIdentity() nothrow @nogc
{
    for (;;)
    {
        const previous = atomicLoad(lastIdentity);
        if (previous == maxIdentity)
            return 0;
        if (cas(&lastIdentity, previous, previous + 1))
            return previous + 1;
    }
}

private bool validQueueSizes(ReactorOptions options) pure nothrow @nogc
{
    return options.completionsPerTick != 0 && options.maxConnectionsPerCore > 0
        && options.maxConnectionsPerCore <= ushort.max && options.mailboxCapacity > 0
        && options.mailboxCapacity <= ushort.max && options.maxTimersPerCore > 0
        && options.maxTimersPerCore <= ushort.max && options.maxNativeWatchesPerCore <= ushort.max;
}

private bool validStorage(ReactorOptions options, uint workers) pure nothrow @nogc
{
    return options.maxPendingIoPerCore > 0 && options.maxPendingIoPerCore <= 8192 && options.ioBufferBytes > 0
        && options.ioBufferBytes <= 1_048_576 && options.fiberPoolSize > 0 && options.fiberPoolSize <= ushort.max
        && options.fiberStackBytes >= 16_384 && options.fiberStackBytes <= 1_048_576
        && cast(ulong) workers * options.maxPendingIoPerCore * options.ioBufferBytes <= 512UL * 1024 * 1024;
}

/// Noncopyable owner for a bounded, single-run reactor.
struct Reactor
{
    private Runtime* runtime;
    private bool owner;

    @disable this(this);

    ~this() nothrow @nogc
    {
        if (!owner || runtime is null)
            return;
        const state = atomicLoad(runtime.state);
        if (state == State.configured || state == State.stopping)
        {
            // A stopped-before-run owner can release its startup allocations here. A running owner
            // retains them until run joins all workers.
            if (!atomicLoad(runtime.runStarted))
                runtime.release();
        }
    }

    /// Reserve resources and select a platform backend.
    static Result!Reactor create(ReactorOptions options)
    {
        auto cpus = availableCpus();
        const count = options.cores == 0 ? cast(uint) cpus.length : options.cores;
        if (count == 0 || count > cpus.length || !validQueueSizes(options) || !validStorage(options, count))
            return Result!Reactor(Reactor.init, Error(Status.invalidArgument, "invalid reactor limits"));

        auto runtime = new Runtime;
        runtime.options = options;
        runtime.workers = new Worker[count];
        foreach (index, ref worker; runtime.workers)
            worker.initialize(runtime, cast(uint) index, cpus[index]);
        const result = runtime.prepareBackend(options.backend);
        if (result.code != Status.ok)
        {
            runtime.release();
            return Result!Reactor(Reactor.init, result);
        }

        Result!Reactor created;
        created.value.runtime = runtime;
        created.value.owner = true;
        return move(created);
    }

    /// The calling loop's borrowed facade. Startup and one-time execution require the owning handle.
    static Reactor current() nothrow @nogc
    {
        Reactor handle;
        handle.runtime = currentRuntime;
        return handle;
    }

    /// Open the sole listening socket and register the owner-loop acceptance callback.
    Error listen(ListenOptions options, AcceptFn accept)
    {
        return bindListenerCallback(options, accept, null);
    }

    /// Set up a listener with application-owned context. It must support concurrent calls on different cores.
    Error listenWith(ListenOptions options, AcceptDelegate accept)
    {
        return bindListenerCallback(options, null, accept);
    }

    private Error bindListenerCallback(ListenOptions options, AcceptFn accept, AcceptDelegate bound)
    {
        if (!owner || runtime is null || (accept is null && bound is null))
            return Error(Status.invalidArgument, "invalid listener");
        if (atomicLoad(runtime.state) != State.configured || runtime.listener.valid)
            return Error(Status.conflict, "listener already configured or reactor started");
        auto socket = bindListener(options.host, options.port, options.backlog);
        if (!socket.ok)
            return socket.error;
        const port = socketPort(socket.value);
        if (!port.ok)
        {
            closeSocket(socket.value);
            return port.error;
        }
        runtime.listener = socket.value;
        runtime.port = port.value;
        runtime.accept = accept;
        runtime.acceptDelegate = bound;
        return Error.init;
    }

    /// Run the prepared event loops once and join them on shutdown.
    Error run()
    {
        if (!owner || runtime is null)
            return Error(Status.invalidArgument, "invalid reactor owner");
        if (!cas(&runtime.state, State.configured, State.starting))
            return Error(Status.conflict, "reactor already started or stopped");
        atomicStore(runtime.runStarted, true);
        return runtime.run();
    }

    /// Request shutdown. Final I/O completions still retire on their owners.
    void stop() nothrow @nogc
    {
        if (runtime !is null)
            runtime.stop();
    }

    /// Admit a callback with a default task context to a worker mailbox.
    Error post(uint ownerCore, TaskFn task) nothrow @nogc
    {
        return post(ownerCore, task, TaskContext.init);
    }

    /// Admit a callback with a copied cancellation context and correlation identity.
    Error post(uint ownerCore, TaskFn task, TaskContext context) nothrow @nogc
    {
        if (runtime is null || task is null || ownerCore >= runtime.workers.length)
            return Error(Status.invalidArgument, "invalid task or owner core");
        if (atomicLoad(runtime.state) >= State.stopping)
            return Error(Status.unavailable, "reactor is stopping");
        return Error(runtime.workers[ownerCore].mailbox.enqueue(Message(task, ConnectionId.init, move(context))));
    }

    /// Retain a task delegate for dispatch as a fiber on the current owner core.
    Error postWith(uint ownerCore, TaskDelegate task, TaskContext context = TaskContext.init) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime || ownerCore != currentWorkerIndex || task is null)
            return Error(Status.invalidArgument, "bound task requires its owner and callback");
        if (atomicLoad(runtime.state) != State.running)
            return Error(Status.unavailable, "reactor is not running");
        auto message = Message(null, ConnectionId.init, move(context), task);
        return Error(runtime.workers[ownerCore].mailbox.enqueue(move(message)));
    }

    /// Mark the connection draining on its owner or queue the request to that owner.
    Error close(ConnectionId connection) nothrow @nogc
    {
        if (runtime is null || connection.ownerCore >= runtime.workers.length || connection.generation == 0)
            return Error(Status.invalidArgument, "invalid connection handle");
        if (currentRuntime is runtime && currentWorkerIndex == connection.ownerCore)
            return Error(runtime.workers[currentWorkerIndex].closeConnection(connection));
        if (atomicLoad(runtime.state) != State.running)
            return Error(Status.unavailable, "reactor is not running");
        return Error(runtime.workers[connection.ownerCore].mailbox.enqueue(Message(null, connection)));
    }

    /// Return the current owner index or uint.max outside this reactor.
    uint currentCore() const nothrow @nogc
    {
        return runtime !is null && currentRuntime is runtime ? currentWorkerIndex : uint.max;
    }

    /// Reserve a single receive of at most maxBytes on the connection owner.
    Result!IoId read(ConnectionId connection, size_t maxBytes, Context context, ReadFn completion) nothrow @nogc
    {
        return queueRead(connection, maxBytes, context, IoCallbacks(completion));
    }

    /// Reserve a receive and keep an owned delegate through the final completion.
    Result!IoId readWith(ConnectionId connection, size_t maxBytes, Context context, ReadDelegate done) nothrow @nogc
    {
        return queueRead(connection, maxBytes, context, IoCallbacks(null, done));
    }

    private Result!IoId queueRead(ConnectionId id, size_t limit, Context context, IoCallbacks callbacks) nothrow @nogc
    {
        if (currentCore() != id.ownerCore || currentRuntime is null || !callbacks.reading)
            return Result!IoId(IoId.init, Error(Status.invalidArgument, "read requires its owner and callback"));
        return runtime.workers[currentWorkerIndex].queueIo(id, limit, null, context, callbacks);
    }

    /// Copy a bounded write into slot-owned storage and send its bytes before completion.
    Result!IoId write(ConnectionId id, scope const(ubyte)[] bytes, Context context, CompletionFn done) nothrow @nogc
    {
        return sendTo(id, bytes, context, IoCallbacks(null, null, done));
    }

    /// Copy a bounded write and retain its delegate through the final completion.
    Result!IoId writeWith(ConnectionId id, scope const(ubyte)[] data, Context ctx, CompletionDelegate fn) nothrow @nogc
    {
        return sendTo(id, data, ctx, IoCallbacks(null, null, null, fn));
    }

    private Result!IoId sendTo(ConnectionId id, scope const(ubyte)[] data, Context ctx, IoCallbacks cb) nothrow @nogc
    {
        if (currentCore() != id.ownerCore || currentRuntime is null || (cb.write is null && cb.boundWrite is null))
            return Result!IoId(IoId.init, Error(Status.invalidArgument, "write requires its owner and callback"));
        return runtime.workers[currentWorkerIndex].queueIo(id, data.length, data, ctx, cb);
    }

    /// Request cancellation of the ticket. Its final callback still runs exactly once.
    Error cancel(IoId operation) nothrow @nogc
    {
        if (currentCore() != operation.connection.ownerCore || currentRuntime is null)
            return Error(Status.invalidArgument, "operation cancellation requires its owner");
        return Error(runtime.workers[currentWorkerIndex].cancelIo(operation));
    }

    /// Schedule a one-shot callback on the current owner loop.
    Result!TimerId schedule(Deadline deadline, TaskFn task) nothrow @nogc
    {
        if (currentRuntime is null || currentRuntime !is runtime || task is null
                || deadline.monotonicNanoseconds == Deadline.none.monotonicNanoseconds)
            return Result!TimerId(TimerId.init, Error(Status.invalidArgument, "invalid deadline, task or owner"));
        if (atomicLoad(runtime.state) != State.running)
            return Result!TimerId(TimerId.init, Error(Status.unavailable, "reactor is stopping"));
        const generation = nextIdentity();
        if (generation == 0)
            return Result!TimerId(TimerId.init, Error(Status.resourceExhausted, "timer identities exhausted"));
        const timer = TimerId(currentWorkerIndex, cast(uint) generation, generation);
        const status = runtime.workers[currentWorkerIndex].timers.schedule(timer, deadline, task);
        return status == Status.ok ? Result!TimerId(timer) : Result!TimerId(TimerId.init,
                Error(status, "timer capacity exhausted"));
    }

    /// Cancel a pending timer owned by the calling loop.
    Error cancel(TimerId timer) nothrow @nogc
    {
        if (currentCore() != timer.ownerCore || currentRuntime is null)
            return Error(Status.invalidArgument, "timer cancellation requires its owner");
        return Error(runtime.workers[currentWorkerIndex].timers.cancel(timer));
    }

    /// The active fiber's context. Loop callbacks have no implicit request context.
    Result!TaskContext currentTask() const nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Result!TaskContext(TaskContext.init, Error(Status.notFound, "no active fiber"));
        return runtime.workers[currentWorkerIndex].activeTask();
    }

    /// Yield only from a task fiber. The same owner resumes it on deadline, cancellation, or shutdown.
    Error yieldUntil(Deadline deadline) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Error(Status.notFound, "no active fiber");
        return runtime.workers[currentWorkerIndex].yieldTask(deadline);
    }

    /// Create or update a Linux watch on the current worker. The caller keeps ownership of fd and
    /// removes the watch before releasing the descriptor or callback. Error readiness is always delivered.
    Error watchNative(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
    {
        version (linux)
        {
            enum valid = NativeInterest.read | NativeInterest.write | NativeInterest.error;
            if (fd < 0 || callback is null || interest == NativeInterest.none || (interest & ~valid) != 0)
                return Error(Status.invalidArgument, "invalid native descriptor watch");
            if (runtime is null || currentRuntime !is runtime || atomicLoad(runtime.state) != State.running)
                return Error(Status.conflict, "native watch requires a running owner loop");
            return runtime.workers[currentWorkerIndex].watchNative(fd, interest, callback);
        }
        else
            return Error(Status.unsupported, "native descriptor watches require Linux");
    }

    /// Drop a Linux watch from its owner loop. Remains available during cancellation and shutdown.
    Error unwatchNative(int fd) nothrow @nogc
    {
        version (linux)
        {
            if (fd < 0)
                return Error(Status.invalidArgument, "invalid native descriptor");
            if (runtime is null || currentRuntime !is runtime)
                return Error(Status.conflict, "native watch removal requires its owner loop");
            return Error(runtime.workers[currentWorkerIndex].nativeWatches.remove(fd));
        }
        else
            return Error(Status.unsupported, "native descriptor watches require Linux");
    }

    /// Return the port selected by a successful listen.
    Result!ushort localPort() const nothrow @nogc
    {
        if (runtime is null || runtime.port == 0)
            return Result!ushort(0, Error(Status.notFound, "listener port unavailable"));
        return Result!ushort(runtime.port);
    }

    /// Return the actual backend selected at creation.
    Backend activeBackend() const nothrow @nogc
    {
        return runtime is null ? Backend.automatic : runtime.backend;
    }

    /// Retrieve GC and affinity observations once all workers have joined.
    Result!WorkerStats workerStats(uint core) const nothrow @nogc
    {
        if (runtime is null || core >= runtime.workers.length)
            return Result!WorkerStats(WorkerStats.init, Error(Status.invalidArgument, "invalid worker index"));
        if (atomicLoad(runtime.state) != State.stopped)
            return Result!WorkerStats(WorkerStats.init, Error(Status.unavailable, "workers have not joined"));
        return Result!WorkerStats(runtime.workers[core].stats);
    }
}

private struct Runtime
{
    shared State state;
    shared bool runStarted;
    ReactorOptions options;
    Worker[] workers;
    Backend backend;
    Socket listener;
    ushort port;
    AcceptFn accept;
    AcceptDelegate acceptDelegate;

    @disable this(this);

    Error prepareBackend(Backend requested) nothrow @nogc
    {
        version (linux)
        {
            if (requested == Backend.automatic || requested == Backend.ioUring)
            {
                const failure = prepareCompletion(Backend.ioUring);
                if (failure.code == Status.ok || requested == Backend.ioUring)
                    return failure;
                if (failure.code != Status.unsupported && failure.code != Status.permissionDenied
                        && failure.code != Status.unavailable)
                    return failure;
            }
            if (requested == Backend.automatic || requested == Backend.epoll)
                return prepareReadiness(Backend.epoll);
        }
        else version (OSX)
        {
            if (requested == Backend.automatic || requested == Backend.kqueue)
                return prepareReadiness(Backend.kqueue);
        }
        else version (Windows)
        {
            if (requested == Backend.automatic || requested == Backend.iocp)
                return prepareCompletion(Backend.iocp);
        }
        return Error(Status.unsupported, "reactor backend is unavailable on this target");
    }

    version (Posix)
    {
        Error prepareReadiness(Backend selected) nothrow @nogc
        {
            backend = selected;
            foreach (ref worker; workers)
            {
                const poller = openReadiness();
                if (!poller.ok)
                    return poller.error;
                worker.readiness = poller.value;
            }
            return Error.init;
        }
    }

    version (ReactorReadinessOnly)
    {
    }
    else
    {
        Error prepareCompletion(Backend selected) nothrow @nogc
        {
            backend = selected;
            const entries = 2 * (options.maxPendingIoPerCore + 1);
            foreach (ref worker; workers)
            {
                auto port = openCompletionPort(entries);
                if (!port.ok)
                {
                    foreach (ref opened; workers)
                        closeCompletionPort(opened.completions);
                    return port.error;
                }
                worker.completions = port.value;
            }
            return Error.init;
        }
    }

    Error run()
    {
        scope (exit)
        {
            foreach (ref worker; workers)
                worker.releaseFibers();
            release();
            atomicStore(state, State.stopped);
        }

        version (Posix)
        {
            if (listener.valid && (backend == Backend.epoll || backend == Backend.kqueue))
            {
                foreach (ref worker; workers)
                {
                    const status = setInterest(worker.readiness, listener, listenToken, Interest.none, Interest.read);
                    if (status != Status.ok)
                        return Error(status, "could not register listener");
                }
            }
        }

        foreach (ref worker; workers)
            worker.preallocateFibers();

        auto threads = new Thread[workers.length];
        size_t started;
        scope (failure)
        {
            stop();
            foreach (thread; threads[0 .. started])
                joinWorker(thread);
        }
        foreach (ref worker; workers)
        {
            threads[started] = startWorker(&worker.execute);
            ++started;
        }
        cas(&state, State.starting, State.running);

        Error result;
        foreach (thread; threads)
        {
            if (joinWorker(thread) !is null)
            {
                result = Error(Status.ioError, "worker terminated unexpectedly");
                stop();
            }
        }
        foreach (ref worker; workers)
            if (worker.failure.code != Status.ok)
                return worker.failure;
        return result;
    }

    void stop() nothrow @nogc
    {
        for (;;)
        {
            const observed = atomicLoad(state);
            if (observed >= State.stopping || cas(&state, observed, State.stopping))
                return;
        }
    }

    void release() nothrow @nogc
    {
        foreach (ref worker; workers)
            worker.release();
        closeSocket(listener);
        acceptDelegate = null;
    }
}

private struct Connection
{
    Socket socket;
    ulong generation;
    uint next;
    OperationId read;
    OperationId write;
    uint delivering;
    bool draining;
    version (Posix) Interest interest;
}

private struct IoCallbacks
{
    ReadFn read;
    ReadDelegate boundRead;
    CompletionFn write;
    CompletionDelegate boundWrite;

    bool reading() const pure nothrow @nogc
    {
        return read !is null || boundRead !is null;
    }
}

private struct IoWork
{
    OperationId id;
    ConnectionId connection;
    Context context;
    IoCallbacks callbacks;
    size_t length;
    size_t offset;
    bool started;
    bool pending;
    bool cancelSent;
    Status cancellation;
}

private struct FiberTask
{
    Fiber fiber;
    TaskFn task;
    TaskDelegate boundTask;
    TaskContext context;
    Deadline wake;
    uint next;

    bool occupied() const pure nothrow @nogc
    {
        return task !is null || boundTask !is null;
    }
}

private void enterTask() @safe nothrow @nogc
{
    currentRuntime.workers[currentWorkerIndex].executeTask();
}

private struct Worker
{
    Runtime* runtime;
    uint index;
    uint cpu;
    Error failure;
    WorkerStats stats;
    Connection[] connections;
    uint nextFree;
    OperationTable operations;
    IoWork[] workItems;
    ubyte[] buffers;
    uint liveOperations;
    Mailbox mailbox;
    Timers timers;
    FiberTask[] fibers;
    uint freeFiber = noSlot;
    uint activeFiber = noSlot;
    uint activeFiberCount;

    version (Posix) Readiness readiness;

    version (linux)
    {
        NativeWatches nativeWatches;
        bool nativePending;
        bool nativeCancelSent;
    }

    version (ReactorReadinessOnly)
    {
    }
    else
    {
        CompletionPort completions;
        bool acceptPending;
        bool acceptCancelSent;
        uint cancellationAcks;
    }

    @disable this(this);

    void initialize(Runtime* runtime, uint index, uint cpu)
    {
        this.runtime = runtime;
        this.index = index;
        this.cpu = cpu;

        const options = runtime.options;
        connections = new Connection[options.maxConnectionsPerCore];
        foreach (slot, ref connection; connections)
            connection.next = cast(uint)(slot + 1);
        connections[$ - 1].next = noSlot;
        operations = OperationTable(options.maxPendingIoPerCore);
        workItems = new IoWork[options.maxPendingIoPerCore];
        buffers = new ubyte[cast(size_t) options.ioBufferBytes * options.maxPendingIoPerCore];
        mailbox.initialize(options.mailboxCapacity);
        timers.initialize(options.maxTimersPerCore);
        version (linux)
            nativeWatches.reserve(options.maxNativeWatchesPerCore);
    }

    void preallocateFibers()
    {
        fibers = new FiberTask[runtime.options.fiberPoolSize];
        foreach (slot, ref task; fibers)
        {
            task.fiber = createFiber(&enterTask, runtime.options.fiberStackBytes);
            task.next = cast(uint)(slot + 1);
        }
        fibers[$ - 1].next = noSlot;
        freeFiber = 0;
    }

    void releaseFibers()
    {
        foreach (ref task; fibers)
            releaseFiber(task.fiber);
        fibers = null;
    }

    Result!TaskContext activeTask() const nothrow @nogc
    {
        if (activeFiber == noSlot)
            return Result!TaskContext(TaskContext.init, Error(Status.notFound, "no active fiber"));
        return Result!TaskContext(fibers[activeFiber].context);
    }

    Error yieldTask(Deadline deadline) nothrow @nogc
    {
        if (activeFiber == noSlot)
            return Error(Status.notFound, "no active fiber");
        if (deadline.monotonicNanoseconds == Deadline.none.monotonicNanoseconds)
            return Error(Status.invalidArgument, "fiber yield requires a finite deadline");
        if (atomicLoad(runtime.state) != State.running)
            return Error(Status.cancelled, "reactor is stopping");
        auto task = &fibers[activeFiber];
        const initial = task.context.cancellation.check();
        if (initial.code != Status.ok)
            return initial;
        task.wake = deadline;
        yieldFiber();
        if (atomicLoad(runtime.state) != State.running)
            return Error(Status.cancelled, "reactor is stopping");
        return task.context.cancellation.check();
    }

    void executeTask() nothrow @nogc
    {
        auto task = &fibers[activeFiber];
        if (task.context.cancellation.check().code != Status.ok)
            return;
        if (task.task !is null)
            task.task();
        else
            task.boundTask();
    }

    private void startTask(ref Message message) nothrow @nogc
    {
        assert(freeFiber != noSlot);
        const slot = freeFiber;
        auto task = &fibers[slot];
        freeFiber = task.next;
        task.task = message.task;
        task.boundTask = message.boundTask;
        task.context = move(message.context);
        ++activeFiberCount;
        resumeTask(slot);
    }

    private void resumeTask(uint slot) nothrow @nogc
    {
        auto task = &fibers[slot];
        activeFiber = slot;
        const failure = resumeFiber(task.fiber);
        activeFiber = noSlot;
        if (task.fiber.state == Fiber.State.TERM)
        {
            resetFiber(task.fiber);
            task.task = null;
            task.boundTask = null;
            task.context = TaskContext.init;
            task.next = freeFiber;
            freeFiber = slot;
            --activeFiberCount;
        }
        if (failure !is null)
            fail(Error(Status.ioError, "reactor task fiber terminated with an error"));
    }

    private void resumeReadyTasks(bool stopping = false) nothrow @nogc
    {
        if (activeFiberCount == 0)
            return;
        const now = Deadline.afterMillis(0);
        uint used;
        foreach (slot, ref task; fibers)
        {
            if (!stopping && used == runtime.options.completionsPerTick)
                break;
            if (task.occupied && (stopping || task.wake.monotonicNanoseconds <= now.monotonicNanoseconds
                    || task.context.cancellation.check().code != Status.ok))
            {
                resumeTask(cast(uint) slot);
                ++used;
            }
        }
    }

    void execute() nothrow @nogc
    {
        currentRuntime = runtime;
        currentWorkerIndex = index;
        scope (exit)
        {
            currentWorkerIndex = uint.max;
            currentRuntime = null;
        }
        stats.affinityPinned = pinWorker(cpu);
        while (atomicLoad(runtime.state) == State.starting)
            yieldWorker();

        const initialUsage = workerUsage();
        const initialGc = GC.stats.allocatedInCurrentThread;
        const initialCollections = GC.profileStats.numCollections;
        while (atomicLoad(runtime.state) == State.running)
        {
            resumeReadyTasks();
            processMessages();
            processTimers();
            if (atomicLoad(runtime.state) != State.running)
                break;
            advanceOperations();
            const wait = timers.waitMillis(Deadline.afterMillis(0), waitBudgetMillis);
            version (ReactorReadinessOnly)
            {
                waitForReadiness(wait);
            }
            else
            {
                if (completions.valid)
                {
                    advanceAccept();
                    version (linux)
                        advanceNativeWatch();
                    waitForCompletions(wait);
                }
                else
                {
                    version (Posix)
                        waitForReadiness(wait);
                }
            }
        }
        resumeReadyTasks(true);
        drain();
        stats.gcAllocated = GC.stats.allocatedInCurrentThread - initialGc;
        stats.gcCollections = GC.profileStats.numCollections - initialCollections;
        const finalUsage = workerUsage();
        stats.cpuNanos = finalUsage.cpuNanos - initialUsage.cpuNanos;
        stats.voluntarySwitches = finalUsage.voluntarySwitches - initialUsage.voluntarySwitches;
        stats.involuntarySwitches = finalUsage.involuntarySwitches - initialUsage.involuntarySwitches;
        stats.outstandingOperations = liveOperations;
    }

    void release() nothrow @nogc
    {
        mailbox.seal();
        version (Posix)
            destroyReadiness(readiness);
        version (ReactorReadinessOnly)
        {
        }
        else
        {
            closeCompletionPort(completions);
        }
        version (linux)
            nativeWatches.release();
    }

    version (linux)
    {
        Error watchNative(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
        {
            if (!nativeWatches.enabled)
                return Error(Status.resourceExhausted, "native descriptor watches are disabled");
            if (!nativeWatches.receiver.valid)
            {
                auto created = openReadiness();
                if (!created.ok)
                    return created.error;
                if (readiness.valid)
                {
                    const registered = setInterest(readiness, Socket(created.value.descriptor),
                            nativeWatchToken, Interest.none, Interest.read);
                    if (registered != Status.ok)
                    {
                        destroyReadiness(created.value);
                        return Error(registered, "could not attach native descriptor poller");
                    }
                }
                nativeWatches.receiver = created.value;
            }
            return Error(nativeWatches.update(fd, interest, callback));
        }

        private void advanceNativeWatch() nothrow @nogc
        {
            if (!nativeWatches.receiver.valid || nativePending)
                return;
            const outcome = submitReadable(completions, nativeWatches.receiver.descriptor, nativeWatchToken);
            if (outcome == Status.ok)
                nativePending = true;
            else if (outcome != Status.unavailable)
                fail(Error(outcome, "could not submit native descriptor readiness"));
        }

        private void notifyNativeWatches() nothrow @nogc
        {
            const outcome = nativeWatches.notify(runtime.options.completionsPerTick);
            if (outcome.code != Status.ok)
                fail(outcome);
        }

        private void completeNativeWatch(Status status) nothrow @nogc
        {
            nativePending = false;
            nativeCancelSent = false;
            if (atomicLoad(runtime.state) != State.running)
                return;
            if (status == Status.ok)
                notifyNativeWatches();
            else if (status != Status.unavailable)
                fail(Error(status, "native descriptor readiness failed"));
        }
    }

    private void processMessages() nothrow @nogc
    {
        Message next;
        foreach (_; 0 .. runtime.options.completionsPerTick)
        {
            if (atomicLoad(runtime.state) != State.running || freeFiber == noSlot || !mailbox.dequeue(next))
                break;
            if (next.task !is null || next.boundTask !is null)
                startTask(next);
            else
                closeConnection(next.close);
        }
    }

    private void processTimers() nothrow @nogc
    {
        const now = Deadline.afterMillis(0);
        foreach (_; 0 .. runtime.options.completionsPerTick)
        {
            if (atomicLoad(runtime.state) != State.running)
                break;
            auto task = timers.takeDue(now);
            if (task is null)
                break;
            task();
        }
    }

    private void fail(Error error) nothrow @nogc
    {
        if (failure.code == Status.ok)
            failure = error;
        runtime.stop();
    }

    private void admit(Socket incoming) nothrow @nogc
    {
        if (nextFree == noSlot || atomicLoad(runtime.state) != State.running)
        {
            closeSocket(incoming);
            return;
        }

        const generation = nextIdentity();
        if (generation == 0)
        {
            closeSocket(incoming);
            fail(Error(Status.resourceExhausted, "connection identities exhausted"));
            return;
        }
        const slot = nextFree;
        auto connection = &connections[slot];
        nextFree = connection.next;
        *connection = Connection(incoming, generation);
        const id = ConnectionId(index, slot, generation);
        if (runtime.accept !is null)
            runtime.accept(id);
        else
            runtime.acceptDelegate(id);
    }

    private bool validConnection(ConnectionId id) const nothrow @nogc
    {
        return id.ownerCore == index && id.generation != 0 && id.slot < connections.length
            && connections[id.slot].generation == id.generation;
    }

    Status closeConnection(ConnectionId id) nothrow @nogc
    {
        if (!validConnection(id))
            return Status.notFound;

        connections[id.slot].draining = true;
        closeIdle(id.slot);
        return Status.ok;
    }

    private void closeIdle(uint slot) nothrow @nogc
    {
        auto connection = &connections[slot];
        if (!connection.draining || connection.read.generation != 0
                || connection.write.generation != 0 || connection.delivering != 0)
            return;
        closeSocket(connection.socket);
        *connection = Connection.init;
        connection.next = nextFree;
        nextFree = slot;
    }

    Result!IoId queueIo(ConnectionId id, size_t length, scope const(ubyte)[] input, Context context,
            IoCallbacks callbacks) nothrow @nogc
    {
        if (atomicLoad(runtime.state) != State.running)
            return Result!IoId(IoId.init, Error(Status.unavailable, "reactor is stopping"));
        if (!validConnection(id))
            return Result!IoId(IoId.init, Error(Status.notFound, "connection not found"));
        if (length == 0 || length > runtime.options.ioBufferBytes)
            return Result!IoId(IoId.init, Error(Status.invalidArgument, "invalid I/O byte limit"));

        auto connection = &connections[id.slot];
        if (connection.draining)
            return Result!IoId(IoId.init, Error(Status.unavailable, "connection is closing"));
        if ((callbacks.reading ? connection.read : connection.write).generation != 0)
            return Result!IoId(IoId.init, Error(Status.conflict, "operation in this direction already active"));

        const reserved = operations.reserve(id);
        if (!reserved.ok)
            return Result!IoId(IoId.init, reserved.error);

        auto operation = reserved.value;
        auto work = &workItems[operation.slot];
        work.id = operation;
        work.connection = id;
        work.context = context;
        work.callbacks = callbacks;
        work.length = length;
        if (callbacks.reading)
            connection.read = operation;
        else
        {
            connection.write = operation;
            operationBuffer(operation.slot)[0 .. length] = input;
        }
        ++liveOperations;
        return Result!IoId(IoId(id, operation.slot, operation.generation));
    }

    Status cancelIo(IoId operation) nothrow @nogc
    {
        if (operation.generation == 0 || operation.slot >= workItems.length)
            return Status.notFound;
        auto work = &workItems[operation.slot];
        if (work.id.generation != operation.generation || work.connection != operation.connection)
            return Status.notFound;
        return requestCancel(work.id, Status.cancelled);
    }

    private Status requestCancel(OperationId id, Status reason) nothrow @nogc
    {
        const status = operations.requestCancellation(id, reason);
        if (status == Status.ok && workItems[id.slot].cancellation == Status.ok)
            workItems[id.slot].cancellation = reason;
        return status;
    }

    private ubyte[] operationBuffer(uint slot) nothrow @nogc
    {
        const length = runtime.options.ioBufferBytes;
        const offset = cast(size_t) slot * length;
        return buffers[offset .. offset + length];
    }

    private void advanceOperations() nothrow @nogc
    {
        foreach (ref work; workItems)
        {
            if (work.id.generation == 0)
                continue;
            advanceOperation(work.id);
        }
    }

    private void observeCancellation(OperationId id) nothrow @nogc
    {
        auto work = &workItems[id.slot];
        if (work.cancellation != Status.ok)
            return;
        if (connections[work.connection.slot].draining)
        {
            requestCancel(id, Status.cancelled);
            return;
        }
        const status = work.context.check().code;
        if (status == Status.timedOut || status == Status.cancelled)
            requestCancel(id, status);
    }

    private void advanceOperation(OperationId id) nothrow @nogc
    {
        observeCancellation(id);
        auto work = &workItems[id.slot];
        if (work.cancellation != Status.ok)
        {
            if (!work.pending)
                deliver(id, work.cancellation, work.offset);
            else
            {
                version (ReactorReadinessOnly)
                {
                    assert(0, "readiness must not retain buffer pointers");
                }
                else
                {
                    if (!work.cancelSent)
                        cancelInFlight(id.token, work.cancelSent);
                }
            }
            return;
        }
        if (!work.started)
        {
            const status = operations.start(id);
            assert(status == Status.ok);
            work.started = true;
        }
        version (ReactorReadinessOnly)
        {
            refreshInterest(work.connection.slot);
        }
        else
        {
            if (completions.valid)
            {
                if (!work.pending)
                    submitOperation(id);
            }
            else
            {
                version (Posix)
                    refreshInterest(work.connection.slot);
            }
        }
    }

    private void deliver(OperationId id, Status status, size_t bytes) nothrow @nogc
    {
        auto work = &workItems[id.slot];
        assert(work.id == id && !work.pending);
        const done = operations.finish(id, status, bytes);
        assert(done.ok);

        const slot = work.connection.slot;
        auto connection = &connections[slot];
        ++connection.delivering;
        if (work.callbacks.reading)
        {
            connection.read = OperationId.init;
            scope const(ubyte)[] data;
            if (done.value.status == Status.ok)
                data = operationBuffer(id.slot)[0 .. bytes];
            if (work.callbacks.read !is null)
                work.callbacks.read(done.value, data);
            else
                work.callbacks.boundRead(done.value, data);
        }
        else
        {
            connection.write = OperationId.init;
            if (work.callbacks.write !is null)
                work.callbacks.write(done.value);
            else
                work.callbacks.boundWrite(done.value);
        }
        --connection.delivering;
        const retired = operations.retire(id);
        assert(retired == Status.ok);
        *work = IoWork.init;
        --liveOperations;
        closeIdle(slot);

        version (Posix)
        {
            if (readiness.valid && connection.socket.valid)
                refreshInterest(slot);
        }
    }

    version (Posix)
    {
        private ulong readinessToken(uint slot) const nothrow @nogc
        {
            return (connections[slot].generation << 16) | slot;
        }

        private void refreshInterest(uint slot) nothrow @nogc
        {
            auto connection = &connections[slot];
            const desired = directions(connection.read.generation != 0, connection.write.generation != 0);
            const status = setInterest(readiness, connection.socket, readinessToken(slot),
                    connection.interest, desired);
            if (status != Status.ok)
                fail(Error(status, "could not update readiness registration"));
            else
                connection.interest = desired;
        }

        private void waitForReadiness(uint millis) nothrow @nogc
        {
            ReadyEvent[64] events;
            const budget = runtime.options.completionsPerTick;
            const count = budget < events.length ? budget : events.length;
            const ready = poll(readiness, events[0 .. count], millis);
            if (!ready.ok)
            {
                fail(ready.error);
                return;
            }
            foreach (event; events[0 .. ready.value])
            {
                if (atomicLoad(runtime.state) != State.running)
                    return;
                version (linux)
                {
                    if (event.token == nativeWatchToken)
                    {
                        notifyNativeWatches();
                        continue;
                    }
                }
                if (event.token == listenToken)
                {
                    auto incoming = acceptConnection(runtime.listener);
                    if (incoming.ok)
                        admit(incoming.value);
                    else if (incoming.error.code != Status.unavailable)
                        fail(incoming.error);
                    continue;
                }
                const id = ConnectionId(index, cast(ushort) event.token, event.token >> 16);
                if (!validConnection(id))
                    continue;
                auto connection = &connections[id.slot];
                if ((event.directions & Interest.read) && connection.read.generation != 0)
                    performReadyIo(connection.read);
                if (validConnection(id) && (event.directions & Interest.write) && connection.write.generation != 0)
                    performReadyIo(connection.write);
            }
        }

        private void performReadyIo(OperationId id) nothrow @nogc
        {
            // The previous callback in this poll batch may have cancelled or queued an operation.
            advanceOperation(id);
            auto work = &workItems[id.slot];
            if (work.id != id)
                return;

            auto socket = connections[work.connection.slot].socket;
            auto buffer = operationBuffer(id.slot);
            const result = work.callbacks.reading ? receive(socket,
                    buffer[0 .. work.length]) : transmit(socket, buffer[work.offset .. work.length]);
            if (result.error.code == Status.unavailable)
                return;
            completeIo(id, result.error.code, result.value);
        }
    }

    private void completeIo(OperationId id, Status status, size_t bytes) nothrow @nogc
    {
        auto work = &workItems[id.slot];
        if (bytes > work.length - work.offset)
        {
            fail(Error(Status.ioError, "kernel reported out-of-bounds transfer"));
            deliver(id, Status.ioError, work.offset);
            return;
        }

        work.offset += bytes;
        if (work.cancellation != Status.ok || status != Status.ok || work.callbacks.reading || work.offset
                == work.length)
            deliver(id, status, work.offset);
        else if (bytes == 0)
            deliver(id, Status.ioError, work.offset);
    }

    version (ReactorReadinessOnly)
    {
    }
    else
    {
        private void advanceAccept() nothrow @nogc
        {
            if (acceptPending || !runtime.listener.valid)
                return;
            version (Windows)
            {
                if (index != 0)
                    return;
            }
            const status = submitAccept(completions, runtime.listener);
            if (status == Status.ok)
                acceptPending = true;
            else if (status != Status.unavailable)
                fail(Error(status, "asynchronous accept submission failed"));
        }

        private void submitOperation(OperationId id) nothrow @nogc
        {
            auto work = &workItems[id.slot];
            auto connection = &connections[work.connection.slot];
            auto buffer = operationBuffer(id.slot);
            const status = work.callbacks.reading ? submitRead(completions, connection.socket,
                    buffer[0 .. work.length], id.token) : submitWrite(completions,
                    connection.socket, buffer[work.offset .. work.length], id.token);
            if (status == Status.ok)
                work.pending = true;
            else if (status != Status.unavailable)
                deliver(id, status, work.offset);
        }

        private void cancelInFlight(ulong token, ref bool sent) nothrow @nogc
        {
            const status = cancelKernel(completions, token);
            if (status == Status.ok)
            {
                sent = true;
                version (linux)
                    ++cancellationAcks;
            }
            else if (status == Status.notFound)
                sent = true;
            else if (status != Status.unavailable)
                fail(Error(status, "asynchronous cancellation submission failed"));
        }

        private void waitForCompletions(uint millis) nothrow @nogc
        {
            foreach (_; 0 .. runtime.options.completionsPerTick)
            {
                auto event = pollCompletion(completions, millis);
                if (!event.ok)
                {
                    fail(event.error);
                    return;
                }
                if (!event.value.received)
                    return;
                processCompletion(event.value);
                millis = 0;
            }
        }

        private void processCompletion(KernelEvent event) nothrow @nogc
        {
            if (event.token == 0)
            {
                if (cancellationAcks == 0)
                    fail(Error(Status.ioError, "unexpected cancellation acknowledgement"));
                else
                    --cancellationAcks;
                return;
            }

            if (event.token == listenToken)
            {
                acceptPending = false;
                acceptCancelSent = false;
                if (event.status == Status.ok)
                    admit(event.accepted);
                else if (event.status != Status.unavailable && atomicLoad(runtime.state) == State.running)
                    fail(Error(event.status, "asynchronous accept failed"));
                return;
            }

            version (linux)
            {
                if (event.token == nativeWatchToken)
                {
                    completeNativeWatch(event.status);
                    return;
                }
            }

            const id = OperationId.fromToken(event.token);
            if (id.slot >= workItems.length)
                return;
            auto work = &workItems[id.slot];
            if (work.id != id || !work.pending)
                return;
            work.pending = false;
            observeCancellation(id);
            if (work.cancellation != Status.ok || event.status != Status.unavailable)
                completeIo(id, event.status, event.bytes);
        }

        private bool completionsPending() const pure nothrow @nogc
        {
            version (linux)
                if (nativePending)
                    return true;
            return liveOperations != 0 || acceptPending || cancellationAcks != 0;
        }
    }

    private void drain() nothrow @nogc
    {
        timers.clear();
        foreach (slot, ref connection; connections)
        {
            if (connection.generation != 0)
            {
                connection.draining = true;
                closeIdle(cast(uint) slot);
            }
        }

        version (ReactorReadinessOnly)
        {
            advanceOperations();
        }
        else
        {
            if (!completions.valid)
            {
                advanceOperations();
                return;
            }

            while (completionsPending())
            {
                advanceOperations();
                if (acceptPending && !acceptCancelSent)
                    cancelInFlight(listenToken, acceptCancelSent);
                version (linux)
                    if (nativePending && !nativeCancelSent)
                        cancelInFlight(nativeWatchToken, nativeCancelSent);
                if (completionsPending())
                    waitForCompletions(waitBudgetMillis);
            }
        }
    }
}
