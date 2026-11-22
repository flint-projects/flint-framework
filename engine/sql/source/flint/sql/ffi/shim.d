/// Scalar identities and checked copies at the pinned SQL shim boundary.
module flint.sql.ffi.shim;

import flint.arena : Status;

@safe:

version (linux)
{
    version (FlintNativeSqlite)
        version = FlintSqlNative;
    else version (FlintNativeLibpq)
        version = FlintSqlNative;
}
else version (OSX)
{
    version (FlintNativeSqlite)
        version = FlintSqlNative;
    else version (FlintNativeLibpq)
        version = FlintSqlNative;
}

package(flint.sql) struct Identity
{
    ulong slot;
    ulong generation;
}

package(flint.sql) struct Cell
{
    int kind;
    long integer;
    double floating;
    size_t length;
}

package(flint.sql) enum Progress : int
{
    complete,
    wait,
    row
}

package(flint.sql) struct Completed
{
    Status status;
    ulong affected;
}

package(flint.sql) struct Interest
{
    int fd = -1;
    uint events;
}

private struct FlintSqlOperation;

version (FlintSqlNative)
{
    extern (C) nothrow @nogc @system
    {
        private int flint_sql_pool_open(int, const(char)*, size_t, uint, uint, uint, ulong*, ulong*);
        private int flint_sql_pool_acquire(ulong, ulong, ulong*, ulong*, ulong*);
        private void flint_sql_pool_withdraw(ulong, ulong, ulong);
        private int flint_sql_pool_close(ulong, ulong);
        private int flint_sql_pool_release(ulong, ulong, ulong, ulong);
        private void flint_sql_pool_retire(ulong, ulong);
        private int flint_sql_pool_dirty(ulong, ulong, ulong, ulong);
        private int flint_sql_pool_claim_transaction(ulong, ulong);
        private void flint_sql_pool_finish_transaction(ulong, ulong);

        private FlintSqlOperation* flint_sql_operation_new(const(char)*, size_t, size_t, int, long, int*);
        private FlintSqlOperation* flint_sql_operation_new_script(const(char)*, size_t, long, int*);
        private int flint_sql_operation_bind(FlintSqlOperation*, size_t, int, long, double, const(void)*, size_t);
        private int flint_sql_operation_start(FlintSqlOperation*, ulong, ulong);
        private int flint_sql_operation_drive(FlintSqlOperation*, int*, uint*);
        private void flint_sql_operation_cancel(FlintSqlOperation*);
        private void flint_sql_operation_abort(FlintSqlOperation*);
        private ulong flint_sql_operation_publish_row(FlintSqlOperation*);
        private void flint_sql_operation_next(FlintSqlOperation*);
        private int flint_sql_operation_finish(FlintSqlOperation*, ulong*);
        private void flint_sql_operation_free(FlintSqlOperation*);

        private uint flint_sql_row_columns(ulong, ulong);
        private int flint_sql_row_info(ulong, ulong, uint, Cell*);
        private int flint_sql_row_copy(ulong, ulong, uint, void*, size_t);
        private int flint_sql_poll(int, uint, uint);
    }
}

// SAFETY: The shim validates the bounds, copies the address synchronously, and writes two scalar outputs.
package(flint.sql) Status openPool(int driver, scope const(char)[] address, uint capacity,
        uint maxWaiters, uint prepared, out Identity handle) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_pool_open(driver, address.ptr, address.length, capacity,
                maxWaiters, prepared, &handle.slot, &handle.generation);
    else
        return Status.unsupported;
}

// SAFETY: Locked generation and FIFO checks consume only scalars and write to live out parameters.
package(flint.sql) Status acquirePool(Identity handle, ref ulong ticket, out Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_pool_acquire(handle.slot, handle.generation, &ticket,
                &lease.slot, &lease.generation);
    else
        return Status.unsupported;
}

// SAFETY: This scalar cancellation removes only a matching waiter from a live generation.
package(flint.sql) void withdrawPool(Identity handle, ulong ticket) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        flint_sql_pool_withdraw(handle.slot, handle.generation, ticket);
}

// SAFETY: Closing a generation removes only idle native owners. Outstanding leases prevent reclamation.
package(flint.sql) Status closePool(Identity handle) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_pool_close(handle.slot, handle.generation);
    else
        return Status.unsupported;
}

// SAFETY: Release checks both generation-checked scalar identities and refuses active native work.
package(flint.sql) Status releasePool(Identity pool, Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_pool_release(pool.slot, pool.generation, lease.slot, lease.generation);
    else
        return Status.unsupported;
}

// SAFETY: Retirement marks a matching scalar generation without reclaiming any active native owner.
package(flint.sql) void retireLease(Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        flint_sql_pool_retire(lease.slot, lease.generation);
}

// SAFETY: The shim checks only scalar lease identity and idle state under its lock.
package(flint.sql) bool dirtyLease(Identity pool, Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return flint_sql_pool_dirty(pool.slot, pool.generation, lease.slot, lease.generation) != 0;
    else
        return false;
}

