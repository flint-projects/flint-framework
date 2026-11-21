/// Exclusive startup migration, transaction ownership, and recovery markers.
module flint.migrate.runner;

import core.time : MonoTime;
import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.migrate.embedding : correctDigest, maximumProgram, maximumPrograms, validIdentifier, validText;
import flint.migrate.history : History, Prefix, command, integer;
import flint.migrate.types : Migration, MigrationOptions, MigrationReport;
import flint.sql : Connection, Driver, Pool, Row, ValueKind;
import std.conv : to;

@safe:
package(flint.migrate):

private enum lockKey = 0x464C_494E_545F_4D47L;

Result!MigrationReport migratePool(ref Pool pool, scope const(Migration)[] plan,
        MigrationOptions options, ref Context context)
{
    MigrationReport report;
    const driver = pool.driver();
    const validated = preflight(plan, options, driver, context);
    if (validated.code != Status.ok)
        return Result!MigrationReport(report, validated);
    report.discovered = cast(uint) plan.length;
    auto acquired = pool.acquire(context);
    if (!acquired.ok())
        return Result!MigrationReport(report, acquired.error);

    auto session = Session(acquired.value, driver);
    scope (failure)
    {
        session.connection.retire();
        cast(void) pool.release(session.connection);
    }
    auto outcome = session.lock(options.lockTimeoutNanos, context);
    if (outcome.code == Status.ok)
        outcome = migrateLocked(session, plan, options, context, report);
    const cleaned = session.cleanup();
    const released = pool.release(session.connection);
    if (outcome.code == Status.ok)
        outcome = cleaned.code == Status.ok ? released : cleaned;
    return Result!MigrationReport(report, outcome);
}

private Error preflight(scope const(Migration)[] plan, MigrationOptions options, Driver driver, ref Context context)
{
    if (options.historyTable.length > 54 || !validIdentifier(options.historyTable))
        return Error(Status.invalidArgument,
                "migration history table must be a valid SQL identifier of at most 54 bytes");
    if (options.lockTimeoutNanos < 0 || plan.length > uint.max)
        return Error(Status.invalidArgument, "invalid migration count or lock timeout");

    ulong previous;
    size_t total;
    foreach (ref const item; plan)
    {
        const cancelled = context.check();
        if (cancelled.code != Status.ok)
            return cancelled;
        if (item.versionNumber <= previous || item.versionNumber > long.max)
            return Error(Status.invalidArgument,
                    "migration versions must be positive, signed-range and strictly increasing");
        const valid = preflightMigration(item, driver, maximumPrograms - total);
        if (valid.code != Status.ok)
            return valid;
        previous = item.versionNumber;
        total += item.sql.length;
    }
    return Error.init;
}

private Error preflightMigration(scope const ref Migration item, Driver driver, size_t available)
{
    if (item.description.length > maximumProgram || !validText(item.description))
        return forVersion(item.versionNumber, Status.invalidArgument, "invalid migration description");
    if (item.sql.length > maximumProgram || item.sql.length > available || !validText(item.sql))
        return forVersion(item.versionNumber, Status.invalidArgument, "invalid migration SQL length or UTF-8");
    if (driver == Driver.sqlite && !item.transactional)
        return forVersion(item.versionNumber, Status.unsupported, "SQLite requires transactional migrations");
    if (!correctDigest(item))
        return forVersion(item.versionNumber, Status.conflict, "migration SQL bytes do not match their SHA-256");
    return Error.init;
}

private Error migrateLocked(ref Session session, scope const(Migration)[] plan,
        MigrationOptions options, ref Context context, ref MigrationReport report)
{
    History history;
    auto status = history.open(session.connection, session.driver, options.historyTable, context);
    if (status.code != Status.ok)
        return status;
    Prefix prefix;
    status = inspect(session, history, plan, options.validateOnly, context, prefix);
    report.currentVersion = prefix.versionNumber;
    if (status.code != Status.ok || options.validateOnly)
        return status;
    if (session.driver == Driver.sqlite)
        return applySqlite(session, history, plan[prefix.matched .. $], context, report);
    return applyPostgres(session, history, plan[prefix.matched .. $], context, report);
}

private Error inspect(ref Session session, ref History history, scope const(Migration)[] plan,
        bool validateOnly, ref Context context, out Prefix prefix)
{
    const present = history.exists(session.connection, context);
    if (!present.ok())
        return present.error;
    if (present.value)
    {
        const status = history.checkMetadata(session.connection, context);
        if (status.code != Status.ok)
            return status;
        return history.read(session.connection, plan, context, prefix);
    }
    const metadata = history.metadataExists(session.connection, context);
    if (!metadata.ok())
        return metadata.error;
    if (metadata.value)
        return Error(Status.conflict, "migration metadata exists without its history table");
    if (validateOnly || plan.length == 0)
        return Error.init;
    if (session.driver == Driver.sqlite)
        return history.install(session.connection, context);
    auto status = session.begin("BEGIN", context);
    if (status.code == Status.ok)
        status = history.install(session.connection, context);
    return status.code == Status.ok ? session.commit(context) : status;
}

private Error applySqlite(ref Session session, ref History history, scope const(Migration)[] pending,
        ref Context context, ref MigrationReport report)
{
    foreach (ref const migration; pending)
    {
        const outcome = executeAndRecord(session, history, migration, context);
        if (outcome.code != Status.ok)
            return describeFailure(migration, outcome);
    }
    const committed = session.commit(context);
    if (committed.code != Status.ok)
        return committed;
    report.applied = cast(uint) pending.length;
    if (pending.length != 0)
        report.currentVersion = pending[$ - 1].versionNumber;
    return Error.init;
}

