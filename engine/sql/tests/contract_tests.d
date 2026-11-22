module sql_contract_tests;

import flint.arena : Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.sql : Connection, Driver, Isolation, Pool, PoolOptions, Row, SqlValue, ValueKind, withTransaction;
import std.process : environment;

@safe:

private PoolOptions options(Driver driver, string address, uint size = 1)
{
    PoolOptions result;
    result.driver = driver;
    result.connectionString = address;
    result.maxConnections = size;
    return result;
}

private SqlValue stored(ref scope RequestArena arena, ValueKind kind, scope const(char)[] text) nothrow @nogc
{
    const item = arena.copyIn(cast(const(ubyte)[]) text);
    assert(item.ok());
    return SqlValue(kind, 0, 0, item.value);
}

private bool isText(ref scope RequestArena arena, SqlValue value, scope const(char)[] expected) nothrow @nogc
{
    bool equal;
    const status = arena.read(value.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        equal = bytes == cast(const(ubyte)[]) expected;
    });
    return status == Status.ok && equal;
}

private void exerciseValues(Driver driver, string path)
{
    auto setup = options(driver, path);
    Pool pool;
    const opened = pool.open(setup);
    assert(opened.code == Status.ok, opened.message);
    Context context;
    scope (exit)
        assert(pool.close(context).code == Status.ok);
    auto acquired = pool.acquire(context);
    assert(acquired.ok(), acquired.error.message);
    auto connection = acquired.value;
    auto copied = connection;
    scope (exit)
    {
        assert(pool.release(connection).code == Status.ok);
        assert(pool.release(copied).code == Status.notFound);
    }

    ubyte[8192] scratch;
    scope arena = RequestArena(scratch[]);
    const created = connection.execute(
            "CREATE TEMP TABLE values_test(n bigint, k text, b bytea, z bigint, f boolean)", [], arena, context);
    assert(created.ok(), created.error.message);

    const text = "' ; -- no SQL execution";
    const blob = "blob\0end";
    const SqlValue[5] params = [
        SqlValue.init, stored(arena, ValueKind.text, text), stored(arena, ValueKind.bytes, blob),
        SqlValue(ValueKind.int64, 0), SqlValue(ValueKind.boolean, 0)
    ];
    const insert = driver == Driver.postgres
        ? "INSERT INTO values_test VALUES($1,$2,$3,$4,$5)" : "INSERT INTO values_test VALUES(?,?,?,?,?)";
    const inserted = connection.execute(insert, params[], arena, context);
    assert(inserted.ok(), inserted.error.message);
    assert(inserted.value == 1);
    const SqlValue[5] empty = [
        SqlValue.init, stored(arena, ValueKind.text, ""), stored(arena, ValueKind.bytes, ""),
        SqlValue(ValueKind.int64, -4), SqlValue(ValueKind.boolean, 1)
    ];
    assert(connection.execute(insert, empty[], arena, context).ok());

    Row saved;
    uint seen;
    const read = connection.query("SELECT n,k,b,z,f FROM values_test ORDER BY z DESC", [], arena,
            context, (ref Row row) @safe nothrow @nogc {
        assert(row.columns() == 5);
        assert(row.value(5, arena).error.code == Status.invalidArgument);
        saved = row;
        const n = row.value(0, arena);
        const k = row.value(1, arena);
        const b = row.value(2, arena);
        const z = row.value(3, arena);
        const f = row.value(4, arena);
        assert(n.ok() && k.ok() && b.ok() && z.ok() && f.ok());
        assert(n.value.kind == ValueKind.null_);
        assert(k.value.kind == ValueKind.text && isText(arena, k.value, seen == 0 ? text : ""));
        assert(b.value.kind == ValueKind.bytes && isText(arena, b.value, seen == 0 ? blob : ""));
        assert(z.value.kind == ValueKind.int64 && z.value.integer == (seen == 0 ? 0 : -4));
        assert(f.value.kind == ValueKind.boolean && f.value.integer == (seen == 0 ? 0 : 1));
        ++seen;
        return Error.init;
    });
    assert(read.code == Status.ok, read.message);
    assert(seen == 2);
    assert(saved.columns() == 0);
    assert(saved.value(0, arena).error.code == Status.notFound);
    exerciseTextRules(driver, connection, arena, context);
    const multi = connection.execute("SELECT 1; SELECT 2", [], arena, context);
    assert(multi.error.code == Status.invalidArgument);
    assert(connection.execute("SELECT 1", [], arena, context).ok());
}

