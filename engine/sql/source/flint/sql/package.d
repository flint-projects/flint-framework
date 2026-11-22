/// Typed SQL with exclusive pooled connections and scoped row access.
module flint.sql;

import core.thread.fiber : Fiber;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.sql.ffi.shim : Cell, Identity, Interest, Operation, Progress, acquirePool,
    claimTransaction, closePool, copyCell, dirtyLease, endTransaction, inspectCell, openPool,
    releasePool, retireLease, rowColumns, withdrawPool;
import flint.sql.sys.wait : admit, admitStartup, joinLeaseQueue, leaseChanged, leaseMark,
    leaveLeaseQueue, pause, pauseForLease, waitFor;

@safe:

/// A pinned native backend.
enum Driver : ubyte
{
    postgres,
    sqlite
}

/// Isolation levels accepted by the transaction helper.
enum Isolation : ubyte
{
    readCommitted,
    repeatableRead,
    serializable
}

/// Discriminant of a bound or returned SQL value.
enum ValueKind : ubyte
{
    null_,
    boolean,
    int64,
    float64,
    text,
    bytes
}

/// A value containing scalars or a byte handle in the operation's request arena.
struct SqlValue
{
    /// Active variant.
    ValueKind kind;
    /// Boolean 0/1 or signed 64-bit integer.
    long integer;
    /// Finite 64-bit floating-point value.
    double floating;
    /// Arena handle for text and bytes.
    Buffer bytes;
}

/// Metadata for a registered transactional invoker.
struct Transactional
{
    /// Transaction isolation selected by the caller.
    Isolation isolation = Isolation.readCommitted;
}

/// Limits and immutable startup configuration.
struct PoolOptions
{
    /// Native provider to use.
    Driver driver = Driver.postgres;
    /// libpq connection settings or a SQLite local path/URI.
    string connectionString;
    /// Maximum simultaneously leased connections, at most 16.
    uint maxConnections = 16;
    /// Maximum queued acquisitions, at most 256.
    uint maxWaiters = 256;
    /// Local upper bound on waiting for a lease.
    long acquireTimeoutNanos = 5_000_000_000L;
    /// Maximum cached prepared statements per connection, at most 128.
    uint maxPreparedPerConnection = 128;
}

/// Generation-checked access to the row currently inside a consumer.
struct Row
{
    private ulong slot;
    private ulong generation;

    private this(ulong slot, ulong generation) nothrow @nogc
    {
        this.slot = slot;
        this.generation = generation;
    }

    /// Copy one cell into the supplied arena if it contains bytes.
    Result!SqlValue value(uint column, ref scope RequestArena arena) const nothrow @nogc
    {
        const row = Identity(slot, generation);
        Cell cell;
        auto status = inspectCell(row, column, cell);
        if (status != Status.ok)
            return Result!SqlValue(SqlValue.init, Error(status, "SQL row cell is unavailable"));

        SqlValue output = SqlValue(cast(ValueKind) cell.kind, cell.integer, cell.floating);
        if (output.kind == ValueKind.text || output.kind == ValueKind.bytes)
        {
            const destination = arena.allocate(cell.length, 1);
            if (!destination.ok())
                return Result!SqlValue(SqlValue.init, destination.error);
            Status copied;
            status = arena.write(destination.value, (scope ubyte[] bytes) @safe nothrow @nogc {
                copied = copyCell(row, column, bytes);
            });
            if (status != Status.ok || copied != Status.ok)
                return Result!SqlValue(SqlValue.init, Error(status == Status.ok ? copied : status,
                        "SQL row bytes are unavailable"));
            output.bytes = destination.value;
        }
        return Result!SqlValue(output);
    }

    /// Column count while the row is live. A stale row reports zero.
    uint columns() const nothrow @nogc
    {
        return rowColumns(slot, generation);
    }
}

/// Consumes a single row synchronously on the caller's thread or fiber.
alias RowConsumer = Error delegate(ref Row row) @safe nothrow @nogc;

/// One exclusive generation-checked lease.
struct Connection
{
    private ulong slot;
    private ulong generation;

    private this(Identity identity) nothrow @nogc
    {
        slot = identity.slot;
        generation = identity.generation;
    }

    private Identity identity() const nothrow @nogc
    {
        return Identity(slot, generation);
    }

    /// Execute one parameterized statement and return its affected rows.
    Result!ulong execute(scope const(char)[] sql, scope const(SqlValue)[] params,
            ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return perform(identity(), sql, params, arena, context, null);
    }

