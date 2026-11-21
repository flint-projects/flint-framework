/// Linked worker for independent-process migration conformance.
module migration_startup;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.migrate : Migration, MigrationOptions, migrate;
import flint.sql : Driver, Pool, PoolOptions, Row, ValueKind;
import generated_plan : migrations;
import std.digest.sha : sha256Of;
import std.stdio : stdin, stdout, writeln;

@safe:

private enum markerSql = "SELECT pg_sleep(4)";

int main(string[] args) @system
{
    if (args.length != 4 || (args[1] != "sqlite" && args[1] != "postgres"))
        return 64;
    PoolOptions config;
    config.driver = args[1] == "sqlite" ? Driver.sqlite : Driver.postgres;
    config.connectionString = args[2];
    config.maxConnections = 1;
    Context context;
    Pool pool;
    const opened = pool.open(config);
    if (opened.code != Status.ok)
        return failure(opened);
    scope (exit)
        pool.close(context);
    const mode = args[3];
    if (mode == "hold")
        return hold(pool, context);
    if (mode == "observe" || mode == "check")
        return inspect(pool, context, mode);

    return runMigration(pool, context, mode);
}

private int runMigration(ref Pool pool, ref Context context, string mode)
{
    MigrationOptions options;
    Migration[] plan = [migrations[0], migrations[2]];
    if (mode == "short")
        options.lockTimeoutNanos = 120_000_000;
    else if (mode == "fail")
        plan = [migrations[0], migrations[1]];
    else if (mode == "crash")
        plan ~= Migration(4, "crash window", markerSql, sha256Of(cast(const(ubyte)[]) markerSql), false);
    else if (mode != "apply")
        return 64;
    const result = migrate(pool, plan, options, context);
    if (mode == "short")
    {
        if (result.error.code != Status.timedOut)
            return failure(result.error);
        if (!probe(pool, context))
            return 1;
        writeln("timeout-cleanup");
        return 0;
    }
    if (!result.ok())
        return failure(result.error);
    writeln("applied=", result.value.applied, " current=", result.value.currentVersion);
    return 0;
}

private int failure(Error error)
{
    writeln(error.code, " ", error.message);
    return 1;
}

private int hold(ref Pool pool, ref Context context) @system
{
    auto held = pool.acquire(context);
    if (!held.ok())
        return failure(held.error);
    auto connection = held.value;
    scope (exit)
        pool.release(connection);
    scope RequestArena unused;
    const sqlite = pool.driver() == Driver.sqlite;
    const lock = sqlite ? "BEGIN IMMEDIATE" : "SELECT pg_advisory_lock(5065504281656773959)";
    const locked = connection.execute(lock, [], unused, context);
    if (!locked.ok())
        return failure(locked.error);
    writeln("locked");
    stdout.flush();
    stdin.readln();
    const unlock = sqlite ? "ROLLBACK" : "SELECT pg_advisory_unlock(5065504281656773959)";
    const released = connection.execute(unlock, [], unused, context);
    return released.ok() ? 0 : failure(released.error);
}

private bool probe(ref Pool pool, ref Context context)
{
    auto lease = pool.acquire(context);
    if (!lease.ok())
        return false;
    scope (exit)
        pool.release(lease.value);
    scope RequestArena unused;
    if (pool.driver() == Driver.postgres)
    {
        enum check = "SELECT (pg_locks.granted::int)::bigint FROM pg_locks "
            ~ "WHERE locktype='advisory' AND pid=pg_backend_pid()";
        long remaining;
        const seen = lease.value.query(check, [], unused, context, (ref Row) @safe nothrow @nogc {
            ++remaining;
            return Error.init;
        });
        return seen.code == Status.ok && remaining == 0;
    }
    return lease.value.execute("SELECT 1", [], unused, context).ok();
}

private int inspect(ref Pool pool, ref Context context, string mode)
{
    auto lease = pool.acquire(context);
    if (!lease.ok())
        return failure(lease.error);
    scope (exit)
        pool.release(lease.value);
    scope RequestArena unused;
    const sql = mode == "observe" ? "SELECT COUNT(*) FROM flint_schema_history WHERE version=4 AND NOT success"
        : "SELECT CAST(COALESCE(SUM(id),0) AS BIGINT) FROM example";
    long count;
    const found = lease.value.query(sql, [], unused, context, (ref Row row) @safe nothrow @nogc {
        const cell = row.value(0, unused);
        if (!cell.ok() || cell.value.kind != ValueKind.int64)
            return Error(Status.invalidArgument, "fixture query did not produce an integral result");
        count = cell.value.integer;
        return Error.init;
    });
    if (found.code != Status.ok)
        return failure(found);
    writeln(count);
    return 0;
}
