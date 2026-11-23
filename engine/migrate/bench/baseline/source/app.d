module app;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.sql : Connection, Driver, Pool, Row, SqlValue, ValueKind;
import probe : Entry, benchmark, require, rows;

@safe:

private enum lockKey = SqlValue(ValueKind.int64, 0x464C_494E_545F_4D47L);

private void command(ref Connection connection, string sql, scope const(SqlValue)[] values, ref Context context)
{
    scope RequestArena unused;
    require(connection.execute(sql, values, unused, context).ok());
}

private void found(ref Connection connection, string sql, ref Context context)
{
    scope RequestArena unused;
    uint count;
    const status = connection.query(sql, [], unused, context, (ref Row) @safe nothrow @nogc {
        ++count;
        return Error.init;
    });
    require(status.code == Status.ok && count == 1);
}

private void inspect(ref Connection connection, bool sqlite, ref Context context)
{
    if (sqlite)
    {
        found(connection,
                "SELECT 1 FROM main.sqlite_schema WHERE type='table' AND name='flint_schema_history'", context);
        found(connection,
                "SELECT 1 FROM main.sqlite_schema" ~ " WHERE type='table' AND name='flint_schema_history_settings'",
                context);
        found(connection, "SELECT effective_schema, driver FROM flint_schema_history_settings"
                ~ " WHERE installation_key=1 AND effective_schema='main' AND driver='sqlite'", context);
    }
    else
    {
        found(connection, "SELECT current_schema()::text", context);
        found(connection, "SELECT 1 FROM information_schema.tables WHERE table_schema=current_schema()"
                ~ " AND table_name='flint_schema_history'", context);
        found(connection, "SELECT 1 FROM information_schema.tables WHERE table_schema=current_schema()"
                ~ " AND table_name='flint_schema_history_metadata'", context);
        found(connection, "SELECT effective_schema, driver FROM flint_schema_history_metadata"
                ~ " WHERE installation_key=1 AND effective_schema=current_schema() AND driver='postgres'", context);
    }
}

private ulong read(ref Connection connection, scope const(Entry)[] entries, ref Context context)
{
    ubyte[256] scratch;
    scope arena = RequestArena(scratch[]);
    size_t index;
    ulong checksum;
    enum statement = "SELECT version, sha256, success FROM flint_schema_history ORDER BY version";
    const checked = connection.query(statement, [], arena, context, (ref Row row) @safe nothrow @nogc {
        require(arena.reset() == Status.ok && index < entries.length);
        const number = row.value(0, arena);
        const digest = row.value(1, arena);
        const success = row.value(2, arena);
        require(number.ok() && digest.ok() && success.ok());
        require(number.value.kind == ValueKind.int64 && number.value.integer == entries[index].number);
        require(digest.value.kind == ValueKind.text);
        require(success.value.kind == ValueKind.boolean && success.value.integer == 1);
        bool equal;
        const status = arena.read(digest.value.bytes, (scope const(ubyte)[] input) @safe nothrow @nogc {
            equal = input == cast(const(ubyte)[]) entries[index].hex[];
        });
        require(status == Status.ok && equal);
        checksum += number.value.integer;
        ++index;
        return Error.init;
    });
    require(checked.code == Status.ok && index == rows);
    return checksum;
}

private ulong validate(ref Pool pool, ref Context context, scope const(Entry)[] entries)
{
    auto lease = pool.acquire(context);
    require(lease.ok());
    scope (exit)
        require(pool.release(lease.value).code == Status.ok);
    auto connection = lease.value;
    const sqlite = pool.driver() == Driver.sqlite;
    if (sqlite)
        command(connection, "BEGIN IMMEDIATE", [], context);
    else
        command(connection, "SELECT pg_advisory_lock($1)", [lockKey], context);
    inspect(connection, sqlite, context);
    const checksum = read(connection, entries, context);
    if (sqlite)
        command(connection, "ROLLBACK", [], context);
    else
        command(connection, "SELECT pg_advisory_unlock($1)", [lockKey], context);
    return checksum;
}

void main(string[] args)
{
    benchmark(args, &validate);
}
