module sql_failure_tests;

import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Context;
import flint.sql : Connection, Driver, Pool, PoolOptions, Row, SqlFailure, SqlValue, ValueKind;
import std.process : environment;

@safe:

version (FlintNativeSqlite)
    version = FlintSqlFailureTest;
else version (FlintNativeLibpq)
    version = FlintSqlFailureTest;

version (FlintSqlFailureTest)
{
    private struct Lease
    {
        Pool pool;
        Connection connection;
        Context context;
    }

    private void open(Driver driver, string address, ref Lease lease)
    {
        PoolOptions options;
        options.driver = driver;
        options.connectionString = address;
        options.maxConnections = 1;
        assert(lease.pool.open(options).code == Status.ok);
        auto acquired = lease.pool.acquire(lease.context);
        assert(acquired.ok());
        lease.connection = acquired.value;
    }

    private void close(ref Lease lease)
    {
        assert(lease.pool.release(lease.connection).code == Status.ok);
        assert(lease.pool.close(lease.context).code == Status.ok);
    }

    private Status run(ref Lease lease, scope const(char)[] sql)
    {
        scope RequestArena arena;
        return lease.connection.execute(sql, [], arena, lease.context).error.code;
    }

    private string text(ref scope RequestArena arena, Buffer buffer)
    {
        char[128] local;
        size_t length;
        const status = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            length = bytes.length < local.length ? bytes.length : local.length;
            local[0 .. length] = cast(const(char)[]) bytes[0 .. length];
        });
        assert(status == Status.ok);
        return local[0 .. length].idup;
    }

    /// The same statements fail with the same SQLSTATEs on SQLite and PostgreSQL.
    private void exerciseFailures(Driver driver, string address, string table)
    {
        Lease lease;
        open(driver, address, lease);
        scope (exit)
            close(lease);

        cast(void) run(lease, "DROP TABLE IF EXISTS " ~ table);
        assert(run(lease, "CREATE TABLE " ~ table ~ " (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL)") == Status
                .ok);
        assert(!lease.connection.lastFailure().reported, "a successful statement reported a failure");
        assert(run(lease, "INSERT INTO " ~ table ~ " (id, name) VALUES (1, 'Josh')") == Status.ok);

        // A unique violation is 23505 on both drivers, which Spring translates to DuplicateKeyException.
        assert(run(lease, "INSERT INTO " ~ table ~ " (id, name) VALUES (2, 'Josh')") == Status.conflict);
        auto failure = lease.connection.lastFailure();
        assert(failure.reported && failure.sqlState == "23505", failure.sqlState.idup);
        assert(failure.message.length > 0);
        if (driver == Driver.sqlite)
            assert(failure.vendorCode == 2067, "SQLITE_CONSTRAINT_UNIQUE expected"); // SQLITE_CONSTRAINT_UNIQUE

        assert(run(lease, "INSERT INTO " ~ table ~ " (id, name) VALUES (1, 'Jeff')") == Status.conflict);
        failure = lease.connection.lastFailure();
        assert(failure.sqlState == "23505", failure.sqlState.idup);
        if (driver == Driver.sqlite)
            assert(failure.vendorCode == 1555, "SQLITE_CONSTRAINT_PRIMARYKEY expected");

        assert(run(lease, "INSERT INTO " ~ table ~ " (id) VALUES (3)") == Status.conflict);
        assert(lease.connection.lastFailure().sqlState == "23502");

        // Syntax errors are class 42, which Spring translates to BadSqlGrammarException.
        assert(run(lease, "SELEC 1") == Status.invalidArgument);
        failure = lease.connection.lastFailure();
        assert(failure.sqlState.length == 5 && failure.sqlState[0 .. 2] == "42", failure.sqlState.idup);
        assert(run(lease, "SELECT * FROM missing_" ~ table) == Status.invalidArgument);
        assert(lease.connection.lastFailure().sqlState[0 .. 2] == "42");

        // The next statement clears the record.
        assert(run(lease, "SELECT 1") == Status.ok);
        assert(!lease.connection.lastFailure().reported);
        assert(lease.connection.lastFailure().message.length == 0);

        // Column labels: the column name, or its alias.
        ubyte[4096] scratch;
        scope arena = RequestArena(scratch[]);
        Buffer[2] labels;
        uint count;
        const queried = lease.connection.query("SELECT id, name AS first_name FROM " ~ table, [],
                arena, lease.context, (ref Row row) @safe nothrow @nogc {
            foreach (column; 0 .. row.columns)
            {
                auto label = row.name(column, arena);
                if (!label.ok())
                    return label.error;
                if (count < labels.length)
                    labels[count++] = label.value;
            }
            return Error.init;
        });
        assert(queried.code == Status.ok, queried.message);
        assert(count == 2 && text(arena, labels[0]) == "id" && text(arena, labels[1]) == "first_name");
        cast(void) run(lease, "DROP TABLE " ~ table);
    }

    private void exerciseLongName(Driver driver, string address)
    {
        Lease lease;
        open(driver, address, lease);
        scope (exit)
            close(lease);
        // Longer than the local span: the name is fetched again straight into the arena.
        enum alias_ = "a_column_label_that_is_much_longer_than_sixty_four_bytes_for_the_engine";
        static assert(alias_.length > 64);
        ubyte[4096] scratch;
        scope arena = RequestArena(scratch[]);
        Buffer seen;
        const queried = lease.connection.query("SELECT 1 AS " ~ alias_, [], arena, lease.context,
                (ref Row row) @safe nothrow @nogc {
            auto label = row.name(0, arena);
            if (!label.ok())
                return label.error;
            seen = label.value;
            assert(row.name(1, arena).error.code == Status.invalidArgument);
            return Error.init;
        });
        assert(queried.code == Status.ok, queried.message);
        // PostgreSQL truncates identifiers to 63 bytes (NAMEDATALEN); SQLite keeps the whole label.
        const label = text(arena, seen);
        assert(driver == Driver.postgres ? label == alias_[0 .. 63] : label == alias_, label);
    }
}

version (FlintNativeSqlite)
{
    @("SQLite failures carry SQLSTATE, extended result code and message, and rows carry column labels")
    unittest
    {
        exerciseFailures(Driver.sqlite, ":memory:", "customers");
        exerciseLongName(Driver.sqlite, ":memory:");
    }
}

version (FlintNativeLibpq)
{
    @("PostgreSQL failures carry the server's SQLSTATE and message, and rows carry column labels")
    unittest
    {
        const address = environment.get("FLINT_SQL_PG_TEST_DSN");
        if (address.length == 0)
            return;
        exerciseFailures(Driver.postgres, address, "flint_failure_customers");
        exerciseLongName(Driver.postgres, address);
    }
}