private void exerciseTextRules(Driver driver, ref Connection connection, ref scope RequestArena arena,
        ref Context context)
{
    if (driver == Driver.sqlite)
    {
        const rejected = connection.execute("PRAGMA journal_mode=WAL", [], arena, context);
        assert(rejected.error.code == Status.permissionDenied);
    }
    const nulText = stored(arena, ValueKind.text, "early\0late");
    const identity = driver == Driver.sqlite ? "SELECT ?" : "SELECT $1::text";
    const withNull = connection.query(identity, [nulText], arena, context, (ref Row row) @safe nothrow @nogc {
        const found = row.value(0, arena);
        assert(found.ok() && found.value.kind == ValueKind.text && isText(arena, found.value, "early\0late"));
        return Error.init;
    });
    assert(withNull.code == (driver == Driver.sqlite ? Status.ok : Status.invalidArgument));
}

private void exerciseTransaction(Driver driver, string address)
{
    Pool pool;
    assert(pool.open(options(driver, address)).code == Status.ok);
    Context context;
    scope (exit)
        assert(pool.close(context).code == Status.ok);
    auto acquired = pool.acquire(context);
    assert(acquired.ok());
    scope RequestArena arena;
    auto connection = acquired.value;
    assert(connection.execute("CREATE TEMP TABLE transaction_test(value bigint)", [], arena, context).ok());
    assert(pool.release(connection).code == Status.ok);

    const rejected = withTransaction(pool, Isolation.serializable, context, (ref Connection lease) @safe nothrow @nogc {
        assert(lease.execute("INSERT INTO transaction_test VALUES(11)", [], arena, context).ok());
        assert(lease.execute("INSERT INTO transaction_test VALUES(12)", [], arena, context).ok());
        const nested = withTransaction(pool, Isolation.readCommitted, context,
            (ref Connection nestedLease) @safe nothrow @nogc => Error.init);
        assert(nested.code == Status.conflict);
        return Error(Status.invalidArgument, "rollback requested by test");
    });
    assert(rejected.code == Status.invalidArgument);
    const committed = withTransaction(pool, Isolation.readCommitted, context,
            (ref Connection lease) @safe nothrow @nogc => lease.execute("INSERT INTO transaction_test VALUES(23)",
                [], arena, context).error);
    assert(committed.code == Status.ok, committed.message);
    acquired = pool.acquire(context);
    assert(acquired.ok());
    connection = acquired.value;
    scope (exit)
        assert(pool.release(connection).code == Status.ok);
    size_t rows;
    const read = connection.query("SELECT value FROM transaction_test", [], arena, context,
            (ref Row row) @safe nothrow @nogc {
        const value = row.value(0, arena);
        assert(value.ok() && value.value.integer == 23);
        ++rows;
        return Error.init;
    });
    assert(read.code == Status.ok && rows == 1);
}