private Error applyPostgres(ref Session session, ref History history, scope const(Migration)[] pending,
        ref Context context, ref MigrationReport report)
{
    foreach (ref const migration; pending)
    {
        const result = migration.transactional ? transactional(session, history, migration,
                context) : withMarker(session, history, migration, context);
        if (result.code != Status.ok)
            return describeFailure(migration, result);
        ++report.applied;
        report.currentVersion = migration.versionNumber;
    }
    return Error.init;
}

private Error transactional(ref Session session, ref History history,
        scope const ref Migration migration, ref Context context)
{
    auto status = session.begin("BEGIN", context);
    if (status.code != Status.ok)
        return status;
    status = executeAndRecord(session, history, migration, context);
    return status.code == Status.ok ? session.commit(context) : status;
}

private Error withMarker(ref Session session, ref History history, scope const ref Migration migration,
        ref Context context)
{
    auto status = writeMarker(session, history, migration, context);
    if (status.code != Status.ok)
        return status;
    const elapsed = runProgram(session, migration, context);
    if (!elapsed.ok())
        return elapsed.error;
    status = session.beginDurable(context);
    if (status.code == Status.ok)
        status = history.completeMarker(session.connection, migration.versionNumber, elapsed.value, context);
    return status.code == Status.ok ? session.commit(context) : status;
}

private Error writeMarker(ref Session session, ref History history, scope const ref Migration migration,
        ref Context context)
{
    auto status = session.beginDurable(context);
    if (status.code == Status.ok)
        status = history.record(session.connection, migration, 0, false, context);
    return status.code == Status.ok ? session.commit(context) : status;
}

private Error executeAndRecord(ref Session session, ref History history,
        scope const ref Migration migration, ref Context context)
{
    const elapsed = runProgram(session, migration, context);
    return elapsed.ok() ? history.record(session.connection, migration, elapsed.value, true, context) : elapsed.error;
}

private Result!long runProgram(ref Session session, scope const ref Migration migration, ref Context context)
{
    const started = MonoTime.currTime;
    const outcome = session.connection.executeScript(migration.sql, context);
    return Result!long((MonoTime.currTime - started).total!"msecs", outcome);
}

private Error forVersion(ulong number, Status status, string explanation)
{
    return Error(status, "migration version " ~ number.to!string ~ " " ~ explanation);
}

private Error describeFailure(scope const ref Migration migration, Error failure)
{
    const detail = failure.message.length == 0 ? "could not be applied" : "failed. " ~ failure.message;
    return forVersion(migration.versionNumber, failure.code, detail);
}

private struct Session
{
    Connection connection;
    Driver driver;
    bool transaction;
    bool lockAttempted;
    bool lockHeld;

    Error lock(long nanos, ref Context parent) nothrow @nogc
    {
        const now = Deadline.afterMillis(0).monotonicNanoseconds;
        const limit = now < long.max - nanos ? now + nanos : long.max - 1;
        auto source = CancelSource.create(parent, Deadline(limit));
        if (!source.ok())
            return source.error;
        auto context = source.value.context();
        if (driver == Driver.sqlite)
            return begin("BEGIN IMMEDIATE", context);

        lockAttempted = true;
        scope RequestArena unused;
        const acquired = connection.execute("SELECT pg_advisory_lock($1)", [integer(lockKey)], unused, context);
        lockHeld = acquired.ok();
        return acquired.error;
    }

    Error begin(scope const(char)[] sql, ref Context context) nothrow @nogc
    {
        const status = command(connection, sql, context);
        if (status.code == Status.ok)
            transaction = true;
        else if (status.code == Status.timedOut || status.code == Status.cancelled || status.code == Status.ioError)
            connection.retire();
        return status;
    }

    Error beginDurable(ref Context context) nothrow @nogc
    {
        const status = begin("BEGIN", context);
        return status.code == Status.ok ? command(connection, "SET LOCAL synchronous_commit=on", context) : status;
    }

    Error commit(ref Context context) nothrow @nogc
    {
        const status = command(connection, "COMMIT", context);
        if (status.code == Status.ok)
            transaction = false;
        return status;
    }

    Error cleanup() nothrow @nogc
    {
        if (!transaction && !lockAttempted)
            return Error.init;
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(1500));
        if (!source.ok())
        {
            connection.retire();
            return source.error;
        }
        auto context = source.value.context();
        Error rollback;
        if (transaction)
            rollback = command(connection, "ROLLBACK", context);
        if (rollback.code != Status.ok)
        {
            connection.retire();
            return rollback;
        }
        const released = lockAttempted ? unlock(context) : Error.init;
        if (released.code != Status.ok)
            connection.retire();
        return released;
    }

    private Error unlock(ref Context context) nothrow @nogc
    {
        scope RequestArena unused;
        bool unlocked;
        bool observed;
        const status = connection.query("SELECT pg_advisory_unlock($1)", [integer(lockKey)],
                unused, context, (ref Row row) @safe nothrow @nogc {
            const result = row.value(0, unused);
            if (!result.ok() || result.value.kind != ValueKind.boolean || observed)
                return Error(Status.conflict, "migration advisory unlock result was invalid");
            observed = true;
            unlocked = result.value.integer != 0;
            return Error.init;
        });
        if (status.code != Status.ok)
            return status;
        if (!observed || (lockHeld && !unlocked))
            return Error(Status.conflict, "migration advisory unlock was not acknowledged");
        return Error.init;
    }
}