// SAFETY: The shim modifies only the checked lease's transaction marker under its lock.
package(flint.sql) Status claimTransaction(Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_pool_claim_transaction(lease.slot, lease.generation);
    else
        return Status.unsupported;
}

// SAFETY: The shim clears only the checked lease's transaction marker under its lock.
package(flint.sql) void endTransaction(Identity lease) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        flint_sql_pool_finish_transaction(lease.slot, lease.generation);
}

package(flint.sql) struct Operation
{
    private FlintSqlOperation* native;
    private bool started;

    @disable this(this);

    // SAFETY: The scoped SQL slice has explicit bounds. The shim copies all bytes before returning.
    Status allocate(scope const(char)[] sql, size_t count, bool rows, long deadline) scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (native !is null)
                return Status.conflict;
            int status;
            native = flint_sql_operation_new(sql.ptr, sql.length, count, rows, deadline, &status);
            return cast(Status) status;
        }
        else
            return Status.unsupported;
    }

    // SAFETY: The native boundary copies the scoped bytes and owns the complete program before it can enqueue.
    Status allocateScript(scope const(char)[] sql, long deadline) scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (native !is null)
                return Status.conflict;
            int status;
            native = flint_sql_operation_new_script(sql.ptr, sql.length, deadline, &status);
            return cast(Status) status;
        }
        else
            return Status.unsupported;
    }

    // SAFETY: Only a live unsubmitted operation receives a copy of this bounded byte slice.
    Status bind(size_t index, Cell value, scope const(ubyte)[] bytes) scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (native is null || started)
                return Status.conflict;
            return cast(Status) flint_sql_operation_bind(native, index, value.kind, value.integer,
                    value.floating, bytes.ptr, bytes.length);
        }
        else
            return Status.unsupported;
    }

    // SAFETY: Starting claims this sole operation owner against a validated live lease.
    Status start(Identity lease) scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (native is null || started)
                return Status.conflict;
            const status = cast(Status) flint_sql_operation_start(native, lease.slot, lease.generation);
            started = status == Status.ok;
            return status;
        }
        else
            return Status.unsupported;
    }

    // SAFETY: Active native work shares no borrowed D memory. Only scalar readiness is returned.
    Progress drive(out Interest interest) scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (started)
                return cast(Progress) flint_sql_operation_drive(native, &interest.fd, &interest.events);
        }
        return Progress.complete;
    }

    // SAFETY: Cancellation keeps the native operation and lease alive until a terminal acknowledgment.
    void cancel() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (started)
                flint_sql_operation_cancel(native);
        }
    }

    // SAFETY: The shim transfers a started operation into an owned cleanup or finalizes it itself.
    void abort() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (!started)
                return;
            flint_sql_operation_abort(native);
            native = null;
            started = false;
        }
    }

    // SAFETY: Publication yields a checked scalar generation; no pointer reaches the row consumer.
    ulong publishRow() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (started)
                return flint_sql_operation_publish_row(native);
        }
        return 0;
    }

    // SAFETY: The shim invalidates the generation before it lets the driver advance the row.
    void nextRow() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (started)
                flint_sql_operation_next(native);
        }
    }

    // SAFETY: Only a terminal operation may be acknowledged; native publication already stopped.
    Completed finish() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (!started)
                return Completed(Status.conflict);
            started = false;
            Completed result;
            result.status = cast(Status) flint_sql_operation_finish(native, &result.affected);
            return result;
        }
        else
            return Completed(Status.unsupported);
    }

    // SAFETY: Unsubmitted or acknowledged work has one owner and no driver may retain the pointer.
    void close() scope @trusted nothrow @nogc
    {
        version (FlintSqlNative)
        {
            if (started)
                abort();
            else if (native !is null)
            {
                flint_sql_operation_free(native);
                native = null;
            }
        }
    }
}

// SAFETY: The shim checks the live row generation and returns a column count by value.
package(flint.sql) uint rowColumns(ulong slot, ulong generation) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return flint_sql_row_columns(slot, generation);
    else
        return 0;
}

// SAFETY: Synchronized generation validation and explicit column bounds precede the scalar copy.
package(flint.sql) Status inspectCell(Identity row, uint column, out Cell cell) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_row_info(row.slot, row.generation, column, &cell);
    else
        return Status.unsupported;
}

// SAFETY: The output span is mutable, scoped, and fully checked against a generation-checked cell length.
package(flint.sql) Status copyCell(Identity row, uint column, scope ubyte[] output) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_row_copy(row.slot, row.generation, column, output.ptr, output.length);
    else
        return Status.unsupported;
}

// SAFETY: Poll borrows a scalar descriptor for this call and installs no pointer or callback.
package(flint.sql) Status waitOffReactor(Interest interest, uint millis) @trusted nothrow @nogc
{
    version (FlintSqlNative)
        return cast(Status) flint_sql_poll(interest.fd, interest.events, millis);
    else
        return Status.unsupported;
}