private void exercisePrepared(Driver driver, string address)
{
    import std.conv : to;

    Pool pool;
    assert(pool.open(options(driver, address)).code == Status.ok);
    Context context;
    scope (exit)
        assert(pool.close(context).code == Status.ok);
    auto acquired = pool.acquire(context);
    assert(acquired.ok());
    auto lease = acquired.value;
    scope (exit)
        assert(pool.release(lease).code == Status.ok);
    scope RequestArena arena;
    assert(lease.execute("CREATE TEMP TABLE prepare_test(id bigint)", [], arena, context).ok());
    foreach (key; 0 .. 129)
    {
        const statement = "SELECT " ~ key.to!string;
        const fetched = lease.query(statement, [], arena, context, (ref Row row) @safe nothrow @nogc {
            const value = row.value(0, arena);
            assert(value.ok() && value.value.integer == key);
            return Error.init;
        });
        assert(fetched.code == Status.ok, fetched.message);
    }
    assert(lease.execute("SELECT 0", [], arena, context).ok());
    assert(lease.execute("SELECT * FROM prepare_test", [], arena, context).ok());
    assert(lease.execute("ALTER TABLE prepare_test ADD COLUMN added BIGINT", [], arena, context).ok());
    const changed = lease.execute("SELECT * FROM prepare_test", [], arena, context);
    assert(changed.ok() || changed.error.code == Status.unsupported);
}

private long scalar(ref Connection lease, scope const(char)[] statement, ref Context context) nothrow @nogc
{
    scope RequestArena arena;
    long output;
    const read = lease.query(statement, [], arena, context, (ref Row row) @safe nothrow @nogc {
        const value = row.value(0, arena);
        assert(value.ok() && value.value.kind == ValueKind.int64);
        output = value.value.integer;
        return Error.init;
    });
    assert(read.code == Status.ok, read.message);
    return output;
}

version (FlintNativeSqlite)
{
    @("SQLite typed values, explicit binding, statement boundaries and stale rows")
    unittest
    {
        exerciseValues(Driver.sqlite, ":memory:");
        exerciseTransaction(Driver.sqlite, ":memory:");
        exercisePrepared(Driver.sqlite, ":memory:");
    }

    @("Sixteen live SQLite leases saturate and cannot be used after release")
    unittest
    {
        auto setup = options(Driver.sqlite, ":memory:", 16);
        setup.maxWaiters = 0;
        Pool pool;
        assert(pool.open(setup).code == Status.ok);
        Context context;
        scope (exit)
            assert(pool.close(context).code == Status.ok);
        Connection[16] leases;
        foreach (ref lease; leases)
        {
            const acquired = pool.acquire(context);
            assert(acquired.ok());
            lease = acquired.value;
        }
        assert(pool.acquire(context).error.code == Status.resourceExhausted);
        foreach (ref lease; leases)
            assert(pool.release(lease).code == Status.ok);
        auto acquired = pool.acquire(context);
        assert(acquired.ok());
        assert(pool.release(acquired.value).code == Status.ok);
    }

    private void contend(Pool* pool, uint rounds, bool* failed) nothrow
    {
        Context context;
        scope RequestArena arena;
        foreach (_; 0 .. rounds)
        {
            auto acquired = pool.acquire(context);
            if (!acquired.ok())
            {
                *failed = true;
                return;
            }
            auto lease = acquired.value;
            *failed |= !lease.execute("SELECT 1", [], arena, context).ok();
            *failed |= pool.release(lease).code != Status.ok;
        }
    }

    @("an exhausted pool hands a released lease to its queued waiter without a polling stall")
    @system unittest
    {
        import core.thread : Thread;
        import core.time : MonoTime;

        Pool pool;
        assert(pool.open(options(Driver.sqlite, ":memory:")).code == Status.ok);
        Context context;
        scope (exit)
            assert(pool.close(context).code == Status.ok);
        enum rounds = 200;
        bool firstFailed, secondFailed;
        const started = MonoTime.currTime;
        auto first = new Thread({ contend(&pool, rounds, &firstFailed); }).start();
        auto second = new Thread({ contend(&pool, rounds, &secondFailed); }).start();
        first.join();
        second.join();
        const elapsed = (MonoTime.currTime - started).total!"msecs";
        assert(!firstFailed && !secondFailed);
        // 400 one-connection handoffs take a few milliseconds; a 1–2 ms poll per handoff takes far longer.
        assert(elapsed < 100, "queued SQL waiters stalled between lease handoffs");
    }
}

