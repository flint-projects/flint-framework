module flint.reactor.types;

import core.lifetime : move;
import flint.arena : Status;
import flint.conc : Context;

@safe:

/// Native event delivery mode. Automatic selection uses the supported platform backend.
enum Backend
{
    automatic,
    ioUring,
    kqueue,
    iocp,
    epoll
}

/// Capacities reserved per worker before it accepts work.
struct ReactorOptions
{
    /// Automatic selection probes io_uring on Linux before falling back to epoll.
    Backend backend = Backend.automatic;
    /// Zero selects the logical CPUs available to this process.
    uint cores = 0;
    /// Maximum work items processed per category before rotating to the next category.
    uint completionsPerTick = 256;
    /// Maximum simultaneously occupied connection slots per worker.
    uint maxConnectionsPerCore = 8192;
    /// Number of pinned task fibers per worker.
    uint fiberPoolSize = 1024;
    /// Stack bytes reserved for each task fiber.
    size_t fiberStackBytes = 65_536;
    /// Maximum simultaneous I/O reservations per worker, including callbacks still being delivered.
    uint maxPendingIoPerCore = 128;
    /// Maximum bytes per read reservation or copied write.
    uint ioBufferBytes = 4096;
    /// Bound on admitted cross-worker messages per worker.
    uint mailboxCapacity = 256;
    /// Maximum active one-shot timers per worker.
    uint maxTimersPerCore = 1024;
    /// Maximum Linux borrowed-descriptor watches per worker. Zero disables registration.
    uint maxNativeWatchesPerCore = 1024;
}

/// Level-triggered readiness for a descriptor owned by a native library.
enum NativeInterest : uint
{
    none = 0,
    read = 1,
    write = 2,
    error = 4,
}

/// Runs on the descriptor's owner loop, outside of any task fiber.
alias NativeReadyFn = void delegate(int fd, NativeInterest events) @safe nothrow @nogc;

/// A connection identity remains stable until its final operation retires.
struct ConnectionId
{
    /// Loop that owns the connection.
    uint ownerCore;
    /// Index in the owner's connection table.
    uint slot;
    /// Unique lifetime of that slot.
    ulong generation;
}

/// Identity of one task timer.
struct TimerId
{
    /// Loop that owns the timer.
    uint ownerCore;
    /// Timer identifier within its generation.
    uint slot;
    /// Unique timer lifetime.
    ulong generation;
}

/// Configuration for one TCP listener.
struct ListenOptions
{
    /// Host name or numeric IP to bind.
    string host = "127.0.0.1";
    /// Port to bind. Zero requests an available local port.
    ushort port = 8080;
    /// Maximum backlog requested from the operating system.
    uint backlog = 1024;
}

/// Final outcome of an admitted read or write.
struct Completion
{
    /// Connection associated with the original operation.
    ConnectionId connection;
    /// Final status after resolving cancellation against the operation.
    Status status;
    /// Bytes received or transmitted by this operation, including any completed prefix.
    size_t bytes;
}

/// Called on the owner loop for a newly admitted socket.
alias AcceptFn = void function(ConnectionId) @safe nothrow @nogc;
/// Called once on the owner loop when a write reaches its final outcome.
alias CompletionFn = void function(Completion) @safe nothrow @nogc;
/// A scheduled callback. A posted task may yield on the owner loop.
alias TaskFn = void function() @safe nothrow @nogc;
/// The received bytes may be used within the callback invocation. A successful empty read is EOF.
alias ReadFn = void function(Completion, scope const(ubyte)[]) @safe nothrow @nogc;

/// A listener owned by the application. It may run concurrently on different workers.
alias AcceptDelegate = void delegate(ConnectionId) @safe nothrow @nogc;
/// An application callback for the final outcome on the connection owner.
alias CompletionDelegate = void delegate(Completion) @safe nothrow @nogc;
/// A receive callback that borrows the completed bytes for the duration of the call.
alias ReadDelegate = void delegate(Completion, scope const(ubyte)[]) @safe nothrow @nogc;

/// An owned task bound to the worker that posts it.
alias TaskDelegate = void delegate() @safe nothrow @nogc;

/// A ticket for the exact lifetime of one read or write reservation.
struct IoId
{
    /// Connection associated with the operation.
    ConnectionId connection;
    /// Index in the owner's operation table.
    uint slot;
    /// Generation of the operation slot.
    uint generation;
}

/// Observations from one worker between startup and joined shutdown.
struct WorkerStats
{
    /// D GC bytes allocated on the worker.
    ulong gcAllocated;
    /// Process collection count delta during that worker's lifetime.
    size_t gcCollections;
    /// Whether selecting the preferred CPU succeeded.
    bool affinityPinned;
    /// Worker CPU time in nanoseconds during the sampled Linux run.
    ulong cpuNanos;
    /// Voluntary context switches attributed to this worker.
    ulong voluntarySwitches;
    /// Involuntary context switches attributed to this worker.
    ulong involuntarySwitches;
    /// Occupied operation buffers after the final completion drain.
    uint outstandingOperations;
}

/// A handle that lets a completion on the owner loop resume one suspended task fiber. The
/// generation changes whenever the fiber slot is reused, so a handle outliving its task is rejected.
struct TaskWaker
{
    /// Loop that owns the fiber.
    uint ownerCore = uint.max;
    /// Fiber slot in the owner's pool.
    uint slot;
    /// Lifetime of the task in that slot. Zero marks an empty handle.
    ulong generation;

    /// Whether this handle names a task, live or retired.
    bool valid() const pure nothrow @nogc
    {
        return generation != 0;
    }
}

/// One posted task's copied identity and cancellation context.
struct TaskContext
{
    /// Caller-assigned correlation identifier.
    ulong requestId;
    /// Cancellation and earliest deadline propagated to the task.
    Context cancellation;
    /// High half of the caller's trace identifier.
    ulong traceIdHigh;
    /// Low half of the caller's trace identifier.
    ulong traceIdLow;
    /// Active span associated with this task.
    ulong spanId;

    /// Create a context with a caller-assigned identity and optional cancellation.
    this(ulong requestId, Context cancellation = Context.init) nothrow @nogc
    {
        this.requestId = requestId;
        this.cancellation = move(cancellation);
    }

    /// Copy the task identity and retain its cancellation state.
    this(ref const TaskContext other) nothrow @nogc
    {
        requestId = other.requestId;
        cancellation = other.cancellation;
        traceIdHigh = other.traceIdHigh;
        traceIdLow = other.traceIdLow;
        spanId = other.spanId;
    }
}