    /// Run a complete startup SQL program on this exclusive lease.
    Error executeScript(scope const(char)[] sql, ref Context context) nothrow @nogc
    {
        const startup = admitStartup();
        if (startup.code != Status.ok)
            return startup;
        scope RequestArena unused;
        return perform(identity(), sql, [], unused, context, null, true).error;
    }

    /// Retire the native session when external transaction or lock cleanup cannot be verified.
    void retire() const nothrow @nogc
    {
        retireLease(identity());
    }

    /// Consume each result row before releasing the driver's row storage.
    Error query(scope const(char)[] sql, scope const(SqlValue)[] params, ref scope RequestArena arena,
            ref Context context, scope RowConsumer consume) nothrow @nogc
    {
        if (consume is null)
            return Error(Status.invalidArgument, "SQL query requires a row consumer");
        return perform(identity(), sql, params, arena, context, consume).error;
    }
}

private alias Parameters = const(SqlValue)[];
private alias Execution = Result!ulong;

private Status bind(ref scope Operation work, scope Parameters params, ref scope RequestArena arena) nothrow @nogc
{
    foreach (index, ref const parameter; params)
    {
        const value = Cell(cast(int) parameter.kind, parameter.integer, parameter.floating);
        Status status;
        if (parameter.kind == ValueKind.text || parameter.kind == ValueKind.bytes)
        {
            const borrowed = arena.read(parameter.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                status = work.bind(index, value, bytes);
            });
            if (borrowed != Status.ok)
                return borrowed;
        }
        else
            status = work.bind(index, value, []);
        if (status != Status.ok)
            return status;
    }
    return Status.ok;
}

private Execution perform(Identity lease, scope const(char)[] sql, scope const(SqlValue)[] params,
        ref scope RequestArena arena, ref Context context, scope RowConsumer consume, bool script = false) nothrow @nogc
{
    const ownership = admit();
    if (ownership.code != Status.ok)
        return Result!ulong(0, ownership);
    const initial = context.check();
    if (initial.code != Status.ok)
        return Result!ulong(0, initial);
    if (lease.generation == 0)
        return Result!ulong(0, Error(Status.notFound, "SQL lease is stale"));

    scope Operation operation;
    scope (exit)
        operation.close();
    const deadline = context.deadline().monotonicNanoseconds;
    auto status = script ? operation.allocateScript(sql, deadline) : operation.allocate(sql,
            params.length, consume !is null, deadline);
    if (status == Status.ok)
        status = bind(operation, params, arena);
    if (status == Status.ok)
        status = operation.start(lease);
    if (status != Status.ok)
        return Result!ulong(0, Error(status, "SQL statement or lease is invalid"));

    return drain(operation, lease.slot, context, consume);
}

private Error consumeRow(ref scope Operation operation, ulong slot, scope RowConsumer consumer) nothrow @nogc
{
    const generation = operation.publishRow();
    if (generation == 0)
        return Error(Status.resourceExhausted, "SQL row identity exhausted");
    auto row = Row(slot, generation);
    return consumer(row);
}

private Execution drain(ref scope Operation work, ulong slot, ref Context context, scope RowConsumer sink) nothrow @nogc
{
    Error terminal;
    Deadline cleanup;
    for (;;)
    {
        if (terminal.code == Status.ok)
            terminal = context.check();
        if (terminal.code != Status.ok && cleanup == Deadline.init)
        {
            work.cancel();
            cleanup = Deadline.afterMillis(250);
        }
        Interest interest;
        final switch (work.drive(interest))
        {
        case Progress.complete:
            const result = work.finish();
            if (terminal.code == Status.ok)
                terminal = context.check();
            if (terminal.code == Status.ok && result.status != Status.ok)
                terminal = Error(result.status, "SQL driver rejected the statement");
            return Result!ulong(result.affected, terminal);
        case Progress.row:
            if (terminal.code == Status.ok && sink !is null)
                terminal = consumeRow(work, slot, sink);
            work.nextRow();
            break;
        case Progress.wait:
            const paused = waitFor(interest, context, cleanup);
            if (paused.code != Status.ok || Deadline.afterMillis(0).monotonicNanoseconds >= cleanup
                    .monotonicNanoseconds)
            {
                work.abort();
                if (terminal.code == Status.ok)
                    terminal = paused.code == Status.ok ? Error(Status.timedOut, "SQL cleanup timed out") : paused;
                return Result!ulong(0, terminal);
            }
            break;
        }
    }
}

