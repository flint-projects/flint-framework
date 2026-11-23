module sql_offload_tests;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import flint.arena : RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.reactor : Backend, Reactor, ReactorOptions;
import flint.engine.sql : Driver, Pool, PoolOptions;

@safe:

version (FlintNativeSqlite)
    version = FlintSqlReactorTest;
else version (FlintNativeLibpq)
    version = FlintSqlReactorTest;

version (FlintSqlReactorTest)
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    private shared uint beats;

    private void heartbeat() nothrow @nogc
    {
        atomicOp!"+="(beats, 1u);
        auto owner = Reactor.current();
        assert(owner.schedule(Deadline.afterMillis(2), &heartbeat).ok());
    }

    private final class BusyOwner
    {
        Pool pool;
        string statement;
        Status outcome;

        void exercise() nothrow @nogc
        {
            auto owner = Reactor.current();
            scope (exit)
                owner.stop();
            Context context;
            auto acquired = pool.acquire(context);
            assert(acquired.ok(), acquired.error.message);
            scope (exit)
                assert(pool.release(acquired.value).code == Status.ok);
            assert(owner.schedule(Deadline.afterMillis(2), &heartbeat).ok());
            auto source = CancelSource.create(Context.init, Deadline.afterMillis(80));
            assert(source.ok());
            auto limited = source.value.context();
            scope RequestArena arena;
            outcome = acquired.value.execute(statement, [], arena, limited).error.code;
        }
    }

    private __gshared BusyOwner testOwner;

    // SAFETY: The harness publishes before starting the reactor and clears after all workers join.
    private void publish(BusyOwner owner) @trusted nothrow @nogc
    {
        testOwner = owner;
    }

    // SAFETY: This fixture has one reactor owner and leaves its startup object rooted until run returns.
    private void startBusy() @trusted nothrow @nogc
    {
        testOwner.exercise();
    }

    private void boot(BusyOwner work)
    {
        atomicStore(beats, 0U);
        ReactorOptions options;
        version (OSX) // the readiness backend: kqueue on macOS, epoll on Linux (ADR-024)
            options.backend = Backend.kqueue;
        else version (Windows) // IOCP, the one Windows backend (ADR-026)
            options.backend = Backend.iocp;
        else
            options.backend = Backend.epoll;
        options.cores = 1;
        auto owner = Reactor.create(options);
        assert(owner.ok(), owner.error.message);
        publish(work);
        scope (exit)
            publish(null);
        assert(owner.value.post(0, &startBusy).code == Status.ok);
        const ran = owner.value.run();
        assert(ran.code == Status.ok, ran.message);
        assert(work.outcome == Status.timedOut);
        assert(atomicLoad(beats) >= 5);
    }

    version (FlintNativeSqlite) @("Busy SQLite uses a worker and permits reactor heartbeat during cancellation")
    unittest
    {
        const path = buildPath(tempDir(), "flint-sql-" ~ randomUUID().toString() ~ ".sqlite");
        scope (exit)
        {
            if (exists(path))
                remove(path);
        }
        PoolOptions config;
        config.driver = Driver.sqlite;
        config.connectionString = path;
        config.maxConnections = 2;
        auto work = new BusyOwner;
        work.statement = "INSERT INTO busy_test VALUES(2)";
        assert(work.pool.open(config).code == Status.ok);
        Context context;
        scope (exit)
            assert(work.pool.close(context).code == Status.ok);
        auto writer = work.pool.acquire(context);
        assert(writer.ok());
        scope (exit)
            assert(work.pool.release(writer.value).code == Status.ok);
        scope RequestArena arena;
        assert(writer.value.execute("CREATE TABLE busy_test(value INT)", [], arena, context).ok());
        assert(writer.value.execute("BEGIN IMMEDIATE", [], arena, context).ok());
        assert(writer.value.execute("INSERT INTO busy_test VALUES(1)", [], arena, context).ok());

        boot(work);
        assert(writer.value.execute("ROLLBACK", [], arena, context).ok());
    }

    version (FlintNativeLibpq) @("libpq socket progression and cancellation preserve owner reactor heartbeat")
    unittest
    {
        import std.process : environment;

        const address = environment.get("FLINT_SQL_PG_TEST_DSN");
        if (address.length == 0)
            return;
        PoolOptions config;
        config.driver = Driver.postgres;
        config.connectionString = address;
        config.maxConnections = 1;
        auto work = new BusyOwner;
        work.statement = "SELECT pg_sleep(10)";
        assert(work.pool.open(config).code == Status.ok);
        Context context;
        scope (exit)
            assert(work.pool.close(context).code == Status.ok);
        boot(work);

        auto next = work.pool.acquire(context);
        assert(next.ok());
        scope (exit)
            assert(work.pool.release(next.value).code == Status.ok);
        scope RequestArena arena;
        assert(next.value.execute("SELECT 17", [], arena, context).ok());
    }
}
