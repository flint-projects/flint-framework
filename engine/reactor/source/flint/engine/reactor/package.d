module flint.engine.reactor;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.bitop : bsf;
import core.lifetime : move;
import core.memory : GC;
import core.thread.fiber : Fiber;
import core.thread.osthread : Thread;
import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : replaceWaitHook;
import flint.engine.reactor.internal.operations : OperationId, OperationTable;
import flint.engine.reactor.internal.queues : Mailbox, Message, Timers;
import flint.engine.reactor.sys.fibers : createFiber, PoolFiber, releaseFiber, resetFiber, resumeFiber, yieldFiber;
import flint.engine.reactor.sys.locals : cellStamp, loadCell, localStorable, localWords, storeCell;
import flint.engine.reactor.sys.offload : OffloadPool;
import flint.engine.reactor.sys.workers : availableCpus, joinWorker, pinWorker, startWorker, workerUsage, yieldWorker;

public import flint.engine.reactor.types : AcceptDelegate, AcceptFn, Backend, Completion, CompletionDelegate,
    CompletionFn, ConnectionId, IoId, ListenOptions, NativeInterest, NativeReadyFn, OffloadInterrupt, OffloadWork,
    ReadDelegate, ReactorOptions, ReadFn, TaskContext, TaskDelegate, TaskFn, TaskWaker, TimerId, WorkerStats;

@safe:

// Native descriptor watches nest a poller in the owner's: epoll on Linux, kqueue on macOS. Windows polls the watched
// sockets with WSAPoll on each loop pass (ADR-026).
version (linux)
    version = ReactorNativeWatches;
else version (OSX)
    version = ReactorNativeWatches;
else version (Windows)
    version = ReactorNativeWatches;

version (Posix)
{
    import flint.engine.reactor.sys.sockets : Socket, acceptConnection, bindListener, closeSocket,
        receive, sendImmediately, socketPort, transmit;
    import flint.engine.reactor.sys.readiness : Interest, Readiness, ReadyEvent, destroyReadiness,
        directions, openReadiness, poll, setInterest;
}
version (linux)
{
    import flint.engine.reactor.sys.completion : CompletionPort, KernelEvent, cancelKernel, closeCompletionPort,
        openCompletionPort, pollCompletion, submitAccept, submitRead, submitReadable, submitWrite;
    import flint.engine.reactor.sys.nativewatch : NativeWatches;
    import flint.engine.reactor.sys.scratch : Scratch;
}
else version (OSX)
{
    version = ReactorReadinessOnly;
    import flint.engine.reactor.sys.nativewatch : NativeWatches;
}
else version (Windows)
{
    import flint.engine.reactor.sys.windows : CompletionPort, KernelEvent, Socket, bindListener,
        cancelKernel, closeCompletionPort,
        closeListening, closeSocket, openCompletionPort, pollCompletion, sendImmediately,
        socketPort, submitAccept, submitRead, submitWrite;
    import flint.engine.reactor.sys.nativewatch : NativeWatches;
}

private enum State : ubyte
{
    configured,
    starting,
    running,
    stopping,
    stopped
}

private shared ulong lastIdentity;
private Error waitOnOwner(Deadline deadline) nothrow @nogc
{
    auto owner = Reactor.current();
    if (!owner.currentTask().ok())
        return Error(Status.conflict, "cooperative wait requires an active reactor fiber");
    return owner.yieldUntil(deadline);
}

// The loop a worker thread runs and its index: the root that FiberLocal and Reactor.current resolve from.
private Runtime* currentRuntime;
private uint currentWorkerIndex = uint.max;
private enum noSlot = uint.max;
private enum ioWordBits = ulong.sizeof * 8;
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
        && options.fiberGuardBytes <= 1_048_576
        && options.fiberLocalWords <= maxFiberLocalWords && options.offloadThreads <= 256
        && (options.offloadThreads == 0 || (options.offloadQueueCapacity > 0
                && options.offloadQueueCapacity <= ushort.max))
        && cast(ulong) workers * options.maxPendingIoPerCore * options.ioBufferBytes <= 512UL * 1024 * 1024;
}

/// Words that all `FiberLocal` declarations of a process may claim together, one per local plus its value.
enum uint maxFiberLocalWords = 128;

private shared uint claimedLocalWords;
// FiberLocal values read or written off any task fiber: on a loop callback, an offload thread or a thread
// outside the reactor. Thread-local by design; the stamp is constant because the thread never retires.
private void*[maxFiberLocalWords] threadLocalWords;
private enum size_t threadStamp = 1;