version (FlintNativeLibpq)
{
    @("PostgreSQL typed values and live cancel drain with transaction reset")
    unittest
    {
        const address = environment.get("FLINT_SQL_PG_TEST_DSN");
        if (address.length == 0)
            return;
        exerciseValues(Driver.postgres, address);
        exerciseTransaction(Driver.postgres, address);
        exercisePrepared(Driver.postgres, address);
        Pool pool;
        assert(pool.open(options(Driver.postgres, address)).code == Status.ok);
        Context context;
        scope (exit)
            assert(pool.close(context).code == Status.ok);
        auto acquired = pool.acquire(context);
        assert(acquired.ok());
        auto lease = acquired.value;
        scope (exit)
            assert(pool.release(lease).code == Status.ok);
        scope RequestArena arena;
        const originalBackend = scalar(lease, "SELECT pg_backend_pid()", context);
        assert(lease.execute("BEGIN", [], arena, context).ok());
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(80));
        assert(source.ok());
        auto bounded = source.value.context();
        assert(lease.execute("SELECT pg_sleep(10)", [], arena, bounded).error.code == Status.timedOut);
        assert(pool.release(lease).code == Status.ok);
        acquired = pool.acquire(context);
        assert(acquired.ok());
        lease = acquired.value;
        assert(scalar(lease, "SELECT pg_backend_pid()", context) == originalBackend);
        assert(scalar(lease, "SELECT 123", context) == 123);
    }

    @("PostgreSQL disconnect prevents reuse and surfaces a commit without acknowledgment")
    unittest
    {
        const address = environment.get("FLINT_SQL_PG_TEST_DSN");
        if (address.length == 0)
            return;
        Pool pool;
        assert(pool.open(options(Driver.postgres, address, 2)).code == Status.ok);
        Context context;
        scope (exit)
            assert(pool.close(context).code == Status.ok);
        auto killer = pool.acquire(context);
        assert(killer.ok());
        scope (exit)
            assert(pool.release(killer.value).code == Status.ok);
        scope RequestArena arena;
        const outcome = withTransaction(pool, Isolation.readCommitted, context,
                (ref Connection lease) @safe nothrow @nogc {
            const backend = scalar(lease, "SELECT pg_backend_pid()", context);
            const SqlValue[1] target = [SqlValue(ValueKind.int64, backend)];
            const terminated = killer.value.execute("SELECT pg_terminate_backend($1::int4, 250)",
                target[], arena, context);
            assert(terminated.ok(), terminated.error.message);
            return Error.init;
        });
        assert(outcome.code == Status.unavailable && outcome.message == "SQL commit outcome is unknown");
        assert(killer.value.execute("SELECT 42", [], arena, context).ok());
    }

    @("PostgreSQL reports a commit that the server turned into a rollback as a failure")
    unittest
    {
        const address = environment.get("FLINT_SQL_PG_TEST_DSN");
        if (address.length == 0)
            return;
        Pool pool;
        assert(pool.open(options(Driver.postgres, address, 2)).code == Status.ok);
        Context context;
        scope (exit)
            assert(pool.close(context).code == Status.ok);
        auto setup = pool.acquire(context);
        assert(setup.ok());
        scope RequestArena arena;
        assert(setup.value.execute("CREATE TEMP TABLE IF NOT EXISTS flint_aborted_commit (n int8)",
                [], arena, context).ok());
        assert(pool.release(setup.value).code == Status.ok);
        const outcome = withTransaction(pool, Isolation.readCommitted, context,
                (ref Connection lease) @safe nothrow @nogc {
            scope RequestArena local;
            assert(lease.execute("INSERT INTO flint_aborted_commit VALUES (1)", [], local, context).ok());
            // The failed statement aborts the server transaction; the body still reports success.
            assert(!lease.execute("SELECT 1 / 0", [], local, context).ok());
            return Error.init;
        });
        assert(outcome.code == Status.conflict, "a commit answered with ROLLBACK was reported as success");
    }

}