/// One caller's FIFO ticket and wake registration while it waits for a lease.
private struct LeaseWait
{
    Identity pool;
    ulong ticket;
    bool registered;

    Status attempt(out Identity lease) nothrow @nogc
    {
        const queued = ticket != 0;
        const status = acquirePool(pool, ticket, lease);
        if (status != Status.ok)
            return status;
        unregister();
        // The next queued waiter is now the head and may find another idle lease.
        if (queued)
            leaseChanged(pool.slot);
        return status;
    }

    /// Register for wakeups. Returns whether the caller was already registered.
    bool register() nothrow @nogc
    {
        if (registered)
            return true;
        joinLeaseQueue(pool.slot);
        registered = true;
        return false;
    }

    void leave() nothrow @nogc
    {
        unregister();
        if (ticket == 0)
            return;
        // A departing waiter may have been the queue head.
        withdrawPool(pool, ticket);
        ticket = 0;
        leaseChanged(pool.slot);
    }

    private void unregister() nothrow @nogc
    {
        if (!registered)
            return;
        leaveLeaseQueue(pool.slot);
        registered = false;
    }
}

/// Thread-safe scalar handle to a bounded connection directory.
struct Pool
{
    private ulong slot;
    private ulong generation;
    private long waitNanos;
    private Driver selected;

    private this(Identity identity, Driver driver, long acquireNanos) nothrow @nogc
    {
        slot = identity.slot;
        generation = identity.generation;
        waitNanos = acquireNanos;
        selected = driver;
    }

    private Identity identity() const nothrow @nogc
    {
        return Identity(slot, generation);
    }

    /// Initialize a directory for the selected pinned provider.
    Error open(PoolOptions options)
    {
        if (generation != 0)
            return Error(Status.conflict, "SQL pool is already open");
        if (options.acquireTimeoutNanos < 0)
            return Error(Status.invalidArgument, "SQL pool timeout cannot be negative");
        Identity created;
        const status = openPool(cast(int) options.driver, options.connectionString,
                options.maxConnections, options.maxWaiters, options.maxPreparedPerConnection, created);
        if (status != Status.ok)
            return Error(status, "could not open SQL pool");
        enum maxAcquireNanos = 5_000_000_000L;
        this = Pool(created, options.driver, options.acquireTimeoutNanos < maxAcquireNanos
                ? options.acquireTimeoutNanos : maxAcquireNanos);
        return Error.init;
    }

    /// Return the configured driver. Lease acquisition still checks that the pool is live.
    Driver driver() const pure nothrow @nogc
    {
        return selected;
    }

    /// Acquire the oldest waiting request's available lease within the deadline.
    Result!Connection acquire(ref Context context) nothrow @nogc
    {
        const ownership = admit();
        if (ownership.code != Status.ok)
            return Result!Connection(Connection.init, ownership);
        const start = Deadline.afterMillis(0).monotonicNanoseconds;
        const local = start < long.max - waitNanos ? start + waitNanos : long.max - 1;
        LeaseWait wait = LeaseWait(identity());
        scope (exit)
            wait.leave();
        for (;;)
        {
            const check = context.check();
            if (check.code != Status.ok)
                return Result!Connection(Connection.init, check);
            if (wait.ticket != 0 && Deadline.afterMillis(0).monotonicNanoseconds >= local)
                return Result!Connection(Connection.init, Error(Status.timedOut, "SQL lease wait expired"));
            const mark = leaseMark(slot);
            Identity lease;
            const status = wait.attempt(lease);
            if (status == Status.ok)
                return Result!Connection(Connection(lease));
            if (status != Status.conflict)
                return Result!Connection(Connection.init, Error(status, "SQL pool rejected acquisition"));
            if (Deadline.afterMillis(0).monotonicNanoseconds >= local)
                return Result!Connection(Connection.init, Error(Status.timedOut, "SQL lease wait expired"));
            // Retry once registered so that a release after this point wakes the sleep below.
            if (!wait.register())
                continue;
            const paused = pauseForLease(slot, mark);
            if (paused.code != Status.ok)
                return Result!Connection(Connection.init, paused);
        }
    }

    /// Return an idle lease after rolling back any remaining transaction.
    Error release(ref Connection connection) nothrow @nogc
    {
        const handle = connection.identity();
        Error cleanup;
        if (dirtyLease(identity(), handle))
        {
            cleanup = rollback(connection);
            if (cleanup.code != Status.ok)
                retireLease(handle);
        }
        const status = releasePool(identity(), handle);
        if (status != Status.ok)
            return Error(status, "SQL lease could not be released");
        leaseChanged(slot);
        connection = Connection.init;
        return cleanup;
    }