/// A value each task fiber sees separately, the fiber counterpart of a Java `ThreadLocal`. A task starts
/// with `T.init`; what it sets is gone once it ends, even though its fiber slot is reused. Off a task fiber
/// the value is thread-local. Declare it as `shared FiberLocal!T`: only its storage key is shared.
///
/// `T` is a class or interface reference or plain data without copy or destruction hooks, at most
/// `maxFiberLocalWords - 1` words. A set value may not borrow stack or request storage.
struct FiberLocal(T) if (localStorable!T && localWords!T < maxFiberLocalWords)
{
    /// One past the first word claimed for this local, or zero before the first `set`.
    private uint key;

    /// The calling task's value, or `T.init` when it set none.
    T get() shared nothrow @nogc
    {
        const offset = atomicLoad(key);
        if (offset == 0)
            return T.init;
        size_t stamp;
        auto cell = localCell(offset, localWords!T, stamp);
        if (cell.length == 0 || cellStamp(cell) != stamp)
            return T.init;
        return loadCell!T(cell);
    }

    /// Replace the calling task's value. Fails with `resourceExhausted` when the process claimed
    /// `maxFiberLocalWords` or the task fiber's `ReactorOptions.fiberLocalWords` is too small.
    Error set(T value) shared nothrow @nogc
    {
        const offset = claimLocal(key, localWords!T);
        if (offset == 0)
            return Error(Status.resourceExhausted, "FiberLocal words exhausted for this process");
        size_t stamp;
        auto cell = localCell(offset, localWords!T, stamp, true);
        if (cell.length == 0)
            return Error(Status.resourceExhausted, "raise ReactorOptions.fiberLocalWords for this FiberLocal");
        storeCell!T(cell, stamp, value);
        return Error.init;
    }

    /// Forget the calling task's value, so `get` returns `T.init` and its references are released.
    void remove() shared nothrow @nogc
    {
        const offset = atomicLoad(key);
        if (offset == 0)
            return;
        size_t stamp;
        auto cell = localCell(offset, localWords!T, stamp);
        cell[] = null;
    }
}

/// The offset of a local's cell, claiming `words` plus a stamp on first use. Zero when the process ran out.
private uint claimLocal(ref shared uint key, size_t words) nothrow @nogc
{
    const current = atomicLoad(key);
    if (current != 0)
        return current;
    for (;;)
    {
        const used = atomicLoad(claimedLocalWords);
        if (used + 1 + words > maxFiberLocalWords)
            return 0;
        if (!cas(&claimedLocalWords, used, cast(uint)(used + 1 + words)))
            continue;
        // A racing first `set` may have published first; its claim wins and this one stays unused.
        if (cas(&key, 0U, used + 1))
            return used + 1;
        return atomicLoad(key);
    }
}

