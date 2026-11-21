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
}

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

/// One posted task's copied identity and cancellation context.
struct TaskContext
{
    /// Caller-assigned correlation identifier.
    ulong requestId;
    /// Cancellation and earliest deadline propagated to the task.
    Context cancellation;

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
    }
}