    /// Stop admission and close idle connections after all leases return.
    Error close(ref Context context) nothrow @nogc
    {
        if (generation == 0)
            return Error.init;
        for (;;)
        {
            const status = closePool(identity());
            if (status == Status.ok || status == Status.notFound)
            {
                this = Pool.init;
                return Error.init;
            }
            if (status != Status.conflict)
                return Error(status, "SQL pool could not close");
            const check = context.check();
            if (check.code != Status.ok)
                return check;
            const paused = pause();
            if (paused.code != Status.ok)
                return paused;
        }
    }
}

/// The explicit transaction callback on the one acquired connection.
alias TransactionBody = Error delegate(ref Connection connection) @safe nothrow @nogc;

private Fiber[256] activeFibers;
private bool activeThread;

private size_t enterTransaction(Fiber fiber) nothrow @nogc
{
    if (fiber is null)
    {
        if (activeThread)
            return size_t.max;
        activeThread = true;
        return activeFibers.length;
    }
    size_t empty = size_t.max;
    foreach (index, live; activeFibers)
    {
        if (live is fiber)
            return size_t.max;
        if (live is null && empty == size_t.max)
            empty = index;
    }
    if (empty != size_t.max)
        activeFibers[empty] = fiber;
    return empty;
}

private void leaveTransaction(size_t index) nothrow @nogc
{
    if (index == activeFibers.length)
        activeThread = false;
    else
        activeFibers[index] = null;
}

private Error rollback(ref Connection connection) nothrow @nogc
{
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(250));
    if (!source.ok())
        return source.error;
    auto cleanup = source.value.context();
    scope RequestArena arena;
    return connection.execute("ROLLBACK", [], arena, cleanup).error;
}

/// Execute a callback on one lease and commit only on success.
Error withTransaction(ref Pool pool, Isolation isolation, ref Context context, scope TransactionBody body) nothrow @nogc
{
    if (body is null || isolation > Isolation.serializable)
        return Error(Status.invalidArgument, "invalid SQL transaction");
    const entered = enterTransaction(Fiber.getThis());
    if (entered == size_t.max)
        return Error(Status.conflict, "nested or saturated SQL transaction scope");
    scope (exit)
        leaveTransaction(entered);

    auto acquired = pool.acquire(context);
    if (!acquired.ok())
        return acquired.error;
    auto connection = acquired.value;
    const handle = connection.identity();
    scope (exit)
        pool.release(connection);

    const claim = claimTransaction(handle);
    if (claim != Status.ok)
        return Error(claim, "SQL transaction lease is already active");
    scope (exit)
        endTransaction(handle);

    scope RequestArena arena;
    const started = startTransaction(connection, pool.selected, isolation, arena, context);
    if (started.code != Status.ok)
        return started;

    auto borrowed = connection;
    const outcome = body(borrowed);
    return finishTransaction(connection, arena, context, outcome);
}

private Error finishTransaction(ref Connection connection, ref scope RequestArena arena,
        ref Context context, Error outcome) nothrow @nogc
{
    const handle = connection.identity();
    if (outcome.code == Status.ok)
        outcome = context.check();
    if (outcome.code != Status.ok)
    {
        if (rollback(connection).code != Status.ok)
            retireLease(handle);
        return outcome;
    }

    const committed = connection.execute("COMMIT", [], arena, context).error;
    if (committed.code == Status.ok)
        return Error.init;
    if (ambiguous(committed.code))
    {
        retireLease(handle);
        return Error(Status.unavailable, "SQL commit outcome is unknown");
    }
    if (rollback(connection).code != Status.ok)
        retireLease(handle);
    return committed;
}

private bool ambiguous(Status status) pure nothrow @nogc
{
    return status == Status.cancelled || status == Status.timedOut || status == Status.ioError
        || status == Status.unavailable;
}

private Error startTransaction(ref Connection connection, Driver driver, Isolation isolation,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    static immutable postgresQueries = [
        "BEGIN ISOLATION LEVEL READ COMMITTED", "BEGIN ISOLATION LEVEL REPEATABLE READ",
        "BEGIN ISOLATION LEVEL SERIALIZABLE"
    ];
    const sql = driver == Driver.postgres
        ? postgresQueries[isolation] : (isolation == Isolation.serializable ? "BEGIN IMMEDIATE" : "BEGIN");
    return connection.execute(sql, [], arena, context).error;
}