/// The calling context's cell for `offset`, with the stamp of its current owner. Empty when the active task
/// fiber's storage is too small for this cell.
private void*[] localCell(uint offset, size_t words, out size_t stamp, bool writing = false) nothrow @nogc
{
    const first = offset - 1;
    const end = first + 1 + words;
    auto runtime = currentRuntime;
    if (runtime !is null)
    {
        auto worker = &runtime.workers[currentWorkerIndex];
        if (worker.activeFiber != noSlot)
        {
            const stride = runtime.options.fiberLocalWords;
            if (end > stride)
                return null;
            auto task = &worker.fibers[worker.activeFiber];
            if (writing)
                task.localsDirty = true;
            stamp = cast(size_t) task.generation;
            const base = cast(size_t) worker.activeFiber * stride;
            return worker.localWords[base + first .. base + end];
        }
    }
    stamp = threadStamp;
    return threadLocalWords[first .. end];
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
        bool ready;
        scope (exit)
            if (!ready)
                runtime.release();
        foreach (index, ref worker; runtime.workers)
        {
            const status = worker.initialize(runtime, cast(uint) index, cpus[index]);
            if (status != Status.ok)
                return Result!Reactor(Reactor.init, Error(status, "could not reserve reactor I/O scratch"));
        }
        const result = runtime.prepareBackend(options.backend);
        if (result.code != Status.ok)
            return Result!Reactor(Reactor.init, result);
        if (options.offloadThreads != 0)
        {
            runtime.offload = new OffloadPool(options.offloadThreads, options.offloadQueueCapacity, count);
            if (runtime.offload.open() != Status.ok)
                return Result!Reactor(Reactor.init, Error(Status.ioError, "could not open offload signals"));
        }

        ready = true;
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
        return queueOwner(ownerCore, task, move(context), false);
    }

    /// Dispatch a task on its owner even if the copied context is cancelled before the task enters.
    /// The delegate checks the context before doing application work and retires its owned state.
    Error postWithCleanup(uint ownerCore, TaskDelegate task, TaskContext context) nothrow @nogc
    {
        return queueOwner(ownerCore, task, move(context), true);
    }

    private Error queueOwner(uint ownerCore, TaskDelegate task, TaskContext context, bool cleanup) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime || ownerCore != currentWorkerIndex || task is null)
            return Error(Status.invalidArgument, "bound task requires its owner and callback");
        if (atomicLoad(runtime.state) != State.running)
            return Error(Status.unavailable, "reactor is not running");
        return queueBound(ownerCore, task, move(context), cleanup);
    }

    /// Before run, the reactor owner may transfer an initialized task to one worker's startup queue.
    Error postStartup(uint core, TaskDelegate task, TaskContext context = TaskContext.init) nothrow @nogc
    {
        if (!owner || runtime is null || task is null || core >= runtime.workers.length)
            return Error(Status.invalidArgument, "invalid startup task or owner");
        if (atomicLoad(runtime.state) != State.configured)
            return Error(Status.conflict, "startup tasks require a configured reactor");
        return queueBound(core, task, move(context));
    }

    private Error queueBound(uint ownerCore, TaskDelegate task, TaskContext context, bool cleanup = false) nothrow @nogc
    {
        auto message = Message(null, ConnectionId.init, move(context), task, cleanup);
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

    /// Yield only from a task fiber. The same owner resumes it on deadline, `wake`, cancellation, or shutdown.
    Error yieldUntil(Deadline deadline) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Error(Status.notFound, "no active fiber");
        return runtime.workers[currentWorkerIndex].yieldTask(deadline);
    }

    /// Yield like `yieldUntil`, and also resume as soon as the owner loop observes `watched` cancelled or
    /// expired. Use it when the wait belongs to a context other than the task's own.
    Error yieldUntil(Deadline deadline, ref scope const Context watched) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Error(Status.notFound, "no active fiber");
        const early = watched.check();
        if (early.code != Status.ok)
            return early;
        if (watched.deadline().monotonicNanoseconds < deadline.monotonicNanoseconds)
            deadline = watched.deadline();
        auto worker = &runtime.workers[currentWorkerIndex];
        if (worker.activeFiber == noSlot)
            return Error(Status.notFound, "no active fiber");
        worker.fibers[worker.activeFiber].watched = watched;
        worker.fibers[worker.activeFiber].watching = true;
        const outcome = worker.yieldTask(deadline);
        // The same worker owns the slot after resumption; release the retained cancellation identity.
        worker.fibers[worker.activeFiber].watched = Context.init;
        worker.fibers[worker.activeFiber].watching = false;
        return outcome.code == Status.ok ? watched.check() : outcome;
    }

    /// A handle that resumes the active fiber from a later callback on this loop.
    Result!TaskWaker currentWaker() const nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Result!TaskWaker(TaskWaker.init, Error(Status.notFound, "no active fiber"));
        return runtime.workers[currentWorkerIndex].activeWaker();
    }

    /// Mark a suspended fiber due, so the owner's next pass resumes it before blocking. Waking a running
    /// or already due fiber is a no-op, so waiters re-check their condition before they yield. A handle
    /// whose task ended is rejected with `notFound`. Callable only on the owner loop.
    Error wake(TaskWaker waker) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime || waker.ownerCore != currentWorkerIndex)
            return Error(Status.invalidArgument, "fiber wake requires its owner loop");
        return runtime.workers[currentWorkerIndex].wakeTask(waker);
    }

    /// Run blocking `work` on an offload thread and suspend the calling task fiber until it returns, so
    /// other fibers keep running. `work` may borrow this fiber's frame. When the admission queue is full the
    /// fiber waits for room. Cancellation of the task withdraws work that has not started; work that has
    /// started gets `interrupt` once and the fiber still waits for it to return before reporting
    /// `cancelled`, as it does when the reactor stops. Requires `ReactorOptions.offloadThreads`.
    Error offload(scope OffloadWork work, scope OffloadInterrupt interrupt = null) nothrow @nogc
    {
        if (runtime is null || currentRuntime !is runtime)
            return Error(Status.notFound, "no active fiber");
        if (work is null)
            return Error(Status.invalidArgument, "offload requires work");
        if (runtime.offload is null)
            return Error(Status.unavailable, "offload is disabled; set ReactorOptions.offloadThreads");
        auto worker = &runtime.workers[currentWorkerIndex];
        if (worker.activeFiber == noSlot)
            return Error(Status.conflict, "offload requires an active reactor fiber");
        if (!worker.offloadWatchTried)
        {
            worker.offloadWatchTried = true;
            version (ReactorNativeWatches)
            {
                const signal = runtime.offload.signal(currentWorkerIndex);
                // Without a watch the fiber polls for completion every millisecond instead.
                if (signal >= 0)
                    worker.offloadWatched = worker.watchNative(signal, NativeInterest.read,
                            &worker.offloadReady).code == Status.ok;
            }
        }
        const waker = worker.activeWaker().value;
        for (;;)
        {
            const ticket = runtime.offload.submit(work, waker);
            if (ticket != 0)
                return worker.awaitOffload(ticket, interrupt);
            const waited = worker.yieldTask(Deadline.afterMillis(1));
            if (waited.code != Status.ok)
                return waited;
        }
    }

    /// Create or update a Linux or macOS descriptor watch, or a Windows socket watch, on the current worker. The
    /// caller keeps ownership of fd and
    /// removes the watch before releasing the descriptor or callback. Error readiness is always delivered.
    Error watchNative(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
    {
        version (ReactorNativeWatches)
        {
            enum valid = NativeInterest.read | NativeInterest.write | NativeInterest.error;
            if (fd < 0 || callback is null || interest == NativeInterest.none || (interest & ~valid) != 0)
                return Error(Status.invalidArgument, "invalid native descriptor watch");
            if (runtime is null || currentRuntime !is runtime || atomicLoad(runtime.state) != State.running)
                return Error(Status.conflict, "native watch requires a running owner loop");
            return runtime.workers[currentWorkerIndex].watchNative(fd, interest, callback);
        }
        else
            return Error(Status.unsupported, "native descriptor watches require Linux, macOS or Windows");
    }

    /// Drop a native watch from its owner loop. Remains available during cancellation and shutdown.
    Error unwatchNative(int fd) nothrow @nogc
    {
        version (ReactorNativeWatches)
        {
            if (fd < 0)
                return Error(Status.invalidArgument, "invalid native descriptor");
            if (runtime is null || currentRuntime !is runtime)
                return Error(Status.conflict, "native watch removal requires its owner loop");
            return Error(runtime.workers[currentWorkerIndex].nativeWatches.remove(fd));
        }
        else
            return Error(Status.unsupported, "native descriptor watches require Linux, macOS or Windows");
    }

    /// Stop admission and close the listener, from any thread, while admitted connections keep running.
    /// Each owner retires its accept first: io_uring holds the listener until its pending accept completes,
    /// so the last owner closes it only after every cancelled accept has (ADR-028 sections 7.5 and 10).
    void stopAccepting() nothrow @nogc
    {
        if (runtime !is null)
            atomicStore(runtime.acceptStopping, true);
    }

    /// Whether every owner retired its accept and the listener is closed, so new connections are refused.
    bool acceptStopped() const nothrow @nogc
    {
        return runtime !is null && atomicLoad(runtime.acceptRetired) == runtime.workers.length;
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
    /// Threads for `Reactor.offload`, or null when disabled.
    OffloadPool offload;
    /// Set by `stopAccepting`; each owner then retires its accept and counts itself in `acceptRetired`.
    shared bool acceptStopping;
    shared uint acceptRetired;

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
            // Every fiber waiting on offloaded work stayed until it returned, so no job remains.
            if (offload !is null)
                offload.stop();
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
        if (offload !is null)
            offload.start();

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
        if (offload !is null)
            offload.closeSignals();
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
    PoolFiber fiber;
    TaskFn task;
    TaskDelegate boundTask;
    TaskContext context;
    Deadline wake;
    /// Lifetime of the occupying task for `TaskWaker`, or zero while free.
    ulong generation;
    /// A caller context that also ends the current yield, valid while `watching`.
    Context watched;
    bool watching;
    /// Waiting for offloaded work after cancellation: only a wake or its deadline resumes it.
    bool shielded;
    /// The task wrote FiberLocal storage, which is cleared when it ends.
    bool localsDirty;
    uint next;
    /// Position in the worker's suspended list, or noSlot while free or running.
    uint suspendedAt = noSlot;
    bool invokeIfCancelled;

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
    ulong[] activeIo;
    version (linux)
        Scratch buffers;
    else
        ubyte[] buffers;
    uint liveOperations;
    Mailbox mailbox;
    Timers timers;
    FiberTask[] fibers;
    /// Dense list of fibers that yielded and await a deadline, cancellation or shutdown.
    uint[] suspended;
    uint suspendedCount;
    uint freeFiber = noSlot;
    uint activeFiber = noSlot;
    uint activeFiberCount;
    /// Monotonic time before which this worker leaves pending connections in the backlog after
    /// descriptor exhaustion, or zero while accepting.
    long acceptResumeAt;
    /// This owner no longer touches the listener: `stopAccepting` retired its accept.
    bool acceptClosed;
    /// Earliest wake of a suspended fiber, long.min when one may be due, or long.max when none waits.
    long nextWake = long.max;
    /// Last task lifetime issued on this worker.
    ulong taskGeneration;
    /// FiberLocal cells, `fiberLocalWords` per fiber slot. GC-scanned, so stored references stay alive.
    void*[] localWords;
    /// Whether this worker tried, and managed, to watch its offload signal.
    bool offloadWatchTried;
    bool offloadWatched;

    version (Posix) Readiness readiness;

    version (ReactorNativeWatches) NativeWatches nativeWatches;
    version (linux)
    {
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

    Status initialize(Runtime* runtime, uint index, uint cpu)
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
        activeIo = new ulong[(options.maxPendingIoPerCore + ioWordBits - 1) / ioWordBits];
        mailbox.initialize(options.mailboxCapacity);
        timers.initialize(options.maxTimersPerCore);
        const bytes = cast(size_t) options.ioBufferBytes * options.maxPendingIoPerCore;
        version (linux)
        {
            nativeWatches.reserve(options.maxNativeWatchesPerCore);
            return buffers.reserve(bytes);
        }
        else
        {
            version (ReactorNativeWatches)
                nativeWatches.reserve(options.maxNativeWatchesPerCore);
            buffers = new ubyte[bytes];
            return Status.ok;
        }
    }

    void preallocateFibers()
    {
        fibers = new FiberTask[runtime.options.fiberPoolSize];
        foreach (slot, ref task; fibers)
        {
            task.fiber = createFiber(&enterTask, runtime.options.fiberStackBytes, runtime.options.fiberGuardBytes);
            task.next = cast(uint)(slot + 1);
        }
        fibers[$ - 1].next = noSlot;
        freeFiber = 0;
        suspended = new uint[fibers.length];
        localWords = new void*[fibers.length * runtime.options.fiberLocalWords];
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

    Result!TaskWaker activeWaker() const nothrow @nogc
    {
        if (activeFiber == noSlot)
            return Result!TaskWaker(TaskWaker.init, Error(Status.notFound, "no active fiber"));
        return Result!TaskWaker(TaskWaker(index, activeFiber, fibers[activeFiber].generation));
    }

    Error wakeTask(TaskWaker waker) nothrow @nogc
    {
        if (waker.generation == 0 || waker.slot >= fibers.length || fibers[waker.slot].generation != waker.generation)
            return Error(Status.notFound, "fiber task already ended");
        auto task = &fibers[waker.slot];
        // A running fiber re-checks its condition before yielding; a due one is already resumable.
        if (waker.slot == activeFiber || task.suspendedAt == noSlot)
            return Error.init;
        task.wake = Deadline(long.min);
        nextWake = long.min;
        return Error.init;
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

    /// Suspend the active fiber until offloaded `ticket` returns. See `Reactor.offload`.
    Error awaitOffload(uint ticket, scope OffloadInterrupt interrupt) nothrow @nogc
    {
        auto pool = runtime.offload;
        auto task = &fibers[activeFiber];
        Error cancelled;
        while (!pool.finished(ticket))
        {
            if (atomicLoad(runtime.state) != State.running)
            {
                if (pool.abandon(ticket))
                    return Error(Status.cancelled, "reactor is stopping");
                if (cancelled.code == Status.ok && interrupt !is null)
                    interrupt();
                if (cancelled.code == Status.ok)
                    cancelled = Error(Status.cancelled, "reactor is stopping");
                // Shutdown resumes each fiber once more; the work may borrow this frame, so the owner
                // blocks here until the call returns instead of letting the frame go.
                pool.waitFinished(ticket);
                break;
            }
            if (cancelled.code == Status.ok)
            {
                const status = task.context.cancellation.check();
                if (status.code != Status.ok)
                {
                    if (pool.abandon(ticket))
                        return status;
                    cancelled = status;
                    if (interrupt !is null)
                        interrupt();
                }
            }
            task.shielded = cancelled.code != Status.ok;
            task.wake = Deadline.afterMillis(offloadWatched ? 1_000 : 1);
            yieldFiber();
            task.shielded = false;
        }
        const succeeded = pool.retire(ticket);
        if (cancelled.code != Status.ok)
            return cancelled;
        return succeeded ? Error.init : Error(Status.ioError, "offloaded work ended with a throwable");
    }

    /// On the owner loop, when the offload signal is readable: resume every fiber whose work returned.
    void offloadReady(int, NativeInterest) nothrow @nogc
    {
        auto pool = runtime.offload;
        pool.drain(index);
        foreach (slot; 0 .. pool.capacity)
        {
            const waker = pool.finishedWaker(index, slot);
            if (waker.valid)
                cast(void) wakeTask(waker);
        }
    }

    void executeTask() nothrow @nogc
    {
        auto task = &fibers[activeFiber];
        if (!task.invokeIfCancelled && task.context.cancellation.check().code != Status.ok)
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
        task.invokeIfCancelled = message.invokeIfCancelled;
        task.context = move(message.context);
        task.generation = ++taskGeneration;
        ++activeFiberCount;
        resumeTask(slot);
    }

    private void resumeTask(uint slot) nothrow @nogc
    {
        auto task = &fibers[slot];
        activeFiber = slot;
        const failure = resumeFiber(task.fiber);
        activeFiber = noSlot;
        if (task.fiber.state != Fiber.State.TERM)
        {
            noteWake(task.wake);
            if (task.suspendedAt == noSlot)
            {
                task.suspendedAt = suspendedCount;
                suspended[suspendedCount++] = slot;
            }
        }
        else
        {
            if (task.suspendedAt != noSlot)
            {
                // Swap-remove keeps the list dense; the moved entry has not been visited yet in this pass.
                const moved = suspended[--suspendedCount];
                suspended[task.suspendedAt] = moved;
                fibers[moved].suspendedAt = task.suspendedAt;
                task.suspendedAt = noSlot;
            }
            resetFiber(task.fiber);
            if (task.localsDirty)
            {
                // The generation stamp already hides these cells; clearing them releases their references.
                const stride = runtime.options.fiberLocalWords;
                localWords[cast(size_t) slot * stride .. (cast(size_t) slot + 1) * stride] = null;
                task.localsDirty = false;
            }
            task.task = null;
            task.boundTask = null;
            task.context = TaskContext.init;
            task.generation = 0;
            task.next = freeFiber;
            freeFiber = slot;
            --activeFiberCount;
        }
        if (failure !is null)
            fail(Error(Status.ioError, "reactor task fiber terminated with an error"));
    }

    private void resumeReadyTasks(bool stopping = false) nothrow @nogc
    {
        nextWake = long.max;
        if (suspendedCount == 0)
            return;
        const now = Deadline.afterMillis(0);
        uint used;
        for (uint position = 0; position < suspendedCount;)
        {
            if (!stopping && used == runtime.options.completionsPerTick)
            {
                // Unvisited fibers may already be due; poll again without blocking.
                nextWake = long.min;
                break;
            }
            const slot = suspended[position];
            auto task = &fibers[slot];
            if (stopping || task.wake.monotonicNanoseconds <= now.monotonicNanoseconds
                    || (!task.shielded && task.context.cancellation.statusAt(now.monotonicNanoseconds) != Status.ok)
                    || (task.watching && task.watched.statusAt(now.monotonicNanoseconds) != Status.ok))
            {
                resumeTask(slot);
                ++used;
                // A terminated fiber left the list and another unvisited entry took its position.
                if (position < suspendedCount && suspended[position] != slot)
                    continue;
            }
            else
                noteWake(task.wake);
            ++position;
        }
    }

    private void noteWake(Deadline wake) nothrow @nogc
    {
        if (wake.monotonicNanoseconds < nextWake)
            nextWake = wake.monotonicNanoseconds;
    }

    /// Bound the backend wait by the earliest timer, suspended fiber deadline and runnable mailbox work.
    private uint loopWaitMillis() nothrow @nogc
    {
        if (nextWake == long.min || (freeFiber != noSlot && mailbox.pending()))
            return 0;
        if (nextWake == long.max && timers.empty)
            return waitBudgetMillis;
        const now = Deadline.afterMillis(0);
        const wait = timers.waitMillis(now, waitBudgetMillis);
        if (wait == 0 || nextWake <= now.monotonicNanoseconds)
            return 0;
        if (nextWake == long.max)
            return wait;
        const remaining = cast(ulong) nextWake - cast(ulong) now.monotonicNanoseconds;
        const millis = remaining / 1_000_000 + (remaining % 1_000_000 != 0);
        return millis < wait ? cast(uint) millis : wait;
    }

    void execute() nothrow @nogc
    {
        currentRuntime = runtime;
        currentWorkerIndex = index;
        const previousWait = replaceWaitHook(&waitOnOwner);
        scope (exit)
        {
            replaceWaitHook(previousWait);
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
            if (!acceptClosed && atomicLoad(runtime.acceptStopping))
                retireAccept();
            advanceOperations();
            const wait = loopWaitMillis();
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
                    version (Windows)
                    {
                        // Watched sockets post no completion packet: poll them each pass, and wait at most 1 ms while
                        // any is watched (ADR-026).
                        if (nativeWatches.active)
                        {
                            notifyNativeWatches();
                            waitForCompletions(wait < 1 ? wait : 1);
                        }
                        else
                            waitForCompletions(wait);
                    }
                    else
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
        version (ReactorNativeWatches)
            nativeWatches.release();
        version (linux)
            buffers.release();
    }

    version (ReactorNativeWatches)
    {
        Error watchNative(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
        {
            if (!nativeWatches.enabled)
                return Error(Status.resourceExhausted, "native descriptor watches are disabled");
            version (Windows)
                return Error(nativeWatches.update(fd, interest, callback));
            else
                return watchNested(fd, interest, callback);
        }

        version (Posix) private Error watchNested(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
        {
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

        private void notifyNativeWatches() nothrow @nogc
        {
            const outcome = nativeWatches.notify(runtime.options.completionsPerTick);
            if (outcome.code != Status.ok)
                fail(outcome);
        }
    }

    version (linux)
    {
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

    /// Stop this owner's accepting. A completion owner waits for its cancelled accept to complete before it
    /// counts itself; the last owner to retire closes the listener so the kernel refuses new connections.
    private void retireAccept() nothrow @nogc
    {
        version (ReactorReadinessOnly)
        {
        }
        else
        {
            if (acceptPending)
            {
                if (!acceptCancelSent)
                    cancelInFlight(listenToken, acceptCancelSent);
                return;
            }
        }
        version (Posix)
        {
            // A paused owner already dropped its readiness interest.
            if (readiness.valid && runtime.listener.valid && acceptResumeAt == 0
                    && setInterest(readiness, runtime.listener, listenToken, Interest.read, Interest.none) != Status.ok)
                fail(Error(Status.ioError, "could not retire listener readiness"));
        }
        acceptResumeAt = 0;
        acceptClosed = true;
        if (atomicOp!"+="(runtime.acceptRetired, 1U) != runtime.workers.length)
            return;
        // Every other owner has stopped reading the listener. On Windows the listener also holds the process's
        // Winsock reference, which admitted connections still need, so release gives that up later.
        version (Windows)
            closeListening(runtime.listener);
        else
            closeSocket(runtime.listener);
    }

    /// Leave connections in the backlog for one loop budget instead of stopping on transient exhaustion.
    private void pauseAccept() nothrow @nogc
    {
        if (acceptClosed)
            return;
        acceptResumeAt = Deadline.afterMillis(waitBudgetMillis).monotonicNanoseconds;
        version (Posix)
        {
            // A level-triggered listener would otherwise report readiness on every poll.
            if (readiness.valid && setInterest(readiness, runtime.listener, listenToken,
                    Interest.read, Interest.none) != Status.ok)
                fail(Error(Status.ioError, "could not pause listener readiness"));
        }
    }

    /// Whether the accept backoff has elapsed. Rearms readiness listeners when it has.
    private bool acceptResumed() nothrow @nogc
    {
        if (acceptClosed)
            return false;
        if (acceptResumeAt == 0)
            return true;
        if (Deadline.afterMillis(0).monotonicNanoseconds < acceptResumeAt)
            return false;
        acceptResumeAt = 0;
        version (Posix)
        {
            if (readiness.valid && setInterest(readiness, runtime.listener, listenToken,
                    Interest.none, Interest.read) != Status.ok)
                fail(Error(Status.ioError, "could not resume listener readiness"));
        }
        return true;
    }

    private void admit(Socket incoming) nothrow @nogc
    {
        if (nextFree == noSlot || atomicLoad(runtime.state) != State.running || atomicLoad(runtime.acceptStopping))
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
        // Best effort: a refused option changes latency only, never correctness.
        sendImmediately(incoming);
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
        activeIo[operation.slot / ioWordBits] |= 1UL << (operation.slot % ioWordBits);
        ++liveOperations;
        return Result!IoId(IoId(id, operation.slot, cast(uint) operation.generation));
    }

    Status cancelIo(IoId operation) nothrow @nogc
    {
        if (operation.generation == 0 || operation.slot >= workItems.length)
            return Status.notFound;
        auto work = &workItems[operation.slot];
        if (cast(uint) work.id.generation != operation.generation || work.connection != operation.connection)
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
        version (linux)
            return buffers.slice(offset, offset + length);
        else
            return buffers[offset .. offset + length];
    }

    private void advanceOperations() nothrow @nogc
    {
        if (liveOperations == 0)
            return;
        // One clock sample per pass: every active operation's deadline is judged against it.
        const now = Deadline.afterMillis(0).monotonicNanoseconds;
        foreach (index, ref word; activeIo)
        {
            ulong unvisited = ulong.max;
            // Read the live word again after each callback, which can queue later slots.
            while (const available = word & unvisited)
            {
                const bit = bsf(available);
                unvisited = (ulong.max << bit) << 1;
                advanceOperation(workItems[index * ioWordBits + bit].id, now);
            }
        }
    }

    private void observeCancellation(OperationId id, long now) nothrow @nogc
    {
        auto work = &workItems[id.slot];
        if (work.cancellation != Status.ok)
            return;
        if (connections[work.connection.slot].draining)
        {
            requestCancel(id, Status.cancelled);
            return;
        }
        const status = work.context.statusAt(now);
        if (status == Status.timedOut || status == Status.cancelled)
            requestCancel(id, status);
    }

    private void advanceOperation(OperationId id, long now) nothrow @nogc
    {
        observeCancellation(id, now);
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
        bool starting;
        if (!work.started)
        {
            const status = operations.start(id);
            assert(status == Status.ok);
            work.started = true;
            starting = true;
        }
        version (ReactorReadinessOnly)
        {
            if (starting && writeNow(id))
                return;
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
                {
                    if (starting && writeNow(id))
                        return;
                    refreshInterest(work.connection.slot);
                }
            }
        }
    }

    private void deliver(OperationId id, Status status, size_t bytes) nothrow @nogc
    {
        auto work = &workItems[id.slot];
        assert(work.id == id && !work.pending);
        const done = operations.finish(id, status, bytes, work.callbacks.reading);
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
        activeIo[id.slot / ioWordBits] &= ~(1UL << (id.slot % ioWordBits));
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

        /// A write that has just started is sent at once, as Go's netpoller does: a socket is nearly always
        /// writable, so waiting for EPOLLOUT costs a whole loop pass and two epoll_ctl calls per response.
        /// Returns true when the operation is finished (delivered); false when it must wait for readiness, after
        /// EAGAIN or a partial write. Reads still wait for readiness: the peer has usually not sent yet.
        private bool writeNow(OperationId id) nothrow @nogc
        {
            auto work = &workItems[id.slot];
            if (work.callbacks.reading)
                return false;
            auto socket = connections[work.connection.slot].socket;
            const result = transmit(socket, operationBuffer(id.slot)[work.offset .. work.length]);
            if (result.error.code == Status.unavailable)
                return false;
            completeIo(id, result.error.code, result.value);
            return workItems[id.slot].id != id;
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
            if (!acceptClosed && runtime.listener.valid)
                acceptResumed();
            ReadyEvent[64] events;
            const budget = runtime.options.completionsPerTick;
            const count = budget < events.length ? budget : events.length;
            const ready = poll(readiness, events[0 .. count], millis);
            if (!ready.ok)
            {
                fail(ready.error);
                return;
            }
            const now = Deadline.afterMillis(0).monotonicNanoseconds;
            foreach (event; events[0 .. ready.value])
            {
                if (atomicLoad(runtime.state) != State.running)
                    return;
                version (ReactorNativeWatches)
                {
                    if (event.token == nativeWatchToken)
                    {
                        notifyNativeWatches();
                        continue;
                    }
                }
                if (event.token == listenToken)
                {
                    acceptReady();
                    continue;
                }
                const id = ConnectionId(index, cast(ushort) event.token, event.token >> 16);
                if (!validConnection(id))
                    continue;
                auto connection = &connections[id.slot];
                if ((event.directions & Interest.read) && connection.read.generation != 0)
                    performReadyIo(connection.read, now);
                if (validConnection(id) && (event.directions & Interest.write) && connection.write.generation != 0)
                    performReadyIo(connection.write, now);
            }
        }

        private void acceptReady() nothrow @nogc
        {
            if (acceptClosed)
                return;
            auto incoming = acceptConnection(runtime.listener);
            if (incoming.ok)
                admit(incoming.value);
            else if (incoming.error.code == Status.resourceExhausted)
                pauseAccept();
            else if (incoming.error.code != Status.unavailable)
                fail(incoming.error);
        }

        private void performReadyIo(OperationId id, long now) nothrow @nogc
        {
            // The previous callback in this poll batch may have cancelled or queued an operation.
            advanceOperation(id, now);
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
            if (acceptPending || acceptClosed || atomicLoad(runtime.acceptStopping)
                    || !runtime.listener.valid || !acceptResumed())
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
                else if (event.status == Status.resourceExhausted)
                    pauseAccept();
                else if (event.status != Status.unavailable
                        && atomicLoad(runtime.state) == State.running && !atomicLoad(runtime.acceptStopping))
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
            observeCancellation(id, Deadline.afterMillis(0).monotonicNanoseconds);
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

version (unittest)
{
    /// Test probe: whether the owner's accepted socket for `id` has TCP_NODELAY in effect.
    package(flint.engine.reactor) bool connectionSendsImmediately(ConnectionId id) nothrow @nogc
    {
        version (Posix)
            import flint.engine.reactor.sys.sockets : sendsImmediately;
        else version (Windows)
            import flint.engine.reactor.sys.windows : sendsImmediately;

        if (currentRuntime is null || id.ownerCore != currentWorkerIndex)
            return false;
        auto worker = &currentRuntime.workers[currentWorkerIndex];
        return worker.validConnection(id) && sendsImmediately(worker.connections[id.slot].socket);
    }
}
